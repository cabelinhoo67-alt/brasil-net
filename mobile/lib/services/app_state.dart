import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/storage.dart';
import '../models/models.dart';
import 'bypass_store.dart';
import 'config_cache.dart';
import 'overlay_service.dart';
import 'sim_service.dart';
import 'tunnel/tunnel_factory.dart';
import 'tunnel/tunnel_service.dart';

/// Coordenadas fixas da VPS — nao sao segredo (o mesmo IP/portas ja aparece
/// em qualquer captura de trafego do tunel), so infraestrutura estavel. Usadas
/// para o "login de resgate": quando a API nem responde (rede aberta
/// bloqueada) e nao ha cache local, ainda assim conhecemos onde o servidor
/// esta — so nao sabemos o payload especifico da operadora do usuario.
const _bootstrapServer = ServerInfo(
  id: 'bootstrap',
  name: 'Brasil-Net BR-01',
  host: '187.77.37.249',
  sshPort: 22,
  sslPort: 443,
  proxyPort: 80,
);

/// Payload generico para a tentativa de resgate: sem template proprio, a
/// cadeia de estrategias (StrategyChain) ja cobre payload CONNECT, TLS/SNI e
/// WebSocket por conta propria como fallback, entao o modo de partida aqui e
/// so o ponto de largada da cadeia, nao a unica tentativa.
const _bootstrapPayload = Payload(
  id: 'bootstrap',
  name: 'Reconexao automatica',
  mode: 'SSH_DIRECT',
  content: '',
  server: _bootstrapServer,
);

/// Chuta o codigo da operadora a partir do nome bruto lido do chip (via
/// TelephonyManager, sem precisar da API) — usado so no tunel de resgate,
/// quando `_operator.code` ainda nao foi confirmado pelo backend (a API e
/// justamente quem nao respondeu, entao nunca teria como confirmar isso a
/// tempo). Sem isso, a estrategia TLS/SNI cai no IP puro do servidor como
/// SNI, o que nao e um bug host de verdade e nunca teve chance de funcionar.
String? _guessOperatorCode(SimInfo sim) {
  final name = sim.operatorName.toUpperCase();
  if (name.contains('CLARO')) return 'CLARO';
  if (name.contains('VIVO')) return 'VIVO';
  if (name.contains('TIM')) return 'TIM';
  if (name.contains('OI')) return 'OI';
  if (name.contains('ALGAR') || name.contains('CTBC')) return 'ALGAR';
  if (name.contains('VERO')) return 'VERO';
  return null;
}

/// Estado global do app: autenticacao, operadora detectada, payloads,
/// status do tunel, ping e heartbeat de sessao.
class AppState extends ChangeNotifier {
  AppState({ApiClient? api, BypassStore? bypass})
      : _api = api ?? ApiClient(),
        bypass = bypass ?? BypassStore();

  final ApiClient _api;

  /// Apps que ficam fora do tunel. Exposto para a tela de bypass.
  final BypassStore bypass;

  TunnelService? _tunnel;
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<String>? _logSub;

  Timer? _pingTimer;
  Timer? _heartbeatTimer;

  // ------------------------------ estado -----------------------------------

  bool _booting = true;
  bool _loading = false;
  String? _error;
  String? _notice;
  String _lastLog = '';

  AppUser? _user;
  String? _password; // necessario para autenticar o SSH do tunel
  SimInfo _sim = SimInfo.empty;
  OperatorInfo _operator = OperatorInfo.unknown;
  List<Payload> _payloads = const [];
  Payload? _selected;

  ConnectionStatus _connection = ConnectionStatus.disconnected;
  int _ping = -1;
  int _activeSessions = 0;
  bool _overlayEnabled = false;

  String _deviceId = '';
  String _deviceName = 'Android';
  String _appVersion = '1.0.0';

  bool get booting => _booting;
  bool get loading => _loading;
  String? get error => _error;
  String? get notice => _notice;
  String get lastLog => _lastLog;
  bool get isLoggedIn => _user != null;

  AppUser? get user => _user;
  SimInfo get sim => _sim;
  OperatorInfo get operator => _operator;
  List<Payload> get payloads => _payloads;
  Payload? get selected => _selected;

  ConnectionStatus get connection => _connection;
  int get ping => _ping;
  int get activeSessions => _activeSessions;
  bool get overlayEnabled => _overlayEnabled;

  String get pingLabel => _ping < 0 ? '--' : '$_ping ms';

  /// Sem operadora reconhecida nao ha payload — e isso e intencional:
  /// o filtro por chip e a regra central do produto.
  bool get canConnect =>
      _selected != null && !_connection.isBusy && _operator.detected;

  // ------------------------------ ciclo ------------------------------------

  Future<void> bootstrap() async {
    _booting = true;
    notifyListeners();

    await _loadDeviceInfo();
    await bypass.load();
    _overlayEnabled = await Storage.readOverlayPreference();
    await refreshSim();

    final saved = await Storage.readCredentials();
    if (saved != null) {
      await login(saved.username, saved.password, remember: true, silent: true);
    }

    _booting = false;
    notifyListeners();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final package = await PackageInfo.fromPlatform();
      _appVersion = package.version;
    } catch (_) {
      // mantem o default
    }

    String fallbackId = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _deviceName = '${info.brand} ${info.model}';
      // O id do Android nao e globalmente unico entre apps, mas e estavel
      // para o par (app, aparelho) — que e o que o limite de conexoes precisa.
      fallbackId = info.id;
    } catch (_) {
      // desktop/iOS em desenvolvimento
    }

    _deviceId = await Storage.deviceId(fallbackId);
  }

  /// Le o chip e atualiza a configuracao. Chamado no boot e no "puxar para atualizar".
  Future<void> refreshSim() async {
    final granted = await SimService.ensurePermission();
    if (!granted) {
      _sim = SimInfo.empty;
      _operator = OperatorInfo.unknown;
      _notice =
          'Sem a permissao de telefone o app nao consegue identificar sua operadora.';
      notifyListeners();
      return;
    }

    _sim = await SimService.read();
    notifyListeners();

    if (isLoggedIn) await refreshConfig();
  }

  // --------------------------- autenticacao --------------------------------

  /// Login OFFLINE: aceito a partir do cache local, sem confirmacao da API.
  /// A validacao real das credenciais so acontece quando o usuario tenta
  /// conectar — e o handshake SSH quem confirma usuario/senha nesse caso.
  bool _offlineLogin = false;
  bool get isOfflineLogin => _offlineLogin;

  Future<bool> login(
    String username,
    String password, {
    bool remember = true,
    bool silent = false,
  }) async {
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }

    try {
      final data = await _api.post('/api/app/login', _loginBody(username, password));
      await _applyLoginSuccess(
        data,
        username: username.trim(),
        password: password,
        remember: remember,
      );
      _error = null;
      return true;
    } on ApiException catch (e) {
      debugPrint('[login] falhou: ${e.code} — ${e.message}');

      _error = e.message;
      _lastLog = 'login: ${e.code ?? 'ERRO'}';

      // So cai para o cache/tunel em falha de REDE — senha errada, bloqueio
      // ou expiracao continuam sendo mostrados normalmente, sem mascarar
      // atras de um "modo offline" que nao resolveria o problema real.
      if (e.isNetworkFailure) {
        final offline = await _tryOfflineLogin(username.trim(), password);
        if (offline) return true;

        // Sem cache (aparelho novo, ou 1o login neste device): a unica forma
        // de confirmar a senha e o proprio handshake SSH contra a VPS. Se a
        // operadora esta bloqueando so a chamada de API pela rede aberta —
        // o cenario classico do chip sem credito — o tunel ainda assim
        // costuma passar (ele tem 4 transportes diferentes tentando furar
        // exatamente esse bloqueio). Substitui _error por uma mensagem mais
        // precisa se o proprio SSH confirmar o motivo real da falha.
        final bootstrap = await _tryBootstrapTunnelLogin(username.trim(), password);
        if (bootstrap) return true;
      }

      return false;
    } catch (e, stack) {
      // Nada deve cair aqui. Se cair, o console mostra o que foi — engolir a
      // excecao numa mensagem generica ja custou horas de diagnostico errado.
      debugPrint('[login] excecao inesperada: ${e.runtimeType}: $e');
      debugPrintStack(stackTrace: stack, maxFrames: 8);
      _error = 'Erro inesperado no login: ${e.runtimeType}. Veja o log do app.';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Usa a config salva no ultimo login bem-sucedido para liberar a tela
  /// principal sem esperar a API — o usuario entao toca em "conectar" e o
  /// proprio handshake SSH confirma se a senha ainda e valida.
  ///
  /// So funciona a partir do 2o login em diante: sem cache (aparelho novo, ou
  /// usuario que nunca logou aqui com rede boa), nao ha host/porta/payload
  /// para tentar — nesse caso a API precisa mesmo responder.
  Future<bool> _tryOfflineLogin(String username, String password) async {
    final cached = await ConfigCache.read(username);
    if (cached == null) {
      debugPrint('[login] sem cache para "$username" — nao ha modo offline possivel');
      return false;
    }

    debugPrint(
      '[login] rede indisponivel; usando config salva ha ${cached.age.inMinutes} min',
    );

    _user = cached.user;
    _operator = cached.operator;
    _payloads = cached.payloads;
    _selected = _payloads.isEmpty ? null : _payloads.first;
    _password = password; // a que o usuario acabou de digitar, nao a cacheada
    _offlineLogin = true;

    _notice = 'Sem confirmar com o servidor ainda — conecte para validar.';
    _startTimers();
    return true;
  }

  /// Ultimo recurso quando nao ha cache algum: sobe o tunel direto contra a
  /// VPS (coordenadas fixas, sem payload de operadora) e deixa o proprio
  /// handshake SSH confirmar usuario/senha primeiro. E o unico jeito de logar
  /// num aparelho novo quando a rede aberta bloqueia so a chamada de API — a
  /// cadeia de estrategias do tunel tem 4 transportes tentando furar
  /// exatamente esse tipo de bloqueio (o mesmo motivo pelo qual o tunel em si
  /// funciona mesmo sem saldo).
  ///
  /// Com o tunel de pe (e o SOCKS ja armado pelo listener do _bindTunnel),
  /// repete a MESMA chamada de /api/app/login que acabou de falhar pela rede
  /// aberta — agora ela sai pelo tunel. `/api/app/config` exige token, entao
  /// nao da para simplesmente chamar refreshConfig(): sem essa segunda
  /// chamada de login, nunca existiria um token para autenticar nada.
  Future<bool> _tryBootstrapTunnelLogin(String username, String password) async {
    debugPrint('[login] sem cache; tentando confirmar via tunel direto');

    _bindTunnel(_bootstrapPayload);

    try {
      await _tunnel!.connect(
        _bootstrapPayload,
        username: username,
        password: password,
        bypassPackages: bypass.packages.toList(),
        operatorCode: _operator.code ?? _guessOperatorCode(_sim),
      );
    } on TunnelException catch (error) {
      debugPrint('[login] tunel de resgate falhou: ${error.message}');
      if (error.authFailed) {
        _error = 'Usuario ou senha incorretos.';
      } else if (error.detail != null) {
        // Inclui a etapa que falhou para o usuario conseguir agir (ex.:
        // "Nao consegui alcancar host:porta" aponta bloqueio de rede; um
        // detail de TLS aponta interferencia da operadora).
        _error = 'Nao consegui falar com o servidor. ${error.detail}';
      } else {
        _error = 'Nao consegui falar com o servidor por nenhum caminho. '
            'Verifique sua conexao e tente novamente.';
      }
      return false;
    } catch (error) {
      debugPrint('[login] tunel de resgate — erro inesperado: $error');
      _error = 'Nao consegui falar com o servidor. Tente novamente.';
      return false;
    }

    debugPrint('[login] tunel de resgate conectado — repetindo login por dentro dele');

    try {
      final data = await _api.post('/api/app/login', _loginBody(username, password));
      await _applyLoginSuccess(data, username: username, password: password, remember: true);
      return true;
    } catch (e) {
      // Caso raro: o SSH ja provou que a senha esta certa, mas a chamada de
      // login por dentro do tunel falhou por outro motivo (API recusou por
      // regra de negocio, erro de parsing, etc.). O tunel continua de pe —
      // trata como login offline-equivalente em vez de derrubar a conexao
      // que acabou de furar o bloqueio da operadora so por causa de um erro
      // secundario nao relacionado a rede.
      debugPrint('[login] tunel ok mas login por dentro dele falhou: $e');
      _user = AppUser(id: '', username: username, connectionLimit: 1);
      _password = password;
      _payloads = const [_bootstrapPayload];
      _selected = _bootstrapPayload;
      _offlineLogin = true;
      _notice = 'Conectado — confirmando seus dados com o servidor...';
      _startTimers();
      return true;
    }
  }

  Map<String, dynamic> _loginBody(String username, String password) => {
        'username': username.trim(),
        'password': password,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'appVersion': _appVersion,
        'sim': {
          'operatorName': _sim.operatorName,
          'mccMnc': _sim.mccMnc,
        },
      };

  /// Processa uma resposta de /api/app/login bem-sucedida — usado tanto pelo
  /// caminho normal (rede aberta) quanto pelo tunel de resgate (mesma
  /// chamada, roteada por dentro do SOCKS depois que o SSH ja autenticou).
  Future<void> _applyLoginSuccess(
    Map<String, dynamic> data, {
    required String username,
    required String password,
    required bool remember,
  }) async {
    _api.setToken(data['token'] as String);
    await Storage.saveToken(data['token'] as String);

    _user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
    _password = password; // o tunel SSH autentica com as mesmas credenciais
    _operator = OperatorInfo.fromJson(data['operator'] as Map<String, dynamic>);
    _applyPayloads(data['payloads'] as List<dynamic>);
    _offlineLogin = false;
    _notice = null;

    if (remember) {
      await Storage.saveCredentials(username, password);
    }

    // Atualiza o cache para poder cair aqui da proxima vez que a rede aberta
    // estiver ruim.
    await ConfigCache.save(
      username: username,
      user: _user!,
      operator: _operator,
      payloads: _payloads,
    );

    _startTimers();
  }

  Future<void> logout() async {
    _stopTimers();
    await _tunnel?.disconnect();

    try {
      await _api.post('/api/app/session/close');
    } catch (_) {
      // sessao expira sozinha pelo timeout do backend
    }

    _api.setToken(null);
    await Storage.clearToken();
    await Storage.clearCredentials();

    _user = null;
    _password = null;
    _payloads = const [];
    _selected = null;
    _connection = ConnectionStatus.disconnected;
    _ping = -1;
    notifyListeners();
  }

  // ---------------------------- configuracao -------------------------------

  void _applyPayloads(List<dynamic> raw) {
    _payloads = raw
        .whereType<Map<String, dynamic>>()
        .map(Payload.fromJson)
        .toList(growable: false);

    // Mantem a selecao atual se ela ainda existir na nova lista.
    final previousId = _selected?.id;
    _selected = _payloads.isEmpty
        ? null
        : _payloads.firstWhere(
            (p) => p.id == previousId,
            orElse: () => _payloads.first,
          );
  }

  /// Rebusca os payloads da operadora atual sem refazer login.
  Future<void> refreshConfig() async {
    if (!isLoggedIn) return;

    try {
      final data = await _api.get('/api/app/config', query: {
        'operatorName': _sim.operatorName,
        'mccMnc': _sim.mccMnc,
      });

      _operator = OperatorInfo.fromJson(data['operator'] as Map<String, dynamic>);
      _applyPayloads(data['payloads'] as List<dynamic>);

      final userJson = data['user'] as Map<String, dynamic>;
      if (userJson['expired'] == true || userJson['blocked'] == true) {
        await _forceDisconnect(
          userJson['expired'] == true ? 'Seu acesso expirou.' : 'Sua conta foi bloqueada.',
        );
        return;
      }

      _user = AppUser.fromJson({
        'id': _user?.id ?? '',
        'username': userJson['username'],
        'expiresAt': userJson['expiresAt'],
        'daysLeft': userJson['daysLeft'],
        'connectionLimit': userJson['connectionLimit'],
      });

      // O backend confirmou os dados — sai do modo offline (se estava nele)
      // e atualiza o cache para a proxima vez que a rede aberta falhar.
      if (_offlineLogin) {
        _offlineLogin = false;
        _notice = null;
        debugPrint('[login] confirmado com o backend — saiu do modo offline');
      }
      await ConfigCache.save(
        username: _user!.username,
        user: _user!,
        operator: _operator,
        payloads: _payloads,
      );

      notifyListeners();
    } on ApiException catch (e) {
      // Em modo offline, uma falha aqui e esperada (e a mesma rede que
      // bloqueou o login) — nao sobrescreve o que ja esta funcionando com
      // o tunel ativo.
      if (!_offlineLogin) _error = e.message;
      notifyListeners();
    } catch (_) {
      // offline: mantem a configuracao ja carregada
    }
  }

  void selectPayload(Payload payload) {
    if (_connection.isOnline || _connection.isBusy) return;
    _selected = payload;
    notifyListeners();
  }

  // ------------------------------- tunel -----------------------------------

  /// Liga o motor certo para o payload e passa a escutar o status dele.
  void _bindTunnel(Payload payload) {
    final engine = TunnelFactory.forPayload(payload);
    if (identical(engine, _tunnel)) return;

    _statusSub?.cancel();
    _logSub?.cancel();
    _tunnel = engine;

    _statusSub = engine.status.listen((value) {
      _connection = value;
      _syncOverlay();

      if (value == ConnectionStatus.connected) {
        // A API do proprio app fica de fora da VPN por design (bypass), entao
        // so passa a usar o tunel se a gente disser explicitamente. Isso e o
        // que permite confirmar o login (refreshConfig) pelo MESMO caminho
        // que acabou de furar o bloqueio da operadora — em vez de tentar de
        // novo pela rede aberta, que e onde o 302 acontecia.
        final port = engine.socksPort;
        if (port != null) _api.useSocksProxy(port);

        if (_offlineLogin) {
          unawaited(refreshConfig());
        }
      } else if (value == ConnectionStatus.disconnected) {
        _api.useSocksProxy(null);
      }

      notifyListeners();
    });

    _logSub = engine.logs.listen((message) {
      _lastLog = message;
      notifyListeners();
    });
  }

  Future<void> toggleConnection() async {
    if (_connection.isOnline || _connection.isBusy) {
      await _tunnel?.disconnect();
      return;
    }

    final payload = _selected;
    if (payload == null) {
      _error = 'Selecione uma configuracao antes de conectar.';
      notifyListeners();
      return;
    }

    if (_user == null || _password == null) {
      _error = 'Faca login novamente para conectar.';
      notifyListeners();
      return;
    }

    _error = null;
    _bindTunnel(payload);

    try {
      await _tunnel!.connect(
        payload,
        username: _user!.username,
        password: _password!,
        bypassPackages: bypass.packages.toList(),
        operatorCode: _operator.code,
      );
    } on TunnelException catch (e) {
      // Expõe a etapa que falhou (TCP, payload, TLS, SSH ou auth) via detail,
      // quando houver — em vez de so a mensagem generica.
      _error = e.detail == null ? e.message : '${e.message} (${e.detail})';
      notifyListeners();
    } catch (e) {
      _error = 'Falha ao conectar: $e';
      notifyListeners();
    }
  }

  Future<void> _forceDisconnect(String reason) async {
    await _tunnel?.disconnect();
    _stopTimers();
    _error = reason;
    _payloads = const [];
    _selected = null;
    notifyListeners();
  }

  // ------------------------- ping e heartbeat ------------------------------

  void _startTimers() {
    _stopTimers();

    _measurePing();
    _pingTimer = Timer.periodic(AppConfig.pingInterval, (_) => _measurePing());

    _sendHeartbeat();
    _heartbeatTimer =
        Timer.periodic(AppConfig.heartbeatInterval, (_) => _sendHeartbeat());
  }

  void _stopTimers() {
    _pingTimer?.cancel();
    _heartbeatTimer?.cancel();
    _pingTimer = null;
    _heartbeatTimer = null;
  }

  Future<void> _measurePing() async {
    final value = await _api.measurePing();
    if (value != _ping) {
      _ping = value;
      notifyListeners();
    }
    if (_overlayEnabled && _connection.isOnline) {
      OverlayService.update(pingMs: _ping, status: 'connected');
    }
  }

  // ------------------------------- overlay ----------------------------------

  /// Liga/desliga a janela flutuante. Pede a permissao do sistema na primeira
  /// vez — ela nao vem por dialogo de runtime, entao [enabled] so reflete o
  /// que realmente foi concedido.
  Future<bool> setOverlayEnabled(bool enabled) async {
    if (enabled) {
      final granted = await OverlayService.hasPermission();
      if (!granted) {
        await OverlayService.requestPermission();
        // A concessao acontece numa tela do sistema; o app so sabe o
        // resultado quando volta ao primeiro plano. Nao habilita "no escuro".
        _overlayEnabled = false;
        await Storage.saveOverlayPreference(false);
        notifyListeners();
        return false;
      }
    } else {
      await OverlayService.hide();
    }

    _overlayEnabled = enabled;
    await Storage.saveOverlayPreference(enabled);
    _syncOverlay();
    notifyListeners();
    return enabled;
  }

  /// Chamado ao voltar ao app (ex.: apos a tela de permissao do sistema) para
  /// reavaliar se o overlay pode subir agora.
  Future<void> recheckOverlayPermission() async {
    if (!_overlayEnabled) return;
    final granted = await OverlayService.hasPermission();
    if (granted) _syncOverlay();
  }

  void _syncOverlay() {
    if (!_overlayEnabled) return;

    if (_connection.isOnline || _connection.isBusy) {
      OverlayService.show().then((shown) {
        if (shown) {
          OverlayService.update(
            pingMs: _ping,
            status: _connection.isOnline ? 'connected' : 'connecting',
          );
        }
      });
    } else {
      OverlayService.hide();
    }
  }

  /// O heartbeat e o que permite ao painel derrubar um cliente em tempo real
  /// (bloqueio, expiracao ou kick manual pelo revendedor).
  Future<void> _sendHeartbeat() async {
    if (!isLoggedIn) return;

    try {
      final data = await _api.post('/api/app/session/heartbeat');
      _activeSessions = (data['activeSessions'] ?? 0) as int;

      final days = data['daysLeft'] as int?;
      if (days != null && days != _user?.daysLeft) {
        _user = AppUser(
          id: _user!.id,
          username: _user!.username,
          fullName: _user!.fullName,
          expiresAt: _user!.expiresAt,
          daysLeft: days,
          connectionLimit: _user!.connectionLimit,
          planName: _user!.planName,
        );
      }
      notifyListeners();
    } on ApiException catch (e) {
      if (e.shouldDisconnect) {
        await _forceDisconnect(e.message);
        await logout();
      }
    } catch (_) {
      // sem rede: o proximo heartbeat tenta de novo
    }
  }

  void clearError() {
    _error = null;
    _notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimers();
    _statusSub?.cancel();
    _logSub?.cancel();
    TunnelFactory.disposeAll();
    _api.dispose();
    super.dispose();
  }
}

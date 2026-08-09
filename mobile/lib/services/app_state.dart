import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/storage.dart';
import '../models/models.dart';
import 'bypass_store.dart';
import 'overlay_service.dart';
import 'sim_service.dart';
import 'tunnel/tunnel_factory.dart';
import 'tunnel/tunnel_service.dart';

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
      final data = await _api.post('/api/app/login', {
        'username': username.trim(),
        'password': password,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'appVersion': _appVersion,
        'sim': {
          'operatorName': _sim.operatorName,
          'mccMnc': _sim.mccMnc,
        },
      });

      _api.setToken(data['token'] as String);
      await Storage.saveToken(data['token'] as String);

      _user = AppUser.fromJson(data['user'] as Map<String, dynamic>);
      _password = password; // o tunel SSH autentica com as mesmas credenciais
      _operator = OperatorInfo.fromJson(data['operator'] as Map<String, dynamic>);
      _applyPayloads(data['payloads'] as List<dynamic>);

      if (remember) {
        await Storage.saveCredentials(username.trim(), password);
      }

      _startTimers();
      _error = null;
      return true;
    } on ApiException catch (e) {
      // A ApiException ja vem com a causa traduzida (TIMEOUT, UNREACHABLE...).
      debugPrint('[login] falhou: ${e.code} — ${e.message}');
      _error = e.message;
      _lastLog = 'login: ${e.code ?? 'ERRO'}';
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

      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
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
      _error = e.message;
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

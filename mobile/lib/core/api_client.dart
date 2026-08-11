import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:socks5_proxy/socks_client.dart';

import 'app_config.dart';

/// Erro vindo da API, ja com o `code` estavel que o backend devolve
/// (EXPIRED, CONNECTION_LIMIT, USER_DISABLED, BAD_CREDENTIALS...).
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  bool get isExpired => code == 'EXPIRED';
  bool get isConnectionLimit => code == 'CONNECTION_LIMIT';
  bool get shouldDisconnect =>
      code == 'EXPIRED' || code == 'USER_DISABLED' || code == 'SESSION_CLOSED';

  /// Falha de TRANSPORTE (rede ruim, redirect, timeout) — nunca de negocio
  /// (credenciais, bloqueio, expiracao). E o que decide se vale tentar o
  /// fallback de login offline: cair para o cache por causa de senha errada
  /// seria esconder o erro real do usuario.
  static const _networkCodes = {
    'TIMEOUT',
    'UNREACHABLE',
    'TLS',
    'CONNECTION_LOST',
    'BAD_RESPONSE',
    'NETWORK_REDIRECT',
  };
  bool get isNetworkFailure => _networkCodes.contains(code);

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? _NoRedirectClient();

  /// Nao-final: `useSocksProxy` troca o client para rotear (ou nao) pelo
  /// tunel — ver o comentario la para o motivo.
  http.Client _client;
  String? _token;
  int? _socksPort;

  void setToken(String? token) => _token = token;
  String? get token => _token;

  /// Roteia as chamadas seguintes pelo SOCKS5 local do tunel, ou volta para
  /// a rede aberta se [port] for null.
  ///
  /// O app fica de fora da VPN nativa por design (bypass — evita o loop de
  /// roteamento da propria conexao SSH), entao mesmo com o tunel ativo as
  /// chamadas de API NAO passam por ele automaticamente. Isso e o que fecha
  /// essa lacuna: depois que o tunel autentica, a confirmacao com o backend
  /// (refreshConfig) pode ir por dentro dele — o mesmo caminho que ja provou
  /// furar o bloqueio da operadora.
  void useSocksProxy(int? port) {
    if (_socksPort == port) return;
    _socksPort = port;

    final old = _client;
    _client = _NoRedirectClient(socksPort: port);
    old.close();
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse('${AppConfig.apiUrl}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(
      queryParameters: query.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    final uri = _uri(path, query);
    return _send('GET', uri, () => _client.get(uri, headers: _headers));
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) {
    final uri = _uri(path);
    return _send(
      'POST',
      uri,
      () => _client.post(uri, headers: _headers, body: jsonEncode(body ?? {})),
    );
  }

  /// Executa a chamada traduzindo falhas de rede em mensagens que dizem o que
  /// aconteceu de verdade.
  ///
  /// Antes, qualquer erro virava "verifique sua internet" — que manda o usuario
  /// procurar o problema no lugar errado quando, por exemplo, o servidor esta
  /// fora do ar. Cada causa agora tem mensagem e `code` proprios, e a excecao
  /// original vai para o console do Flutter (`flutter logs` / logcat).
  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri,
    Future<http.Response> Function() call,
  ) async {
    try {
      final response = await call().timeout(AppConfig.requestTimeout);
      return _decode(response);
    } on TimeoutException catch (error, stack) {
      _logFailure(method, uri, error, stack);
      throw ApiException(
        'O servidor nao respondeu em ${AppConfig.requestTimeout.inSeconds}s. '
        'Ele pode estar fora do ar ou a porta bloqueada.',
        code: 'TIMEOUT',
      );
    } on SocketException catch (error, stack) {
      _logFailure(method, uri, error, stack);

      // errno 111/61 = recusada; 113/101 = host inalcancavel; 7/-2 = DNS.
      final detail = error.osError?.message ?? error.message;
      throw ApiException(
        'Nao consegui alcancar ${uri.host}:${uri.port} ($detail). '
        'Confira se o servidor esta rodando e se a porta esta liberada.',
        code: 'UNREACHABLE',
      );
    } on HandshakeException catch (error, stack) {
      _logFailure(method, uri, error, stack);
      throw ApiException('Falha no certificado HTTPS do servidor.', code: 'TLS');
    } on http.ClientException catch (error, stack) {
      _logFailure(method, uri, error, stack);
      throw ApiException('Conexao interrompida: ${error.message}', code: 'CONNECTION_LOST');
    } on FormatException catch (error, stack) {
      _logFailure(method, uri, error, stack);
      throw ApiException(
        'O servidor respondeu algo que nao e JSON. O endereco aponta mesmo para a API?',
        code: 'BAD_RESPONSE',
      );
    }
  }

  void _logFailure(String method, Uri uri, Object error, StackTrace stack) {
    debugPrint('[api] $method $uri falhou');
    debugPrint('[api] ${error.runtimeType}: $error');
    if (kDebugMode) debugPrintStack(stackTrace: stack, maxFrames: 6);
  }

  void _logRedirect(int status, String? location, Uri? requested) {
    debugPrint('[api] redirect inesperado: $requested -> $status Location: $location');
  }

  Map<String, dynamic> _decode(http.Response response) {
    // 3xx antes de tentar decodificar: quando a rede movel intercepta trafego
    // HTTP em texto claro (proxy transparente de operadora sem credito), o
    // servidor que responde nao e o nosso backend — e a propria operadora,
    // devolvendo um redirect para a pagina de recarga. Tentar fazer
    // jsonDecode nesse corpo (geralmente HTML ou vazio) so produzia
    // "Resposta invalida do servidor (302)", que nao diz ao usuario o que
    // fazer. Detectado aqui, a mensagem aponta a causa real.
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers['location'];
      _logRedirect(response.statusCode, location, response.request?.url);
      throw ApiException(
        'Sua rede redirecionou a conexao (HTTP ${response.statusCode}) em vez '
        'de responder. Isso costuma acontecer quando o chip esta sem credito '
        'ou sem pacote de dados — confira com a operadora ou troque para Wi-Fi.',
        code: 'NETWORK_REDIRECT',
        statusCode: response.statusCode,
      );
    }

    Map<String, dynamic> data;
    try {
      data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(
        'Resposta invalida do servidor (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return data;

    throw ApiException(
      (data['message'] as String?) ?? 'Erro ${response.statusCode}',
      code: data['code'] as String?,
      statusCode: response.statusCode,
    );
  }

  /// Mede o RTT ate o backend. Retorna -1 quando nao ha resposta.
  Future<int> measurePing() async {
    final stopwatch = Stopwatch()..start();
    try {
      await _client
          .get(_uri('/api/app/ping'))
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  void dispose() => _client.close();
}

/// Cliente HTTP que nunca segue redirects sozinho.
///
/// `package:http`'s `IOClient`/`Client()` padrao delega ao `dart:io
/// HttpClient`, que por padrao SEGUE 301/302/303/307/308 automaticamente —
/// inclusive rebaixando POST para GET no caminho (comportamento historico do
/// HTTP/1.0 que a maioria dos clientes ainda replica). Isso troca o corpo da
/// requisicao original por um vazio e faz a rota final devolver outra coisa
/// (404 da rota GET inexistente, HTML de erro), mascarando a causa real atras
/// de "Resposta invalida do servidor" generico.
///
/// `HttpClientRequest.followRedirects` so pode ser setado por requisicao — o
/// `IOClient` de alto nivel nao expoe esse hook, entao a request e aberta na
/// mao aqui. Com isso, todo 3xx chega intacto ao `ApiClient._decode()`, que
/// sabe explicar a causa real: tipicamente a operadora interceptando o chip
/// sem credito, nao um bug no backend.
class _NoRedirectClient extends http.BaseClient {
  _NoRedirectClient({int? socksPort}) {
    if (socksPort != null) {
      // SocksTCPClient substitui o factory de conexao do HttpClient: toda
      // conexao TCP passa a ser negociada via SOCKS5 em 127.0.0.1:socksPort
      // (o servidor que o SshTunnelService ja mantem de pe) antes de tocar
      // a rede de verdade. TLS por cima (chamadas https://) continua
      // funcionando normalmente, encapsulado dentro do proxy.
      SocksTCPClient.assignToHttpClient(_inner, [
        ProxySettings(InternetAddress.loopbackIPv4, socksPort),
      ]);
    }
  }

  final HttpClient _inner = HttpClient()
    ..connectionTimeout = AppConfig.requestTimeout
    ..autoUncompress = true;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final ioRequest = await _inner.openUrl(request.method, request.url);
    ioRequest.followRedirects = false;

    request.headers.forEach(ioRequest.headers.set);
    ioRequest.contentLength =
        request.contentLength ?? (request is http.Request ? request.bodyBytes.length : -1);

    if (request is http.Request && request.bodyBytes.isNotEmpty) {
      ioRequest.add(request.bodyBytes);
    } else {
      await request.finalize().forEach(ioRequest.add);
    }

    final ioResponse = await ioRequest.close();

    // HttpHeaders (dart:io) so oferece forEach — sem .keys nem .entries.
    final headers = <String, String>{};
    ioResponse.headers.forEach((name, values) => headers[name] = values.join(', '));

    return http.StreamedResponse(
      ioResponse,
      ioResponse.statusCode,
      contentLength: ioResponse.contentLength < 0 ? null : ioResponse.contentLength,
      request: request,
      headers: headers,
      reasonPhrase: ioResponse.reasonPhrase,
      isRedirect: ioResponse.isRedirect,
    );
  }

  @override
  void close() => _inner.close(force: true);
}

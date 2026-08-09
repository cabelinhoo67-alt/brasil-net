import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  String? _token;

  void setToken(String? token) => _token = token;
  String? get token => _token;

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

  Map<String, dynamic> _decode(http.Response response) {
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

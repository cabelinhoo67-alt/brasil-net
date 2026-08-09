import 'dart:convert';

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

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    final response = await _client
        .get(_uri(path, query), headers: _headers)
        .timeout(AppConfig.requestTimeout);
    return _decode(response);
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final response = await _client
        .post(_uri(path), headers: _headers, body: jsonEncode(body ?? {}))
        .timeout(AppConfig.requestTimeout);
    return _decode(response);
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

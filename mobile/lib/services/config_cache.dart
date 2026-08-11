import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Ultima configuracao de login que respondeu com sucesso pela API,
/// guardada localmente para permitir o fluxo "tunel primeiro".
///
/// Por que existe: o app precisa saber host, porta, modo e SNI ANTES de abrir
/// o SSH — e hoje isso so vem da API (`/api/app/login`). Numa rede que
/// intercepta a propria chamada de login (chip sem credito, portal cativo),
/// o app fica sem informacao nenhuma para tentar o tunel, mesmo que o SSH em
/// si conseguisse passar. Este cache resolve isso: na primeira vez que a API
/// responder bem, guardamos payloads + dados do usuario por username. Nas
/// vezes seguintes, se a API nao responder rapido, usamos o que ja temos
/// salvo para tentar o tunel direto, sem esperar a rede aberta.
///
/// Limitacao real, sem contorno possivel: o PRIMEIRO login de cada usuario
/// em cada aparelho precisa de uma rede que alcance o backend pelo menos uma
/// vez. Depois disso, logins seguintes tem o fallback.
class ConfigCache {
  ConfigCache._();

  static String _key(String username) => 'config_cache_${username.toLowerCase()}';

  static Future<void> save({
    required String username,
    required AppUser user,
    required OperatorInfo operator,
    required List<Payload> payloads,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode({
      'savedAt': DateTime.now().toIso8601String(),
      'user': user.toJson(),
      'operator': operator.toJson(),
      'payloads': payloads.map((p) => p.toJson()).toList(),
    });
    await prefs.setString(_key(username), json);
  }

  /// Devolve null se este usuario nunca logou com sucesso neste aparelho.
  static Future<CachedConfig?> read(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(username));
    if (raw == null) return null;

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CachedConfig(
        savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
        user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
        operator: OperatorInfo.fromJson(json['operator'] as Map<String, dynamic>),
        payloads: (json['payloads'] as List<dynamic>)
            .map((p) => Payload.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      // Cache corrompido ou de um formato antigo: trata como inexistente.
      return null;
    }
  }

  static Future<void> clear(String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(username));
  }
}

class CachedConfig {
  const CachedConfig({
    required this.savedAt,
    required this.user,
    required this.operator,
    required this.payloads,
  });

  final DateTime savedAt;
  final AppUser user;
  final OperatorInfo operator;
  final List<Payload> payloads;

  Duration get age => DateTime.now().difference(savedAt);
}

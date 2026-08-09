import 'dart:async';

import '../../models/models.dart';

/// Contrato do motor de tunelamento.
///
/// A UI (AppState, telas) so conhece esta interface. Trocar SSH por V2Ray, ou
/// plugar outro core no futuro, e trocar a implementacao — nada mais muda.
abstract class TunnelService {
  Stream<ConnectionStatus> get status;
  Stream<String> get logs;

  ConnectionStatus get currentStatus;

  /// Sobe o tunel para o [payload] escolhido, autenticando com as credenciais
  /// do proprio cliente (o mesmo usuario/senha do login do app).
  ///
  /// [bypassPackages] sao os apps que ficam fora do tunel (split tunneling).
  Future<void> connect(
    Payload payload, {
    required String username,
    required String password,
    List<String> bypassPackages = const [],
  });

  Future<void> disconnect();
  Future<void> dispose();
}

/// Erro de tunel com mensagem ja pronta para a tela.
class TunnelException implements Exception {
  const TunnelException(this.message, {this.detail});

  final String message;
  final Object? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

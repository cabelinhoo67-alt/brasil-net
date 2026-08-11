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

  /// Porta do SOCKS5 local quando o tunel esta ativo, ou null.
  ///
  /// O proprio app fica de fora da VPN nativa (bypass, evita loop de
  /// roteamento da conexao SSH) — entao, mesmo com o tunel de pe, as
  /// chamadas de API do app NAO passam por ele automaticamente. Quem quiser
  /// que uma chamada especifica va pelo tunel precisa falar SOCKS5 com esta
  /// porta explicitamente (ver `ApiClient.useSocksProxy`).
  int? get socksPort;

  /// Sobe o tunel para o [payload] escolhido, autenticando com as credenciais
  /// do proprio cliente (o mesmo usuario/senha do login do app).
  ///
  /// [bypassPackages] sao os apps que ficam fora do tunel (split tunneling).
  /// [operatorCode] alimenta o fallback de bug host (SNI) quando o payload nao
  /// tras um SNI proprio cadastrado.
  Future<void> connect(
    Payload payload, {
    required String username,
    required String password,
    List<String> bypassPackages = const [],
    String? operatorCode,
  });

  Future<void> disconnect();
  Future<void> dispose();
}

/// Erro de tunel com mensagem ja pronta para a tela.
class TunnelException implements Exception {
  const TunnelException(this.message, {this.detail, this.authFailed = false});

  final String message;
  final Object? detail;

  /// true quando o SSH respondeu e recusou usuario/senha — ao contrario de
  /// timeout/bloqueio de rede, trocar de transporte nao resolve isso, entao a
  /// cadeia de fallback deve parar em vez de tentar a proxima estrategia.
  final bool authFailed;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

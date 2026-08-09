import 'dart:async';

import 'package:flutter/services.dart';

import 'tunnel_service.dart';

/// Ponte com a VpnService nativa (Android).
///
/// A VpnService cria a interface TUN e o tun2socks empurra os pacotes IP para
/// o SOCKS5 local que o [SshTunnelService] levantou. Sem esta etapa o tunel
/// existe, mas so quem falar SOCKS explicitamente passa por ele.
class VpnBridge {
  static const _method = MethodChannel('br.com.tunnelsystem/vpn');
  static const _events = EventChannel('br.com.tunnelsystem/vpn_events');

  Stream<String>? _stateStream;

  /// Eventos do servico nativo: "connected", "disconnected", "error:<msg>".
  Stream<String> get state =>
      _stateStream ??= _events.receiveBroadcastStream().map((e) => e.toString());

  /// Pede a autorizacao de VPN ao usuario (dialogo do sistema).
  /// Retorna true se ja estava autorizada ou se o usuario aceitou agora.
  Future<bool> prepare() async {
    try {
      return await _method.invokeMethod<bool>('prepare') ?? false;
    } on PlatformException catch (error) {
      throw TunnelException(
        'Nao foi possivel pedir a permissao de VPN.',
        detail: error.message,
      );
    }
  }

  Future<void> start({
    required int socksPort,
    required String bypassHost,
    String? sessionName,
  }) async {
    final allowed = await prepare();
    if (!allowed) {
      throw const TunnelException(
        'Voce precisa autorizar a VPN para o trafego passar pelo tunel.',
      );
    }

    try {
      await _method.invokeMethod<void>('start', {
        'socksPort': socksPort,
        'bypassHost': bypassHost,
        'sessionName': sessionName ?? 'Tunnel',
      });
    } on PlatformException catch (error) {
      throw TunnelException('A VPN nao subiu.', detail: error.message);
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } on PlatformException {
      // Parar algo que ja caiu nao e erro que o usuario precise ver.
    } on MissingPluginException {
      // Rodando fora do Android.
    }
  }

  Future<bool> isRunning() async {
    try {
      return await _method.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Bytes recebidos e enviados pelo tunel desde a conexao.
  ///
  /// Vem do proprio motor nativo, entao reflete o trafego real do aparelho —
  /// nao so o que o app moveu.
  Future<({int rx, int tx})> stats() async {
    try {
      final data = await _method.invokeMapMethod<String, Object?>('stats');
      return (
        rx: (data?['rx'] as num?)?.toInt() ?? 0,
        tx: (data?['tx'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (rx: 0, tx: 0);
    }
  }
}

import '../../models/models.dart';
import 'ssh_tunnel_service.dart';
import 'tunnel_service.dart';
import 'v2ray_tunnel_service.dart';

/// Escolhe o motor certo para cada payload.
///
/// Os dois motores implementam a mesma interface, entao a UI nunca sabe qual
/// esta em uso. Trocar de payload troca de motor de forma transparente.
class TunnelFactory {
  TunnelFactory._();

  static final _ssh = SshTunnelService();
  static V2RayTunnelService? _v2ray;

  static TunnelService forPayload(Payload payload) {
    if (payload.mode == 'V2RAY') {
      return _v2ray ??= V2RayTunnelService();
    }
    // SSH_DIRECT, SSH_PAYLOAD, SSH_SSL e, por ora, SLOWDNS/UDP caem no SSH.
    return _ssh;
  }

  /// Desliga tudo — chamado no dispose do AppState.
  static Future<void> disposeAll() async {
    await _ssh.dispose();
    await _v2ray?.dispose();
    _v2ray = null;
  }
}

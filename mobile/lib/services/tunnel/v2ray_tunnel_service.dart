import 'dart:async';

import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../../models/models.dart';
import 'tunnel_service.dart';

/// Motor para payloads V2Ray/Xray (links `vmess://`, `vless://`, `trojan://`).
///
/// Diferente do SSH, aqui o core nativo ja traz VpnService e tun2socks
/// prontos — nao ha nada a compilar. Se a sua operacao usa V2Ray, este e o
/// caminho que funciona sem nenhum passo extra de build.
///
/// O conteudo do payload cadastrado no painel deve ser o link completo.
class V2RayTunnelService implements TunnelService {
  V2RayTunnelService() {
    _engine = FlutterV2ray(onStatusChanged: _onStatusChanged);
  }

  late final FlutterV2ray _engine;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _logController = StreamController<String>.broadcast();

  bool _initialized = false;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  @override
  Stream<ConnectionStatus> get status => _statusController.stream;

  @override
  Stream<String> get logs => _logController.stream;

  @override
  ConnectionStatus get currentStatus => _status;

  void _emit(ConnectionStatus value) {
    _status = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  void _log(String message) {
    if (!_logController.isClosed) _logController.add(message);
    // ignore: avoid_print
    print('[v2ray] $message');
  }

  /// O core reporta o estado por conta propria; traduzimos para o enum da UI.
  void _onStatusChanged(V2RayStatus status) {
    switch (status.state.toUpperCase()) {
      case 'CONNECTED':
        _emit(ConnectionStatus.connected);
        break;
      case 'CONNECTING':
        _emit(ConnectionStatus.connecting);
        break;
      case 'DISCONNECTED':
        _emit(ConnectionStatus.disconnected);
        break;
      case 'ERROR':
        _emit(ConnectionStatus.error);
        break;
      default:
        _log('estado do core: ${status.state}');
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _engine.initializeV2Ray();
    _initialized = true;
  }

  @override
  Future<void> connect(
    Payload payload, {
    required String username,
    required String password,
    List<String> bypassPackages = const [],
  }) async {
    _emit(ConnectionStatus.connecting);

    try {
      await _ensureInitialized();

      final link = payload.content.trim();
      if (link.isEmpty) {
        throw const TunnelException('Este payload V2Ray esta sem o link de conexao.');
      }

      final allowed = await _engine.requestPermission();
      if (!allowed) {
        throw const TunnelException(
          'Voce precisa autorizar a VPN para o trafego passar pelo tunel.',
        );
      }

      final parsed = FlutterV2ray.parseFromURL(link);
      _log('conectando em ${parsed.remark}');

      await _engine.startV2Ray(
        remark: payload.name,
        config: parsed.getFullConfiguration(),
        // O flutter_v2ray tem split tunneling proprio: blockedApps ficam fora.
        blockedApps: bypassPackages.isEmpty ? null : bypassPackages,
        proxyOnly: false,
      );
    } on TunnelException {
      _emit(ConnectionStatus.error);
      rethrow;
    } catch (error) {
      _log('falha: $error');
      _emit(ConnectionStatus.error);
      throw TunnelException('Nao foi possivel conectar via V2Ray.', detail: error);
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _engine.stopV2Ray();
    } catch (error) {
      _log('erro ao desconectar: $error');
    }
    _emit(ConnectionStatus.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _statusController.close();
    await _logController.close();
  }
}

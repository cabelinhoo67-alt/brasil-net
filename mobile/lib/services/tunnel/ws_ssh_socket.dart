import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'tunnel_service.dart';

/// Adaptador de [WebSocketChannel] para o [SSHSocket] que o dartssh2 espera.
///
/// O fluxo bruto do protocolo SSH (banner, key exchange, tudo) vira frames
/// binarios de WebSocket, um a um — do lado do servidor, um bridge simples
/// (ver vps-agent/ws-bridge) devolve o frame para o sshd local e vice-versa.
/// Para o dartssh2, isto e so mais um socket: ele nao sabe que esta rodando
/// dentro de HTTPS.
class WebSocketSSHSocket implements SSHSocket {
  WebSocketSSHSocket(this._channel) {
    _subscription = _channel.stream.listen(
      _onData,
      onDone: _handleClosed,
      onError: _handleError,
      cancelOnError: false,
    );

    _incoming.onCancel = () => _subscription.cancel();
    _outgoing.stream.listen(
      (data) => _channel.sink.add(Uint8List.fromList(data)),
      onDone: _handleSinkDone,
    );
  }

  /// Conecta e espera o handshake HTTP/WebSocket completar (101 Switching
  /// Protocols) antes de devolver o socket — sem isso, escrever bytes SSH
  /// cedo demais quebraria o upgrade.
  ///
  /// [headers] sao headers HTTP extras enviados no pedido de upgrade (ex.:
  /// `Origin`, `User-Agent` de navegador) para a conexao parecer HTTPS comum
  /// para a operadora. O runtime ja envia `Connection: Upgrade`,
  /// `Upgrade: websocket` e `Sec-WebSocket-*` automaticamente.
  static Future<WebSocketSSHSocket> connect(
    String url, {
    required Duration timeout,
    Map<String, dynamic> headers = const {},
  }) async {
    // IOWebSocketChannel.connect e o unico construtor que aceita headers
    // customizados (camuflagem de navegador). O WebSocketChannel.connect
    // generico nao expoe esse parametro.
    final channel = IOWebSocketChannel.connect(
      Uri.parse(url),
      headers: headers,
    );

    try {
      await channel.ready.timeout(
        timeout,
        onTimeout: () => throw TunnelException(
          'O servidor WebSocket nao respondeu ao handshake ($url).',
        ),
      );
    } catch (error) {
      // Nunca aguardar sink.close() no caminho de erro. Num black-hole de
      // rede (a operadora bloqueia o dominio sem responder), o close do canal
      // fica pendurado esperando o socket subjacente finalizar — e a tentativa
      // inteira morreria no deadline generico da cadeia, reportando
      // "Sem resposta do servidor em 20s" sem a causa real. Fecha em segundo
      // plano com teto proprio e propaga o erro imediatamente.
      unawaited(() async {
        try {
          await channel.sink.close().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Canal ja fechado ou handshake nunca terminou — nada a fazer.
        }
      }());

      if (error is TunnelException) rethrow;
      throw TunnelException('Falha ao conectar via WebSocket.', detail: error);
    }

    return WebSocketSSHSocket(channel);
  }

  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _subscription;

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  void _onData(dynamic data) {
    if (_incoming.isClosed) return;
    // O servidor deve mandar sempre binario; texto e descartado em vez de
    // corromper o stream SSH (um frame de texto no meio quebraria tudo).
    if (data is Uint8List) {
      _incoming.add(data);
    } else if (data is List<int>) {
      _incoming.add(Uint8List.fromList(data));
    }
  }

  void _handleSinkDone() {
    try {
      _channel.sink.close();
    } catch (_) {}
  }

  void _handleError(Object error) {
    if (!_incoming.isClosed) _incoming.addError(error);
    _handleClosed();
  }

  void _handleClosed() {
    if (_closed) return;
    _closed = true;

    if (!_incoming.isClosed) _incoming.close();
    if (!_outgoing.isClosed) _outgoing.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();

    _subscription.cancel();
    try {
      _channel.sink.close();
    } catch (_) {}
  }

  @override
  void destroy() => _handleClosed();

  @override
  Future<void> close() async {
    _handleClosed();
    await _doneCompleter.future;
  }

  @override
  Future<void> flush() async {}
}

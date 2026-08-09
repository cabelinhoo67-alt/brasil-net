import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Adaptador de [RawSocket] para o [SSHSocket] que o dartssh2 espera.
///
/// Usamos `RawSocket` em vez de `Socket` de proposito: o handshake do payload
/// precisa ler a resposta do proxy ANTES do TLS comecar, e so o `RawSocket`
/// permite entregar a assinatura em andamento para
/// `RawSecureSocket.secure(subscription: ...)`. Com `Socket` comum, listar o
/// stream inviabiliza o upgrade para TLS depois.
class RawSSHSocket implements SSHSocket {
  RawSSHSocket(
    this._raw, {
    StreamSubscription<RawSocketEvent>? subscription,
    Uint8List? leftover,
  }) {
    _subscription = subscription ?? _raw.listen(_onEvent);
    // Assinatura herdada de outra fase (ex.: pos-TLS) precisa apontar para ca.
    _subscription.onData(_onEvent);
    _subscription.onDone(_handleClosed);
    _subscription.onError(_handleError);

    _incoming.onCancel = () => _subscription.cancel();
    _outgoing.stream.listen(_enqueue, onDone: _handleSinkDone);

    // O banner SSH pode chegar no mesmo segmento TCP da resposta do proxy.
    // Esses bytes ja saíram do socket e precisam entrar no stream antes de
    // qualquer coisa nova — sem isso o handshake SSH falha por banner ausente.
    if (leftover != null && leftover.isNotEmpty) {
      scheduleMicrotask(() {
        if (!_incoming.isClosed) _incoming.add(leftover);
      });
    }
  }

  final RawSocket _raw;
  late final StreamSubscription<RawSocketEvent> _subscription;

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _doneCompleter = Completer<void>();

  final _pending = BytesBuilder(copy: false);
  bool _writable = true;
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _doneCompleter.future;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _raw.read();
        if (data != null && data.isNotEmpty && !_incoming.isClosed) {
          _incoming.add(data);
        }
        break;

      case RawSocketEvent.write:
        _writable = true;
        _flush();
        break;

      case RawSocketEvent.readClosed:
        _handleClosed();
        break;

      case RawSocketEvent.closed:
        _handleClosed();
        break;
    }
  }

  void _enqueue(List<int> data) {
    if (_closed) return;
    _pending.add(data);
    _flush();
  }

  /// `RawSocket.write` pode escrever menos bytes do que o pedido; o excedente
  /// volta para a fila e sai no proximo evento de escrita.
  void _flush() {
    if (_closed || !_writable || _pending.isEmpty) return;

    final chunk = _pending.takeBytes();

    int written;
    try {
      written = _raw.write(chunk);
    } catch (error) {
      _handleError(error);
      return;
    }

    if (written < chunk.length) {
      _pending.add(Uint8List.sublistView(chunk, written));
      _writable = false;
      _raw.writeEventsEnabled = true;
    }
  }

  void _handleSinkDone() {
    // Espera o buffer esvaziar antes de sinalizar fim de escrita.
    if (_pending.isEmpty && !_closed) {
      try {
        _raw.shutdown(SocketDirection.send);
      } catch (_) {
        /* socket ja fechado */
      }
    }
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
      _raw.close();
    } catch (_) {
      /* ja fechado */
    }
  }

  @override
  void destroy() => _handleClosed();

  /// Empurra o que estiver na fila de saida.
  ///
  /// `implements SSHSocket` obriga a implementar todos os membros da interface,
  /// inclusive os que tem corpo padrao — por isso este metodo existe. O que nao
  /// couber no buffer do socket sai nos proximos eventos de escrita.
  @override
  Future<void> flush() async {
    _flush();
  }

  @override
  Future<void> close() async {
    _handleClosed();
    await _doneCompleter.future;
  }
}

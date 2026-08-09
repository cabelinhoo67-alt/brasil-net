import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Servidor SOCKS5 local que entrega cada conexao ao tunel SSH.
///
/// E a peca que liga os dois mundos: o tun2socks (lado nativo) fala SOCKS5
/// com este servidor, e cada conexao aceita aqui vira um canal
/// `direct-tcpip` dentro da sessao SSH ja autenticada.
///
/// Implementa o subset do RFC 1928 que importa na pratica:
/// autenticacao "no auth" e comando CONNECT, com destino em IPv4, IPv6 ou
/// nome de dominio. BIND e UDP ASSOCIATE nao sao suportados — nenhum
/// tun2socks usado neste cenario precisa deles para TCP.
class Socks5Server {
  Socks5Server({required this.openChannel, this.onLog});

  /// Abre um canal no tunel para `host:port`.
  /// Devolve um par de streams ja conectado ao destino remoto.
  final Future<TunnelChannel> Function(String host, int port) openChannel;

  final void Function(String message)? onLog;

  ServerSocket? _server;
  final _clients = <Socket>{};

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  /// Sobe o servidor em 127.0.0.1. Porta 0 deixa o SO escolher uma livre.
  Future<int> start({int desiredPort = 0}) async {
    await stop();

    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      desiredPort,
      shared: false,
    );
    _server = server;

    server.listen(
      _handleClient,
      onError: (Object error) => onLog?.call('socks: erro no accept: $error'),
      cancelOnError: false,
    );

    onLog?.call('socks5 escutando em 127.0.0.1:${server.port}');
    return server.port;
  }

  Future<void> stop() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();

    await _server?.close();
    _server = null;
  }

  Future<void> _handleClient(Socket client) async {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);

    final reader = _ByteReader(client);

    try {
      await _handshake(client, reader);
      final target = await _readConnectRequest(client, reader);

      final TunnelChannel channel;
      try {
        channel = await openChannel(target.host, target.port);
      } catch (error) {
        onLog?.call('socks: falha ao abrir ${target.host}:${target.port} — $error');
        _reply(client, _RepCode.hostUnreachable);
        await client.close();
        return;
      }

      _reply(client, _RepCode.success);

      // A partir daqui e so encanamento: cliente <-> canal SSH.
      await _pipe(client, channel, reader);
    } on _SocksException catch (error) {
      onLog?.call('socks: ${error.message}');
      client.destroy();
    } catch (error) {
      onLog?.call('socks: erro inesperado: $error');
      client.destroy();
    } finally {
      _clients.remove(client);
    }
  }

  /// Negociacao de metodo: aceitamos apenas "sem autenticacao" (0x00).
  Future<void> _handshake(Socket client, _ByteReader reader) async {
    final version = await reader.readByte();
    if (version != 0x05) {
      throw _SocksException('versao SOCKS nao suportada: $version');
    }

    final methodCount = await reader.readByte();
    final methods = await reader.readBytes(methodCount);

    if (!methods.contains(0x00)) {
      client.add([0x05, 0xff]); // nenhum metodo aceitavel
      await client.flush();
      throw _SocksException('cliente nao aceita conexao sem autenticacao');
    }

    client.add([0x05, 0x00]);
    await client.flush();
  }

  Future<_Target> _readConnectRequest(Socket client, _ByteReader reader) async {
    final version = await reader.readByte();
    final command = await reader.readByte();
    await reader.readByte(); // RSV, sempre 0x00
    final addressType = await reader.readByte();

    if (version != 0x05) throw _SocksException('versao invalida no request');

    if (command != 0x01) {
      _reply(client, _RepCode.commandNotSupported);
      throw _SocksException('comando $command nao suportado (so CONNECT)');
    }

    final String host;
    switch (addressType) {
      case 0x01: // IPv4
        final raw = await reader.readBytes(4);
        host = raw.join('.');
        break;

      case 0x03: // nome de dominio
        final length = await reader.readByte();
        final raw = await reader.readBytes(length);
        host = String.fromCharCodes(raw);
        break;

      case 0x04: // IPv6
        final raw = await reader.readBytes(16);
        final parts = <String>[];
        for (var i = 0; i < 16; i += 2) {
          parts.add(((raw[i] << 8) | raw[i + 1]).toRadixString(16));
        }
        host = parts.join(':');
        break;

      default:
        _reply(client, _RepCode.addressTypeNotSupported);
        throw _SocksException('tipo de endereco $addressType nao suportado');
    }

    final portBytes = await reader.readBytes(2);
    final port = (portBytes[0] << 8) | portBytes[1];

    return _Target(host, port);
  }

  /// Resposta do CONNECT. Devolvemos 0.0.0.0:0 como endereco de bind:
  /// e aceito e evita expor o IP real do tunel ao cliente local.
  void _reply(Socket client, int code) {
    try {
      client.add([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    } catch (_) {
      // socket ja morreu; nada a fazer
    }
  }

  Future<void> _pipe(Socket client, TunnelChannel channel, _ByteReader reader) async {
    final completer = Completer<void>();
    var closed = false;

    Future<void> shutdown() async {
      if (closed) return;
      closed = true;

      try {
        await channel.close();
      } catch (_) {
        /* ignorado */
      }
      client.destroy();

      if (!completer.isCompleted) completer.complete();
    }

    // Bytes que sobraram do buffer do handshake precisam ir primeiro,
    // senao perdemos o inicio do payload do cliente.
    final leftover = reader.takeBuffered();
    if (leftover.isNotEmpty) channel.sink.add(leftover);

    reader.releaseTo(
      onData: (data) => channel.sink.add(data),
      onDone: shutdown,
      onError: (_) => shutdown(),
    );

    channel.stream.listen(
      (data) {
        try {
          client.add(data);
        } catch (_) {
          shutdown();
        }
      },
      onDone: shutdown,
      onError: (_) => shutdown(),
      cancelOnError: true,
    );

    return completer.future;
  }
}

/// Canal ja aberto dentro do tunel (implementado pelo motor SSH).
class TunnelChannel {
  TunnelChannel({required this.stream, required this.sink, required this.close});

  final Stream<Uint8List> stream;
  final StreamSink<List<int>> sink;
  final Future<void> Function() close;
}

class _Target {
  const _Target(this.host, this.port);
  final String host;
  final int port;
}

class _SocksException implements Exception {
  const _SocksException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _RepCode {
  static const success = 0x00;
  static const hostUnreachable = 0x04;
  static const commandNotSupported = 0x07;
  static const addressTypeNotSupported = 0x08;
}

/// Leitor byte a byte sobre o socket.
///
/// O handshake SOCKS precisa ler quantidades exatas de bytes antes de
/// entregar o restante ao tunel; esta classe segura o excedente e depois
/// devolve o controle do stream com [releaseTo].
class _ByteReader {
  _ByteReader(Socket socket) {
    _subscription = socket.listen(
      (data) {
        if (_released) {
          _onData?.call(data);
          return;
        }
        _buffer.addAll(data);
        _drain();
      },
      onDone: () {
        _done = true;
        if (_released) {
          _onDone?.call();
        } else {
          _drain();
        }
      },
      onError: (Object error) {
        if (_released) {
          _onError?.call(error);
        } else {
          _failPending(error);
        }
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = <int>[];
  final _pending = <_PendingRead>[];

  bool _done = false;
  bool _released = false;

  void Function(Uint8List data)? _onData;
  void Function()? _onDone;
  void Function(Object error)? _onError;

  Future<int> readByte() async => (await readBytes(1)).first;

  Future<Uint8List> readBytes(int count) {
    if (count == 0) return Future.value(Uint8List(0));

    final completer = Completer<Uint8List>();
    _pending.add(_PendingRead(count, completer));
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_pending.isNotEmpty && _buffer.length >= _pending.first.count) {
      final request = _pending.removeAt(0);
      final data = Uint8List.fromList(_buffer.sublist(0, request.count));
      _buffer.removeRange(0, request.count);
      request.completer.complete(data);
    }

    if (_done && _pending.isNotEmpty) {
      _failPending(const _SocksException('conexao encerrada no meio do handshake'));
    }
  }

  void _failPending(Object error) {
    for (final request in _pending) {
      if (!request.completer.isCompleted) request.completer.completeError(error);
    }
    _pending.clear();
  }

  /// Bytes ja recebidos que ainda nao foram consumidos pelo handshake.
  Uint8List takeBuffered() {
    final data = Uint8List.fromList(_buffer);
    _buffer.clear();
    return data;
  }

  /// Passa o stream adiante — do ponto de vista do chamador, o socket volta
  /// a ser um stream normal.
  void releaseTo({
    required void Function(Uint8List data) onData,
    required void Function() onDone,
    required void Function(Object error) onError,
  }) {
    _onData = onData;
    _onDone = onDone;
    _onError = onError;
    _released = true;

    if (_done) onDone();
  }

  Future<void> cancel() => _subscription.cancel();
}

class _PendingRead {
  _PendingRead(this.count, this.completer);
  final int count;
  final Completer<Uint8List> completer;
}

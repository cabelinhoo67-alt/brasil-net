import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'payload_parser.dart';

/// Resultado de uma tentativa de escrita fragmentada.
@immutable
class WriteReport {
  const WriteReport({
    required this.segmentsWritten,
    required this.totalBytes,
    this.durations,
  });

  /// Quantos segmentos foram efetivamente enviados.
  final int segmentsWritten;

  /// Total de bytes escritos (soma dos segmentos).
  final int totalBytes;

  /// Tempo gasto por segmento (mesma ordem dos segmentos enviados).
  final List<Duration>? durations;

  @override
  String toString() =>
      'WriteReport($segmentsWritten segmentos, $totalBytes bytes)';
}

/// Excecao tipada para falhas de I/O do socket de tunel.
class TunnelSocketException implements Exception {
  const TunnelSocketException(this.message, {this.detail, this.timeout = false});

  final String message;
  final Object? detail;
  final bool timeout;

  @override
  String toString() => detail == null
      ? 'TunnelSocketException: $message'
      : 'TunnelSocketException: $message ($detail)';
}

/// Wrapper de socket TCP/SSL com suporte a escrita fragmentada (MTU slicing)
/// e injecao de payload segmentada no nivel de fluxo de bytes.
///
/// Encapsula [Socket] ou [SecureSocket] e expoe:
///
///  - [writeFragmented]: envia cada [PayloadSegment] como um write + flush
///    distinto, respeitando o atraso configurado entre segmentos — o que gera
///    multiplos quadros TCP no meio do handshake HTTP (evasao de DPI por
///    fragmentacao de pacotes).
///  - [writeFragmentedLoop]: variante com deadline global, protegendo contra
///    zero-window/black-hole da operadora durante o envio.
///  - [upgradeToTls]: promove o socket TCP para TLS/SSL (SNI custom) apos a
///    injecao do payload — padrao "connect + upgrade".
class TunnelSocket {
  TunnelSocket._(Socket socket) : _socket = socket;

  /// Abre uma conexao TCP crua, ja com `TCP_NODELAY` (envio imediato dos
  /// segmentos, sem coalescencia Nagle).
  static Future<TunnelSocket> connectTcp(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final raw = await _connectRaw(host, port, timeout);
    raw.setOption(SocketOption.tcpNoDelay, true);
    return TunnelSocket._(raw);
  }

  /// Abre uma conexao TCP e promove a TLS/SSL imediatamente (modo "SSL puro").
  static Future<TunnelSocket> connectTls(
    String host,
    int port, {
    String? sni,
    bool Function(X509Certificate certificate)? onBadCertificate,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final raw = await _connectRaw(host, port, timeout);
    raw.setOption(SocketOption.tcpNoDelay, true);
    final socket = TunnelSocket._(raw);
    await socket.upgradeToTls(
      sni: sni ?? host,
      onBadCertificate: onBadCertificate,
      timeout: timeout,
    );
    return socket;
  }

  static Future<Socket> _connectRaw(String host, int port, Duration timeout) async {
    try {
      return await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (error) {
      throw TunnelSocketException(
        'Nao consegui alcancar $host:$port.',
        detail: error.osError?.message ?? error.message,
      );
    } on TimeoutException {
      throw TunnelSocketException(
        'Tempo esgotado ao conectar em $host:$port.',
        timeout: true,
      );
    }
  }

  final Socket _socket;
  SecureSocket? _secure;
  bool _closed = false;

  /// `true` quando o transporte subjacente e TLS/SSL.
  bool get isTls => _secure != null;

  /// `true` quando o socket foi fechado.
  bool get isClosed => _closed;

  /// Sink de escrita ativo (delega ao SecureSocket quando promovido).
  IOSink get _sink => _secure ?? _socket;

  /// Stream de dados recebidos (delega ao transporte ativo).
  Stream<List<int>> get stream => (_secure ?? _socket).cast<List<int>>();

  /// Endereco remoto da conexao subjacente.
  InternetAddress? get remoteAddress => _secure?.remoteAddress ?? _socket.remoteAddress;

  /// Escreve um unico segmento e faz flush imediato (envio na hora).
  Future<void> writeSegment(PayloadSegment segment) async {
    _ensureOpen();
    _sink.add(segment.data);
    await _sink.flush();
  }

  /// Envia os segmentos um a um com flush apos cada um, respeitando os
  /// atrasos — a fragmentacao TCP (MTU slicing) que engana a inspecao de
  /// estado de DPI durante o handshake.
  ///
  /// Cada segmento se torna um quadro TCP distinto por causa do flush
  /// explicito; sem ele, o kernel coalesceria os writes no proximo pacote.
  Future<WriteReport> writeFragmented(List<PayloadSegment> segments) async {
    if (segments.isEmpty) {
      return const WriteReport(segmentsWritten: 0, totalBytes: 0);
    }

    var written = 0;
    var total = 0;
    final durations = <Duration>[];

    for (final segment in segments) {
      _ensureOpen();

      final sw = Stopwatch()..start();
      _sink.add(segment.data);
      await _sink.flush();
      sw.stop();
      durations.add(sw.elapsed);

      written++;
      total += segment.data.length;

      if (segment.delayAfter > Duration.zero) {
        await Future<void>.delayed(segment.delayAfter);
      }
    }

    return WriteReport(
      segmentsWritten: written,
      totalBytes: total,
      durations: durations,
    );
  }

  /// Variante com deadline global: aborta com [TunnelSocketException] se a
  /// escrita inteira nao terminar dentro de [deadline] — protecao contra
  /// zero-window da operadora (o buffer TCP para de aceitar dados).
  Future<WriteReport> writeFragmentedLoop(
    List<PayloadSegment> segments, {
    Duration deadline = const Duration(seconds: 10),
  }) async {
    if (segments.isEmpty) {
      return const WriteReport(segmentsWritten: 0, totalBytes: 0);
    }

    final endAt = DateTime.now().add(deadline);
    var written = 0;
    var total = 0;

    for (final segment in segments) {
      if (DateTime.now().isAfter(endAt)) {
        throw const TunnelSocketException(
          'A operadora parou de aceitar dados durante o envio do payload.',
          timeout: true,
        );
      }

      _ensureOpen();
      _sink.add(segment.data);
      await _sink.flush();

      written++;
      total += segment.data.length;

      if (segment.delayAfter > Duration.zero) {
        await Future<void>.delayed(segment.delayAfter);
      }
    }

    return WriteReport(segmentsWritten: written, totalBytes: total);
  }

  /// Promove o socket TCP para TLS/SSL (upgrade no meio do fluxo).
  ///
  /// Usado nos modos que conectam TCP, injetam o payload e so entao sobem o
  /// TLS com SNI custom. `onBadCertificate` default aceita certificados
  /// auto-assinados (a confidencialidade real vem do SSH por dentro).
  Future<void> upgradeToTls({
    String? sni,
    bool Function(X509Certificate certificate)? onBadCertificate,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (isTls) return;

    try {
      final secure = await SecureSocket.secure(
        _socket,
        host: sni ?? '',
        onBadCertificate: onBadCertificate ?? (_) => true,
      ).timeout(timeout);
      _secure = secure;
    } on TimeoutException {
      throw const TunnelSocketException(
        'Tempo esgotado no handshake TLS.',
        timeout: true,
      );
    } on TlsException catch (error) {
      throw TunnelSocketException(
        'Falha no TLS.',
        detail: error.osError?.message ?? error.message,
      );
    } on SocketException catch (error) {
      throw TunnelSocketException(
        'Falha no TLS.',
        detail: error.osError?.message ?? error.message,
      );
    }
  }

  /// Le a resposta HTTP do proxy ate o fim do cabecalho (`\r\n\r\n`).
  ///
  /// Usado apos a injecao do payload para validar o handshake: `200`
  /// (CONNECT aceito) ou `101` (Switching Protocols). A assinatura faz
  /// single-subscription na stream subjacente; por isso deve ser chamada
  /// antes de qualquer outro listener na mesma conexao.
  Future<Uint8List> readHeader({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    _ensureOpen();

    final buffer = BytesBuilder();
    final completer = Completer<Uint8List>();
    late StreamSubscription<List<int>> subscription;

    subscription = stream.listen(
      (chunk) {
        buffer.add(chunk);
        if (_hasHeaderEnd(buffer.toBytes())) {
          if (!completer.isCompleted) completer.complete(buffer.toBytes());
          unawaited(subscription.cancel());
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(buffer.toBytes());
      },
    );

    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        unawaited(subscription.cancel());
        throw const TunnelSocketException(
          'Tempo esgotado aguardando resposta do proxy.',
          timeout: true,
        );
      });
    } catch (_) {
      unawaited(subscription.cancel());
      rethrow;
    }
  }

  static bool _hasHeaderEnd(Uint8List data) {
    // Procura por \r\n\r\n (fim do cabecalho HTTP).
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return true;
      }
    }
    return false;
  }

  /// Fecha o socket de forma idempotente.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sink = _sink;
    try {
      await sink.flush();
    } catch (_) {
      /* ja fechado */
    }
    try {
      await sink.close();
    } catch (_) {
      /* ja fechado */
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const TunnelSocketException('Socket ja fechado.');
    }
  }
}

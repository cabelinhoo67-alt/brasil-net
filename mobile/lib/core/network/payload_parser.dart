import 'dart:math';

import 'package:flutter/foundation.dart';

/// Marcador que divide o envio em dois segmentos TCP imediatos.
const kInstantSplit = '[instant_split]';

/// Marcador que divide o envio em dois segmentos com pausa entre eles.
const kDelaySplit = '[delay_split]';

/// Roda completa de um payload: texto substituido + sequencia de segmentos
/// prontos para escrever no socket (pos-fragmentacao).
@immutable
class ParsedPayload {
  const ParsedPayload({
    required this.text,
    required this.segments,
    this.warning,
  });

  /// Payload com todos os placeholders resolvidos (sem os marcadores).
  final String text;

  /// Segmentos binarios na ordem de envio, com o atraso pos-envio de cada um.
  final List<PayloadSegment> segments;

  /// Aviso opcional do parser (ex.: placeholder desconhecido).
  final String? warning;

  /// Concatenacao de todos os segmentos (payload completo em bytes).
  Uint8List get bytes => Uint8List.fromList(
        segments.expand((s) => s.data).toList(),
      );

  @override
  String toString() =>
      'ParsedPayload(segments: ${segments.length}, bytes: ${bytes.length})';
}

/// Um segmento binario pronto para envio, com atraso opcional apos ele.
@immutable
class PayloadSegment {
  const PayloadSegment(this.data, {this.delayAfter = Duration.zero});

  final Uint8List data;

  /// Atraso a aguardar apos o envio deste segmento antes do proximo.
  final Duration delayAfter;

  @override
  String toString() =>
      'PayloadSegment(${data.length}B, delay: ${delayAfter.inMilliseconds}ms)';
}

/// Engine de parsing de payload com fragmentacao de bytes (DPI bypass).
///
/// Substitui marcadores no nivel de fluxo de bytes e divide o buffer em
/// segmentos no ponto exato dos marcadores de split:
///
///   - `[crlf]`           -> `\r\n`
///   - `[host]`           -> Host/SNI ativo
///   - `[seuid]`          -> identificador unico da sessao (UUID v4)
///   - `[raw]`            -> linha de request bruta sem sanitizacao
///   - `[instant_split]`  -> quebra o buffer; segmento 1 vai imediatamente
///   - `[delay_split:ms]` -> quebra o buffer; segmento 1 vai, espera X ms,
///                            entao o segmento 2 vai
///
/// Marcadores herdados do parser legado ([split], [delay_split], [host_port],
/// [port], [method], [protocol], [ua], [net_data], [lf], [cr]) continuam
/// aceitos para payloads existentes no painel.
class PayloadParserEngine {
  const PayloadParserEngine();

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0 Mobile Safari/537.36';

  // Tokens do parser legado (sem delay parametrizado).
  static const splitToken = '[split]';
  static const delaySplitToken = '[delay_split]';
  static const instantSplitToken = kInstantSplit;

  /// Renderiza o payload com todos os placeholders resolvidos (sem split).
  ///
  /// [sessionId] alimenta `[seuid]`; quando nulo, gera um UUID v4 a cada
  /// chamada. [host] alimenta `[host]` (e `[host_port]` junto com [port]).
  String render({
    required String payload,
    required String host,
    int port = 0,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
    String? userAgent,
    String? sessionId,
  }) {
    final seuid = sessionId ?? _uuidV4();
    final hostPort = host.isNotEmpty ? '$host:$port' : '';

    // Ordem deterministica: placeholders maiores primeiro ([host_port] antes
    // de [host]/[port]) para nao haver vazamento de substring.
    var out = payload
        .replaceAll('[host_port]', hostPort)
        .replaceAll('[host]', host)
        .replaceAll('[port]', port.toString())
        .replaceAll('[method]', method)
        .replaceAll('[seuid]', seuid)
        .replaceAll('[raw]', '$method $hostPort $protocol');

    return out
        .replaceAll('[protocol]', protocol)
        .replaceAll('[ua]', userAgent ?? _userAgent)
        .replaceAll('[net_data]', '')
        .replaceAll('[crlf]', '\r\n')
        .replaceAll('[lf]', '\n')
        .replaceAll('[cr]', '\r');
  }

  /// Divide o payload renderizado em segmentos de envio, respeitando os
  /// marcadores de split (instantaneo e com delay parametrizado).
  ///
  /// O atraso de um split e atribuido ao segmento ANTERIOR ao marcador: envia
  /// o primeiro pedaco, espera X ms, envia o restante. Sem marcadores, retorna
  /// um unico segmento com o payload completo.
  List<PayloadSegment> segments({
    required String payload,
    required String host,
    int port = 0,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
    String? userAgent,
    String? sessionId,
  }) {
    final rendered = render(
      payload: payload,
      host: host,
      port: port,
      method: method,
      protocol: protocol,
      userAgent: userAgent,
      sessionId: sessionId,
    );

    final result = <PayloadSegment>[];
    final tokens = _splitScan(rendered);

    if (tokens.isEmpty) {
      if (rendered.isNotEmpty) {
        result.add(PayloadSegment(_bytes(rendered)));
      }
      return result;
    }

    var cursor = 0;
    for (final token in tokens) {
      final head = rendered.substring(cursor, token.index);
      if (head.isNotEmpty) {
        result.add(PayloadSegment(_bytes(head)));
      }
      // Delay do split vai no segmento anterior (semantica do parser legado).
      if (token.delay != null && result.isNotEmpty) {
        result[result.length - 1] = PayloadSegment(
          result.last.data,
          delayAfter: token.delay!,
        );
      }
      cursor = token.index + token.length;
    }
    if (cursor < rendered.length) {
      result.add(PayloadSegment(_bytes(rendered.substring(cursor))));
    }

    return result.isEmpty ? [PayloadSegment(_bytes(rendered))] : result;
  }

  /// Resultado completo: texto renderizado + segmentos.
  ParsedPayload parse({
    required String payload,
    required String host,
    int port = 0,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
    String? userAgent,
    String? sessionId,
  }) {
    final text = render(
      payload: payload,
      host: host,
      port: port,
      method: method,
      protocol: protocol,
      userAgent: userAgent,
      sessionId: sessionId,
    );
    final segs = segments(
      payload: payload,
      host: host,
      port: port,
      method: method,
      protocol: protocol,
      userAgent: userAgent,
      sessionId: sessionId,
    );
    return ParsedPayload(text: text, segments: segs);
  }

  // ------------------------- scanner de splits -----------------------------

  static final RegExp _splitRegExp = RegExp(
    r'\[instant_split\]|\[delay_split(?::(\d+))?\]|\[split\]',
  );

  /// Encontra todos os marcadores de split no texto, em ordem de aparicao.
  static List<_SplitToken> _splitScan(String text) {
    final tokens = <_SplitToken>[];
    for (final m in _splitRegExp.allMatches(text)) {
      final raw = m.group(0)!;
      if (raw == kInstantSplit || raw == splitToken) {
        tokens.add(_SplitToken(m.start, raw.length, null));
      } else {
        // [delay_split] ou [delay_split:ms]
        Duration? delay;
        final msRaw = m.group(1);
        if (msRaw != null) {
          final ms = int.tryParse(msRaw);
          if (ms != null && ms > 0) delay = Duration(milliseconds: ms);
        }
        tokens.add(_SplitToken(
          m.start,
          raw.length,
          delay ?? const Duration(milliseconds: 200),
        ));
      }
    }
    return tokens;
  }

  // ------------------------- utilitarios ----------------------------------

  static Uint8List _bytes(String value) =>
      Uint8List.fromList(value.codeUnits.map((c) => c & 0xff).toList());

  /// UUID v4 criptograficamente aleatorio para `[seuid]`.
  static String _uuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // versao 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variante RFC 4122
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Um marcador de split encontrado no payload renderizado.
@immutable
class _SplitToken {
  const _SplitToken(this.index, this.length, this.delay);

  /// Posicao do marcador no texto renderizado.
  final int index;

  /// Comprimento do marcador (para avancar o cursor).
  final int length;

  /// Atraso pos-envio do segmento anterior (nulo = envio imediato).
  final Duration? delay;
}

/// Adapter de conveniencia: mantem a assinatura do parser legado
/// ([`PayloadParser`]) apontando para a nova engine, para que o codigo
/// existente continue compilando sem alteracoes.
class PayloadParser {
  const PayloadParser._();

  static const splitToken = PayloadParserEngine.splitToken;
  static const delaySplitToken = PayloadParserEngine.delaySplitToken;
  static const instantSplitToken = PayloadParserEngine.instantSplitToken;

  static String render({
    required String payload,
    required String host,
    required int port,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
    String? userAgent,
    String? sessionId,
  }) =>
      const PayloadParserEngine().render(
        payload: payload,
        host: host,
        port: port,
        method: method,
        protocol: protocol,
        userAgent: userAgent,
        sessionId: sessionId,
      );

  static List<PayloadChunk> chunks({
    required String payload,
    required String host,
    required int port,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
  }) {
    const engine = PayloadParserEngine();
    final segs = engine.segments(
      payload: payload,
      host: host,
      port: port,
      method: method,
      protocol: protocol,
    );
    return segs
        .map((s) => PayloadChunk(s.data, delayAfter: s.delayAfter))
        .toList();
  }
}

/// Chunk binario do parser legado.
class PayloadChunk {
  const PayloadChunk(this.data, {this.delayAfter = Duration.zero});

  final Uint8List data;
  final Duration delayAfter;
}

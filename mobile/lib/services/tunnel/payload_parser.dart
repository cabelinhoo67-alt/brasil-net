import 'dart:typed_data';

/// Traduz o payload cadastrado no painel para os bytes que vao no socket.
///
/// A sintaxe com colchetes e a mesma usada pelos injetores conhecidos, entao
/// payloads que voce ja tem continuam valendo:
///
///   CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]
///
/// Placeholders suportados:
///   [host]        host do servidor
///   [port]        porta de destino
///   [host_port]   host:porta
///   [protocol]    HTTP/1.1
///   [crlf] [lf] [cr]
///   [ua]          User-Agent
///   [raw]         linha de request bruta (metodo + host_port + protocolo)
///   [net_data]    marcador de dados da rede (removido: usado por alguns painies)
///   [split]       divide o envio em dois pacotes TCP
///   [delay_split] divide o envio com uma pausa entre os pacotes
class PayloadParser {
  const PayloadParser._();

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  /// Marcadores que quebram o envio em varios pacotes.
  static const splitToken = '[split]';
  static const delaySplitToken = '[delay_split]';

  static String render({
    required String payload,
    required String host,
    required int port,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
    String? userAgent,
  }) {
    final hostPort = '$host:$port';

    return payload
        .replaceAll('[host_port]', hostPort)
        .replaceAll('[host]', host)
        .replaceAll('[port]', '$port')
        .replaceAll('[protocol]', protocol)
        .replaceAll('[method]', method)
        .replaceAll('[raw]', '$method $hostPort $protocol')
        .replaceAll('[ua]', userAgent ?? _userAgent)
        .replaceAll('[net_data]', '')
        .replaceAll('[crlf]', '\r\n')
        .replaceAll('[lf]', '\n')
        .replaceAll('[cr]', '\r');
  }

  /// Quebra o payload nos marcadores de split, preservando a ordem.
  ///
  /// Cada parte vira um `write` separado no socket — e justamente essa
  /// fragmentacao que alguns payloads dependem para funcionar.
  static List<PayloadChunk> chunks({
    required String payload,
    required String host,
    required int port,
    String method = 'CONNECT',
    String protocol = 'HTTP/1.1',
  }) {
    final rendered = render(
      payload: payload,
      host: host,
      port: port,
      method: method,
      protocol: protocol,
    );

    final result = <PayloadChunk>[];
    var rest = rendered;

    while (true) {
      final splitAt = rest.indexOf(splitToken);
      final delayAt = rest.indexOf(delaySplitToken);

      // Nenhum marcador restante: o que sobrou e o ultimo pacote.
      if (splitAt < 0 && delayAt < 0) {
        if (rest.isNotEmpty) result.add(PayloadChunk(_bytes(rest)));
        break;
      }

      final useDelay = splitAt < 0 || (delayAt >= 0 && delayAt < splitAt);
      final index = useDelay ? delayAt : splitAt;
      final token = useDelay ? delaySplitToken : splitToken;

      final head = rest.substring(0, index);
      if (head.isNotEmpty) {
        result.add(PayloadChunk(
          _bytes(head),
          delayAfter: useDelay ? const Duration(milliseconds: 200) : Duration.zero,
        ));
      }
      rest = rest.substring(index + token.length);
    }

    return result;
  }

  static Uint8List _bytes(String value) =>
      Uint8List.fromList(value.codeUnits.map((c) => c & 0xff).toList());
}

class PayloadChunk {
  const PayloadChunk(this.data, {this.delayAfter = Duration.zero});

  final Uint8List data;
  final Duration delayAfter;
}

import 'dart:typed_data';

/// Deteccao de portal cativo da operadora.
///
/// Quando o chip esta sem saldo (ou fora do pacote de dados), a operadora nao
/// recusa a conexao: ela ACEITA o TCP e devolve um HTTP 302 apontando para a
/// pagina de recarga. Do ponto de vista do socket parece sucesso — e por isso
/// o SSH direto "conecta" e morre logo em seguida, sem erro claro.
///
/// Detectar isso cedo permite trocar de estrategia em vez de insistir.
class CaptivePortal {
  const CaptivePortal._();

  /// Dominios de recarga/portal das operadoras brasileiras. Aparecem no
  /// `Location:` do 302 ou no corpo da pagina de bloqueio.
  static const _knownHosts = <String>[
    'recarga',
    'meuplano',
    'portal',
    'captive',
    'bloqueio',
    'semcredito',
    'vivo.com.br',
    'claro.com.br',
    'tim.com.br',
    'oi.com.br',
    'algartelecom',
  ];

  /// Status HTTP que indicam interceptacao, nao sucesso do tunel.
  static const _redirectCodes = <int>[301, 302, 303, 307, 308];

  /// Analisa a primeira resposta recebida no socket.
  ///
  /// Um servidor SSH responde com o banner `SSH-2.0-...`. Se o que voltou for
  /// HTTP, alguem no meio interceptou.
  static PortalVerdict inspect(Uint8List data) {
    if (data.isEmpty) return PortalVerdict.inconclusive;

    // Le so o cabecalho; o corpo pode ser grande e nao interessa aqui.
    final head = String.fromCharCodes(
      data.take(1024).toList(),
    ).toLowerCase();

    // Banner SSH: caminho limpo, nao ha portal.
    if (head.startsWith('ssh-')) return PortalVerdict.clean;

    if (!head.startsWith('http/')) {
      // Nao e HTTP nem SSH — pode ser TLS ou lixo; deixa o handshake decidir.
      return PortalVerdict.inconclusive;
    }

    final statusMatch = RegExp(r'^http/\d\.\d\s+(\d{3})').firstMatch(head);
    final status = int.tryParse(statusMatch?.group(1) ?? '') ?? 0;

    // 200 aqui e a resposta do proxy ao CONNECT: transporte estabelecido.
    if (status == 200 || status == 101) return PortalVerdict.clean;

    if (_redirectCodes.contains(status)) {
      return PortalVerdict.portal;
    }

    // 403/511 sao usados por portais que nao redirecionam.
    if (status == 403 || status == 511) return PortalVerdict.portal;

    // Qualquer HTTP inesperado no lugar do banner SSH e interceptacao.
    if (_knownHosts.any(head.contains)) return PortalVerdict.portal;

    return PortalVerdict.blocked;
  }

  /// Extrai para onde o portal quer mandar o usuario — util no log de suporte.
  static String? redirectTarget(Uint8List data) {
    final head = String.fromCharCodes(data.take(1024).toList());
    final match = RegExp(
      r'location:\s*(\S+)',
      caseSensitive: false,
    ).firstMatch(head);
    return match?.group(1);
  }
}

enum PortalVerdict {
  /// Caminho limpo: banner SSH ou CONNECT aceito.
  clean,

  /// Operadora interceptou (302 para recarga, 511, pagina de bloqueio).
  portal,

  /// Resposta HTTP inesperada — tratada como bloqueio.
  blocked,

  /// Nao da para afirmar; deixe o handshake seguir.
  inconclusive,
}

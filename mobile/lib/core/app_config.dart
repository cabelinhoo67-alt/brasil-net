class AppConfig {
  AppConfig._();

  /// URL do backend.
  ///
  /// O padrao e SEMPRE producao — um build de release sem --dart-define
  /// precisa funcionar em qualquer aparelho fisico, entao o valor de dev
  /// (emulador/rede local) e opt-in, nunca o silencioso default de build.
  /// String.fromEnvironment resolve em tempo de COMPILACAO: esquecer de
  /// passar a flag em dev cai em producao (seguro); esquecer em release
  /// nunca mais aponta pro localhost de ninguem (o bug que gerou o
  /// timeout de 15s em campo — ver docs/TUNNEL.md).
  ///
  /// Para apontar pro seu ambiente de dev:
  ///   Emulador Android:      --dart-define=API_URL=http://10.0.2.2:3333
  ///   Aparelho fisico na rede: --dart-define=API_URL=http://192.168.0.15:3333
  static const String apiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://brasilnetpro.click',
  );

  static const String appName = 'Tunnel App';

  /// Intervalo do heartbeat enviado ao backend (controle de conexoes).
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// Intervalo de medicao de ping exibido na tela principal.
  static const Duration pingInterval = Duration(seconds: 5);

  /// Teto por requisicao. Curto de proposito: em rede movel ruim e melhor
  /// falhar com mensagem clara do que deixar a tela travada.
  static const Duration requestTimeout = Duration(seconds: 15);
}

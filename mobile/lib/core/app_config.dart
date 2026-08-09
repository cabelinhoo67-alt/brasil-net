class AppConfig {
  AppConfig._();

  /// URL do backend.
  ///
  /// Emulador Android: 10.0.2.2 aponta para o localhost do PC.
  /// Aparelho fisico na mesma rede: use o IP da maquina (ex.: 192.168.0.15).
  /// Producao: informe o dominio com https.
  ///
  /// Sobrescreva sem editar o codigo:
  ///   flutter run --dart-define=API_URL=http://192.168.0.15:3333
  static const String apiUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://10.0.2.2:3333',
  );

  static const String appName = 'Tunnel App';

  /// Intervalo do heartbeat enviado ao backend (controle de conexoes).
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// Intervalo de medicao de ping exibido na tela principal.
  static const Duration pingInterval = Duration(seconds: 5);

  static const Duration requestTimeout = Duration(seconds: 20);
}

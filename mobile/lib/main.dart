import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_config.dart';
import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'services/app_state.dart';
import 'services/location_consent.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TunnelApp());
}

class TunnelApp extends StatelessWidget {
  const TunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..bootstrap(),
      child: MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _askedLocation = false;

  /// O consentimento de localizacao e pedido aqui, e nao dentro das telas,
  /// para valer tanto para quem faz login agora quanto para quem entra
  /// direto pelo "manter conectado" — os dois caminhos passam por este ponto.
  void _maybeAskLocation() {
    if (_askedLocation) return;
    _askedLocation = true;

    // Espera o primeiro frame: abrir dialogo durante o build quebra.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) LocationConsent.maybeAsk(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.booting) return const SplashScreen();

    _maybeAskLocation();

    return state.isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}

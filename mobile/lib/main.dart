import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_config.dart';
import 'core/network/connection_manager.dart';
import 'core/theme.dart';
import 'features/config/presentation/controllers/config_controller.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'services/app_state.dart';
import 'services/location_consent.dart';
import 'services/ota_service.dart';
import 'widgets/update_modal.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TunnelApp());
}

class TunnelApp extends StatelessWidget {
  const TunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()..bootstrap()),
        ChangeNotifierProvider(create: (_) => OtaService()),
        // Remote Control Plane: sincroniza payloads/proxies/SNIs com o
        // servidor remoto. O onApplied injeta a config nova no manager ativo
        // (hot reload sem reiniciar o app).
        ChangeNotifierProvider(
          create: (_) => ConfigController(
            onApplied: (config) => TunnelConnectionManager.instance.applyConfig(config),
          )..loadActive(),
        ),
      ],
      child: MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        // O UpdateGate envolve TODAS as rotas: o modal de atualizacao aparece
        // por cima de qualquer tela, sem entrar na pilha de navegacao.
        builder: (context, child) => UpdateGate(child: child ?? const SizedBox()),
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

class _RootState extends State<_Root> with WidgetsBindingObserver {
  bool _askedLocation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Checa OTA e sincroniza a configuracao remota na abertura (silencioso).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<OtaService>().check();
      context.read<ConfigController>().check(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retomar o app rechecа atualizacao — cobre o caso do usuario ficar dias com
  /// o app em segundo plano. Tambem reavalia a permissao de overlay: e o
  /// momento em que o usuario volta da tela de permissao do sistema.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<OtaService>().check();
      context.read<AppState>().recheckOverlayPermission();
    }
  }

  /// O consentimento de localizacao e pedido aqui, e nao dentro das telas,
  /// para valer tanto para quem faz login agora quanto para quem entra
  /// direto pelo "manter conectado" — os dois caminhos passam por este ponto.
  void _maybeAskLocation() {
    if (_askedLocation) return;
    _askedLocation = true;

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

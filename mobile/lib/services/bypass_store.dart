import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lista de apps que ficam FORA do tunel (split tunneling).
///
/// Por que existe: o trafego de apps de mobilidade e bancos, quando sai por um
/// IP de datacenter, aciona o antifraude deles. Mantendo esses apps fora do
/// tunel, eles seguem pela rede real da operadora e nao levantam suspeita — e o
/// resto do aparelho continua protegido.
class BypassStore extends ChangeNotifier {
  static const _key = 'bypass_packages';
  static const _seededKey = 'bypass_seeded';

  /// Blindagem antifraude aplicada no primeiro boot.
  ///
  /// Apps de mobilidade, navegacao e bancos que NAO devem enxergar o IP do
  /// tunel. Sao ativados por padrao porque errar para o lado seguro aqui evita
  /// o pior cenario — um motorista tomar ban por rodar o app de corrida sobre
  /// um IP de datacenter.
  static const defaultPackages = <String>{
    // Mobilidade
    'com.ubercab.driver',
    'com.taxis99',
    'sinet.startup.inDriver',
    // Navegacao (o antifraude cruza a localizacao com a rota)
    'com.waze',
    'com.google.android.apps.maps',
    // Bancos
    'br.com.nubank',
    'com.itau',
    'br.com.inter',
    'br.com.caixa',
    'br.com.bradesco',
    'br.com.santander.app',
  };

  final Set<String> _packages = {};
  bool _loaded = false;

  bool get loaded => _loaded;
  Set<String> get packages => Set.unmodifiable(_packages);
  int get count => _packages.length;

  bool contains(String pkg) => _packages.contains(pkg);

  /// Apps da blindagem antifraude. Removê-los e o que causa ban de motorista,
  /// entao a UI avisa antes de deixar desligar — nao e proibido, mas exige
  /// confirmacao consciente.
  bool isProtected(String pkg) => defaultPackages.contains(pkg);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // Primeiro boot: semeia a lista de blindagem. `_seededKey` garante que,
    // se o usuario limpar tudo depois, nao ressemeamos por cima da escolha dele.
    if (!(prefs.getBool(_seededKey) ?? false)) {
      _packages
        ..clear()
        ..addAll(defaultPackages);
      await prefs.setStringList(_key, _packages.toList());
      await prefs.setBool(_seededKey, true);
    } else {
      _packages
        ..clear()
        ..addAll(prefs.getStringList(_key) ?? const []);
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String pkg, bool enabled) async {
    if (enabled) {
      _packages.add(pkg);
    } else {
      _packages.remove(pkg);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> restoreDefaults() async {
    _packages
      ..clear()
      ..addAll(defaultPackages);
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    _packages.clear();
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _packages.toList());
  }
}

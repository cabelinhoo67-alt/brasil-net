import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';

/// Consentimento de localizacao.
///
/// Dois passos, de proposito: primeiro o nosso dialogo explicando para que
/// serve, e so se o usuario aceitar e que o dialogo do Android aparece. O
/// Android permite pedir a permissao uma unica vez de forma util — se o
/// usuario negar direto no dialogo do sistema, ele nao volta a aparecer. Pedir
/// contexto antes evita queimar essa chance.
class LocationConsent {
  LocationConsent._();

  static const _askedKey = 'location_consent_asked';

  static const message =
      'Olá! Precisamos acessar sua localização para personalizar as '
      'configurações e melhorar o sistema. Você não é obrigado a aceitar. '
      'Gostaria de permitir o acesso?';

  /// Mostra o dialogo uma unica vez por instalacao.
  ///
  /// Chamado no `initState` das telas iniciais; o `addPostFrameCallback`
  /// garante que a arvore ja esta montada antes de abrir o dialogo.
  static Future<void> maybeAsk(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedKey) ?? false) return;

    // Ja concedida em uma instalacao anterior do sistema: nao incomoda.
    if (await Permission.locationWhenInUse.isGranted) {
      await prefs.setBool(_askedKey, true);
      return;
    }

    if (!context.mounted) return;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: const Icon(Icons.location_on_outlined, color: AppColors.primary, size: 32),
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('NÃO', style: TextStyle(color: AppColors.textMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('SIM'),
          ),
        ],
      ),
    );

    // Marcamos como perguntado mesmo na recusa: insistir a cada abertura
    // seria assedio, e a resposta ja foi dada.
    await prefs.setBool(_askedKey, true);

    if (accepted != true) {
      debugPrint('[location] usuario recusou no dialogo do app');
      return;
    }

    final status = await Permission.locationWhenInUse.request();
    debugPrint('[location] resultado do dialogo do Android: $status');
  }

  /// Permite pedir de novo — util em um futuro item de menu "ativar localizacao".
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_askedKey);
  }
}

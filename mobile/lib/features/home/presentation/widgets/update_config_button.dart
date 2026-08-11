import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme.dart';
import '../../../config/presentation/controllers/config_controller.dart';

/// Botao "Buscar Atualizacoes de Payloads" (Remote Control Plane).
///
/// Uso na barra superior da Home:
/// ```dart
/// const UpdateConfigButton(),
/// ```
///
/// Comportamento:
///  - Enquanto [ConfigController.isChecking], exibe um
///    [CircularProgressIndicator] compacto no lugar do icone.
///  - Ao concluir, mostra um SnackBar com o resultado:
///      * Sucesso  -> "Payloads e servidores atualizados para a versao [X]!"
///      * Em dia   -> "Voce ja esta utilizando a versao mais recente."
///      * Erro     -> "Falha ao conectar com o servidor de atualizacao."
class UpdateConfigButton extends StatelessWidget {
  const UpdateConfigButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConfigController>();

    return IconButton(
      tooltip: 'Buscar atualizacoes de payloads',
      // Desabilita apenas durante o check — o usuario pode sincronizar
      // novamente quantas vezes quiser.
      onPressed: controller.isChecking ? null : () => _sync(context, controller),
      icon: controller.isChecking
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AppColors.primary,
              ),
            )
          : const Icon(Icons.sync_rounded),
    );
  }

  Future<void> _sync(BuildContext context, ConfigController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await controller.check();

    // O widget pode ter saido da tela durante a chamada.
    if (!context.mounted) return;

    final String message;
    final Color color;
    if (result.isUnavailable) {
      message = 'Falha ao conectar com o servidor de atualizacao.';
      color = AppColors.danger;
    } else if (result.isUpdated) {
      message = 'Payloads e servidores atualizados para a versao '
          '${result.remoteVersion}!';
      color = AppColors.success;
    } else {
      // UpToDate ou versao local ja igual/superior.
      message = 'Voce ja esta utilizando a versao mais recente.';
      color = AppColors.success;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppColors.surfaceAlt,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(label: 'OK', textColor: color, onPressed: () {}),
        ),
      );
  }
}

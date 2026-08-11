import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../features/home/presentation/widgets/update_config_button.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/connection_card.dart';
import '../widgets/payload_tile.dart';
import 'bypass_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.user;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(user?.username ?? '-',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              user?.daysLeft == null
                  ? 'Sem validade definida'
                  : '${user!.daysLeft} dia(s) restante(s)',
              style: TextStyle(
                fontSize: 12,
                color: (user?.daysLeft ?? 99) <= 3 ? AppColors.warning : AppColors.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: state.overlayEnabled ? 'Desativar janela flutuante' : 'Ativar janela flutuante',
            icon: Icon(
              state.overlayEnabled ? Icons.picture_in_picture_alt : Icons.picture_in_picture_alt_outlined,
              color: state.overlayEnabled ? AppColors.primary : null,
            ),
            onPressed: () => _toggleOverlay(context, state),
          ),
          IconButton(
            tooltip: 'Bypass de apps',
            icon: const Icon(Icons.shield_moon_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BypassScreen()),
            ),
          ),
          // Remote Control Plane: botao manual de atualizacao de payloads.
          const UpdateConfigButton(),
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () => _confirmLogout(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await state.refreshSim();
          await state.refreshConfig();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const ConnectionCard(),
            const SizedBox(height: 16),
            _OperatorSection(state: state),
            const SizedBox(height: 20),
            _PayloadSection(state: state),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton.icon(
          onPressed: state.canConnect || state.connection.isOnline
              ? () => state.toggleConnection()
              : null,
          style: FilledButton.styleFrom(
            backgroundColor:
                state.connection.isOnline ? AppColors.danger : AppColors.primary,
          ),
          icon: Icon(state.connection.isOnline
              ? Icons.power_settings_new_rounded
              : Icons.bolt_rounded),
          label: Text(
            state.connection.isBusy
                ? 'CONECTANDO...'
                : state.connection.isOnline
                    ? 'DESCONECTAR'
                    : 'CONECTAR',
          ),
        ),
      ),
    );
  }

  Future<void> _toggleOverlay(BuildContext context, AppState state) async {
    final granted = await state.setOverlayEnabled(!state.overlayEnabled);

    if (!context.mounted) return;

    if (!granted && !state.overlayEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Autorize "Exibir sobre outros apps" na tela do sistema e tente de novo.',
          ),
          backgroundColor: AppColors.surfaceAlt,
        ),
      );
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sair da conta'),
        content: const Text(
            'Voce sera desconectado e a sessao sera liberada para outro aparelho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sair')),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<AppState>().logout();
    }
  }
}

class _OperatorSection extends StatelessWidget {
  const _OperatorSection({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final op = state.operator;
    final detected = op.detected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (detected ? AppColors.success : AppColors.warning)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                detected ? Icons.sim_card_rounded : Icons.sim_card_alert_rounded,
                color: detected ? AppColors.success : AppColors.warning,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Operadora do chip',
                      style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                  const SizedBox(height: 2),
                  Text(
                    detected ? op.name : (state.sim.operatorName.isEmpty ? 'Nao detectada' : state.sim.operatorName),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  if (!detected)
                    const Text(
                      'Nenhuma configuracao disponivel para este chip',
                      style: TextStyle(fontSize: 11, color: AppColors.warning),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Reler o chip',
              onPressed: () => state.refreshSim(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayloadSection extends StatelessWidget {
  const _PayloadSection({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Configuracoes disponiveis',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text('${state.payloads.length} item(ns)',
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          state.operator.detected
              ? 'Filtradas para ${state.operator.name}'
              : 'Insira um chip reconhecido para ver as configuracoes',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        if (state.payloads.isEmpty)
          const _EmptyPayloads()
        else
          ...state.payloads.map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PayloadTile(
                payload: p,
                selected: state.selected?.id == p.id,
                enabled: !state.connection.isOnline && !state.connection.isBusy,
                onTap: () => state.selectPayload(p),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyPayloads extends StatelessWidget {
  const _EmptyPayloads();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Column(
          children: [
            const Icon(Icons.inbox_rounded, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 12),
            const Text('Nenhuma configuracao para esta operadora',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              'Puxe a tela para baixo para atualizar ou fale com seu revendedor.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

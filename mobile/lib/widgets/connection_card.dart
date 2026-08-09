import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../services/app_state.dart';

/// Painel principal: status da conexao, ping e sessoes em uso.
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  Color _statusColor(ConnectionStatus status) => switch (status) {
        ConnectionStatus.connected => AppColors.success,
        ConnectionStatus.connecting => AppColors.warning,
        ConnectionStatus.error => AppColors.danger,
        ConnectionStatus.disconnected => AppColors.textMuted,
      };

  /// Faixas usuais de latencia em rede movel brasileira.
  Color _pingColor(int ping) {
    if (ping < 0) return AppColors.textMuted;
    if (ping < 120) return AppColors.success;
    if (ping < 300) return AppColors.warning;
    return AppColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final color = _statusColor(state.connection);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
              ),
              child: state.connection.isBusy
                  ? Padding(
                      padding: const EdgeInsets.all(34),
                      child: CircularProgressIndicator(strokeWidth: 3, color: color),
                    )
                  : Icon(
                      state.connection.isOnline
                          ? Icons.shield_rounded
                          : Icons.shield_outlined,
                      size: 56,
                      color: color,
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              state.connection.label.toUpperCase(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              state.selected?.name ?? 'Nenhuma configuracao selecionada',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            // Ultima linha de log do motor: mostra em que etapa o tunel esta
            // (TCP, payload, TLS, SSH) e e o que salva o suporte na hora de
            // descobrir por que uma conexao nao fecha.
            if (state.lastLog.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                state.lastLog,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
              ),
            ],
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                _Metric(
                  icon: Icons.speed_rounded,
                  label: 'Ping',
                  value: state.pingLabel,
                  color: _pingColor(state.ping),
                ),
                _VerticalDivider(),
                _Metric(
                  icon: Icons.devices_rounded,
                  label: 'Conexoes',
                  value: '${state.activeSessions}/${state.user?.connectionLimit ?? 1}',
                  color: state.activeSessions >= (state.user?.connectionLimit ?? 1)
                      ? AppColors.warning
                      : AppColors.textMuted,
                ),
                _VerticalDivider(),
                _Metric(
                  icon: Icons.calendar_today_rounded,
                  label: 'Validade',
                  value: state.user?.daysLeft == null ? '--' : '${state.user!.daysLeft}d',
                  color: (state.user?.daysLeft ?? 99) <= 3
                      ? AppColors.warning
                      : AppColors.textMuted,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 40, color: Colors.white.withValues(alpha: 0.06));
  }
}

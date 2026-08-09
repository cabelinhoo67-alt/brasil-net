import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/ota_service.dart';

/// Modal de atualizacao com estetica glassmorphic.
///
/// Reage ao [OtaService]: aparece quando ha update, mostra changelog, baixa com
/// barra de progresso e se auto-destroi quando o instalador do sistema assume.
///
/// Montado uma vez na raiz (ver main.dart) como overlay — nao e empurrado na
/// pilha de navegacao, entao aparece por cima de qualquer tela.
class UpdateGate extends StatelessWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ota = context.watch<OtaService>();

    // Fases em que o modal deve estar visivel.
    final visible = ota.phase == OtaPhase.available ||
        ota.phase == OtaPhase.downloading ||
        ota.phase == OtaPhase.installing;

    return Stack(
      children: [
        child,
        if (visible && ota.update != null)
          _GlassOverlay(ota: ota),
      ],
    );
  }
}

class _GlassOverlay extends StatelessWidget {
  const _GlassOverlay({required this.ota});
  final OtaService ota;

  @override
  Widget build(BuildContext context) {
    final info = ota.update!;
    final downloading = ota.phase == OtaPhase.downloading;
    final installing = ota.phase == OtaPhase.installing;
    final busy = downloading || installing;

    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: _GlassCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Header(version: info.version, mandatory: info.mandatory),
                      const SizedBox(height: 16),

                      if (!busy) ...[
                        _Changelog(lines: info.changelogLines),
                        if (info.sizeBytes > 0) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Download de ${_mb(info.sizeBytes)}',
                            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                          ),
                        ],
                      ] else
                        _ProgressBlock(
                          progress: ota.progress,
                          installing: installing,
                        ),

                      const SizedBox(height: 20),
                      _Actions(ota: ota, info: info, busy: busy, installing: installing),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            // Vidro: branco translucido sobre o blur, com borda clara em cima.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.14),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.25),
                blurRadius: 40,
                spreadRadius: -8,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.version, required this.mandatory});
  final String version;
  final bool mandatory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primary, Color(0xFF7C3AED)],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(color: AppColors.primary.withValues(alpha: 0.5), blurRadius: 16),
            ],
          ),
          child: const Icon(Icons.rocket_launch_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nova versao disponivel',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              Text(
                mandatory ? 'Atualizacao obrigatoria · v$version' : 'Versao $version',
                style: TextStyle(
                  fontSize: 12,
                  color: mandatory ? AppColors.warning : AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Changelog extends StatelessWidget {
  const _Changelog({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const Text(
        'Melhorias e correcoes nesta versao.',
        style: TextStyle(fontSize: 13, color: AppColors.textMuted),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 200),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines
              .map((line) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 5, right: 8),
                          child: Icon(Icons.circle, size: 5, color: AppColors.primary),
                        ),
                        Expanded(
                          child: Text(line,
                              style: const TextStyle(fontSize: 13, height: 1.35)),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({required this.progress, required this.installing});
  final double progress;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          installing ? 'Abrindo o instalador...' : 'Baixando atualizacao... $pct%',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: installing ? null : progress,
            minHeight: 8,
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            valueColor: const AlwaysStoppedAnimation(AppColors.primary),
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.ota,
    required this.info,
    required this.busy,
    required this.installing,
  });

  final OtaService ota;
  final UpdateInfo info;
  final bool busy;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    if (installing) {
      return const SizedBox.shrink(); // sistema assumiu; nada a fazer
    }

    if (busy) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: ota.cancelDownload,
          child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
        ),
      );
    }

    return Row(
      children: [
        if (!info.mandatory)
          Expanded(
            child: TextButton(
              onPressed: ota.dismiss,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Agora nao', style: TextStyle(color: AppColors.textMuted)),
            ),
          ),
        if (!info.mandatory) const SizedBox(width: 12),
        Expanded(
          flex: info.mandatory ? 1 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, Color(0xFF7C3AED)],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(color: AppColors.primary.withValues(alpha: 0.45), blurRadius: 16),
              ],
            ),
            child: TextButton(
              onPressed: ota.downloadAndInstall,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Atualizar agora',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }
}

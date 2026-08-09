import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/app_state.dart';
import '../services/bypass_store.dart';
import '../services/device_service.dart';

/// Gerenciamento de "Bypass de Aplicativos" (split tunneling).
///
/// Apps marcados aqui NAO passam pelo tunel — seguem pela rede real da
/// operadora. E o que impede o antifraude de apps de mobilidade e bancos de ver
/// um IP de datacenter.
class BypassScreen extends StatefulWidget {
  const BypassScreen({super.key});

  @override
  State<BypassScreen> createState() => _BypassScreenState();
}

class _BypassScreenState extends State<BypassScreen> {
  final _searchController = TextEditingController();
  List<InstalledApp> _apps = const [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final apps = await DeviceService.listInstalledApps(withIcons: true);
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  /// Filtro em tempo real por nome ou pacote. Os apps ja selecionados sobem
  /// para o topo, para o usuario ver o que esta ativo de relance.
  List<InstalledApp> _filtered(BypassStore store) {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? List<InstalledApp>.from(_apps)
        : _apps
            .where((a) =>
                a.name.toLowerCase().contains(q) ||
                a.packageName.toLowerCase().contains(q))
            .toList();

    list.sort((a, b) {
      final sa = store.contains(a.packageName) ? 0 : 1;
      final sb = store.contains(b.packageName) ? 0 : 1;
      if (sa != sb) return sa - sb;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Desligar um app protegido pede confirmacao — e o passo que evita o
  /// motorista se auto-sabotar tirando o app de corrida da blindagem.
  Future<void> _onToggle(BypassStore store, String pkg, bool value, bool protected) async {
    if (!value && protected) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
          title: const Text('Remover da blindagem?'),
          content: const Text(
            'Este app faz parte da protecao antifraude. Se ele passar pelo tunel, '
            'seu trafego sai por um IP de datacenter e pode causar bloqueio da conta.\n\n'
            'Tem certeza que quer tira-lo?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Manter protegido')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remover', style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }
    await store.toggle(pkg, value);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppState>().bypass;
    final filtered = _filtered(store);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bypass de aplicativos', style: TextStyle(fontSize: 16)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'defaults') store.restoreDefaults();
              if (v == 'clear') store.clear();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'defaults', child: Text('Restaurar padrao antifraude')),
              PopupMenuItem(value: 'clear', child: Text('Limpar tudo')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _Explainer(count: store.count),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Buscar app ou pacote...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          _query.isEmpty ? 'Nenhum app encontrado' : 'Nada para "$_query"',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final app = filtered[i];
                            final on = store.contains(app.packageName);
                            final protected = store.isProtected(app.packageName);
                            return _AppRow(
                              app: app,
                              enabled: on,
                              protected: protected,
                              onChanged: (v) => _onToggle(store, app.packageName, v, protected),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_moon_outlined, color: AppColors.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$count app(s) fora do tunel',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                const Text(
                  'Apps de corrida e bancos marcados aqui usam a rede normal, '
                  'evitando bloqueios por IP de datacenter.',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.enabled,
    required this.protected,
    required this.onChanged,
  });

  final InstalledApp app;
  final bool enabled;
  final bool protected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: enabled,
      onChanged: onChanged,
      secondary: SizedBox(
        width: 40,
        height: 40,
        child: app.icon != null
            ? Image.memory(app.icon!, gaplessPlayback: true)
            : Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.android, size: 20, color: AppColors.textMuted),
              ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14)),
          ),
          if (protected) ...[
            const SizedBox(width: 6),
            const Icon(Icons.verified_user, size: 14, color: AppColors.success),
          ],
        ],
      ),
      subtitle: Text(app.packageName,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      activeThumbColor: AppColors.success,
    );
  }
}

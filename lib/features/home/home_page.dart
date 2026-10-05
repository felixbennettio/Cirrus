import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/tr.dart';
import '../../ui/shell/command_palette.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';

class _Quick {
  const _Quick(this.icon, this.label, this.path);

  final IconData icon;
  final L10nText label;
  final String path;
}

const _quick = [
  _Quick(Icons.dns_outlined, L10nText('DNS', 'DNS'), '/zone/dns'),
  _Quick(Icons.cached, L10nText('Purge cache', '清除缓存'), '/zone/cache'),
  _Quick(Icons.bolt, L10nText('Workers', 'Workers'), '/workers'),
  _Quick(Icons.web, L10nText('Pages', 'Pages'), '/pages'),
  _Quick(Icons.cloud_queue, L10nText('R2', 'R2'), '/r2'),
  _Quick(Icons.key, L10nText('KV', 'KV'), '/kv'),
  _Quick(Icons.table_chart_outlined, L10nText('D1', 'D1'), '/d1'),
  _Quick(Icons.settings_ethernet, L10nText('Tunnels', '隧道'), '/zt/tunnels'),
  _Quick(Icons.admin_panel_settings_outlined, L10nText('Access', 'Access'), '/zt/access'),
  _Quick(Icons.auto_awesome, L10nText('Workers AI', 'Workers AI'), '/ai'),
  _Quick(Icons.bar_chart, L10nText('Analytics', '分析'), '/zone/analytics'),
  _Quick(Icons.terminal, L10nText('API console', 'API 控制台'), '/console'),
];

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final zones = ref.watch(zonesProvider);
    final profile = ref.watch(activeProfileProvider);
    final theme = Theme.of(context);
    return PageScaffold(
      title: account?['name'] as String? ?? 'Cirrus',
      subtitle: profile?.name,
      actions: [
        IconButton(
          tooltip: context.tr('Search (Ctrl+K)', '搜索 (Ctrl+K)'),
          icon: const Icon(Icons.search),
          onPressed: () => showCommandPalette(context),
        ),
        IconButton(
          tooltip: context.tr('Refresh', '刷新'),
          icon: const Icon(Icons.refresh),
          onPressed: () {
            ref.read(accountsProvider.notifier).refresh();
            ref.read(zonesProvider.notifier).refresh();
          },
        ),
      ],
      body: ContentList(
        onRefresh: () async {
          await ref.read(accountsProvider.notifier).refresh();
          await ref.read(zonesProvider.notifier).refresh();
        },
        children: [
          zones.when(
            data: (list) {
              final active = list.where((z) => z['status'] == 'active').length;
              final paused = list.where((z) => z['paused'] == true).length;
              final pending = list.where((z) => z['status'] == 'pending').length;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ResponsiveGrid(
                  minItemWidth: 170,
                  children: [
                    StatTile(label: context.tr('Domains', '域名'), value: '${list.length}', icon: Icons.language),
                    StatTile(label: context.tr('Active', '已激活'), value: '$active', icon: Icons.check_circle_outline),
                    StatTile(label: context.tr('Pending', '待激活'), value: '$pending', icon: Icons.hourglass_empty),
                    StatTile(label: context.tr('Paused', '已暂停'), value: '$paused', icon: Icons.pause_circle_outline),
                  ],
                ),
              );
            },
            loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => ErrorView(error: e, compact: true, onRetry: () => ref.read(zonesProvider.notifier).refresh()),
          ),
          SectionCard(
            title: context.tr('Quick access', '快捷入口'),
            children: [
              const SizedBox(height: 4),
              ResponsiveGrid(
                minItemWidth: 120,
                spacing: 8,
                children: [
                  for (final q in _quick)
                    Material(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => context.go(q.path),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                          child: Column(
                            children: [
                              Icon(q.icon, color: theme.colorScheme.primary),
                              const SizedBox(height: 6),
                              Text(q.label.of(context), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
          SectionCard(
            title: context.tr('Domains', '域名'),
            trailing: TextButton(onPressed: () => context.go('/domains'), child: Text(context.tr('Manage', '管理'))),
            children: [
              ...(zones.value ?? const []).take(12).map(
                (z) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: Text(z['name'] as String),
                  subtitle: Text('${(z['plan'] as Map?)?['name'] ?? ''}'),
                  trailing: StatusChip(
                    z['paused'] == true ? 'paused' : (z['status'] as String? ?? ''),
                    tone: z['paused'] == true ? Tone.warn : StatusChip.toneFor(z['status'] as String?),
                  ),
                  onTap: () {
                    ref.read(settingsProvider.notifier).setActiveZone(
                      ref.read(currentAccountIdProvider) ?? '-',
                      z['id'] as String,
                    );
                    context.go('/zone');
                  },
                ),
              ),
              if ((zones.value ?? const []).isEmpty && !zones.isLoading)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.tr('No domains in this account yet.', '该账户还没有域名。')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

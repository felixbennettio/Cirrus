import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/tr.dart';
import '../widgets/common.dart';
import '../widgets/glass.dart';
import 'sign_out.dart';

class _SwitcherButton extends StatelessWidget {
  const _SwitcherButton({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              Icon(Icons.unfold_more, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountSwitcher extends ConsumerWidget {
  const AccountSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeProfileProvider);
    final account = ref.watch(currentAccountProvider);
    final accounts = ref.watch(accountsProvider);
    return Row(
      children: [
        Expanded(
          child: _SwitcherButton(
            icon: Icons.account_tree_outlined,
            title:
                account?['name'] as String? ??
                (accounts.isLoading ? context.tr('Loading…', '加载中…') : context.tr('No account', '无账户')),
            subtitle: profile?.name,
            onTap: () => showAccountPicker(context),
          ),
        ),
        if (profile != null)
          IconButton(
            tooltip: context.tr('Sign out', '退出登录'),
            icon: const Icon(Icons.logout, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => confirmRemoveProfile(context, ref, profile, signOut: true),
          ),
      ],
    );
  }
}

Future<void> showAccountPicker(BuildContext context) {
  return showAppDialog<void>(context: context, builder: (_) => const _AccountPickerDialog());
}

class _AccountPickerDialog extends ConsumerWidget {
  const _AccountPickerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const [];
    final active = ref.watch(activeProfileProvider);
    final accounts = ref.watch(accountsProvider);
    final current = ref.watch(currentAccountIdProvider);
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(context.tr('Credentials', '凭据'), style: theme.textTheme.titleSmall),
            ),
            for (final p in profiles)
              ListTile(
                leading: Icon(p.id == active?.id ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(p.name),
                subtitle: Text('${p.kindLabel} · ${p.secretHint}'),
                onTap: () {
                  ref.read(settingsProvider.notifier).setActiveProfile(p.id);
                  Navigator.pop(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(context.tr('Add credential', '添加凭据')),
              onTap: () {
                Navigator.pop(context);
                context.push('/profiles/add');
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
              child: Row(
                children: [
                  Expanded(child: Text(context.tr('Accounts', '账户'), style: theme.textTheme.titleSmall)),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () => ref.read(accountsProvider.notifier).refresh(),
                  ),
                ],
              ),
            ),
            ...accounts.when(
              data: (list) => [
                for (final a in list)
                  ListTile(
                    leading: Icon(a['id'] == current ? Icons.check_circle : Icons.circle_outlined),
                    title: Text(a['name'] as String? ?? a['id'] as String),
                    subtitle: Mono(a['id'] as String, size: 11),
                    onTap: () {
                      ref.read(settingsProvider.notifier).setActiveAccount(active!.id, a['id'] as String);
                      Navigator.pop(context);
                    },
                  ),
                if (list.isEmpty)
                  ListTile(title: Text(context.tr('No accounts visible to this credential', '当前凭据看不到任何账户'))),
              ],
              loading: () => [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [ListTile(leading: const Icon(Icons.error_outline), title: Text(e.toString()))],
            ),
          ],
        ),
      ),
    );
  }
}

class ZoneSwitcher extends ConsumerWidget {
  const ZoneSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(currentZoneProvider);
    final zones = ref.watch(zonesProvider);
    return _SwitcherButton(
      icon: Icons.public,
      title:
          zone?['name'] as String? ??
          (zones.isLoading ? context.tr('Loading zones…', '加载域名中…') : context.tr('No zones', '没有域名')),
      subtitle: zone == null ? null : '${(zone['plan'] as Map?)?['name'] ?? ''} · ${zone['status'] ?? ''}',
      onTap: () => showZonePicker(context),
    );
  }
}

Future<void> showZonePicker(BuildContext context) {
  return showAppDialog<void>(context: context, builder: (_) => const _ZonePickerDialog());
}

class _ZonePickerDialog extends ConsumerStatefulWidget {
  const _ZonePickerDialog();

  @override
  ConsumerState<_ZonePickerDialog> createState() => _ZonePickerDialogState();
}

class _ZonePickerDialogState extends ConsumerState<_ZonePickerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final zones = ref.watch(zonesProvider);
    final current = ref.watch(currentZoneIdProvider);
    final accountId = ref.watch(currentAccountIdProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SearchField(
                      autofocus: true,
                      hint: context.tr('Search domains', '搜索域名'),
                      onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Refresh', '刷新'),
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ref.read(zonesProvider.notifier).refresh(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: zones.when(
                data: (list) {
                  final filtered = list.where((z) => (z['name'] as String? ?? '').toLowerCase().contains(_q)).toList();
                  return ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final z = filtered[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(z['id'] == current ? Icons.check_circle : Icons.public, size: 20),
                        title: Text(z['name'] as String),
                        subtitle: Text('${(z['plan'] as Map?)?['name'] ?? ''}'),
                        trailing: StatusChip(
                          z['paused'] == true ? 'paused' : (z['status'] as String? ?? ''),
                          tone: z['paused'] == true ? Tone.warn : StatusChip.toneFor(z['status'] as String?),
                        ),
                        onTap: () {
                          ref.read(settingsProvider.notifier).setActiveZone(accountId ?? '-', z['id'] as String);
                          Navigator.pop(context);
                        },
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(e.toString())),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Add domain', '添加域名')),
                    onPressed: () {
                      Navigator.pop(context);
                      context.go('/domains?add=1');
                    },
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      context.go('/domains');
                    },
                    child: Text(context.tr('All domains', '全部域名')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

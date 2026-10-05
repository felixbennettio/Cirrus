import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/tr.dart';
import '../../features/generic/resource_specs.dart';
import '../widgets/common.dart';
import 'nav.dart';

Future<void> showCommandPalette(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _CommandPalette(),
  );
}

class _Entry {
  _Entry({required this.icon, required this.title, this.subtitle, required this.run, this.trailing});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final void Function(BuildContext context) run;
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  String _q = '';
  int _selected = 0;

  List<_Entry> _entries(BuildContext context) {
    final q = _q.toLowerCase();
    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    bool hit(Iterable<String> hay) {
      if (terms.isEmpty) return true;
      final h = hay.join(' ').toLowerCase();
      return terms.every(h.contains);
    }

    final out = <_Entry>[];
    final zone = ref.read(currentZoneProvider);
    for (final item in allNavItems) {
      if (item.scope == NavScope.zone && zone == null) continue;
      if (hit([item.label.en, item.label.zh, ...item.keywords, item.path])) {
        out.add(_Entry(
          icon: item.icon,
          title: item.label.of(context),
          subtitle: item.scope == NavScope.zone ? zone!['name'] as String? : null,
          run: (c) => c.go(item.path),
        ));
      }
    }
    for (final spec in resourceSpecs) {
      if (hit([spec.title.en, spec.title.zh, spec.id, ...spec.keywords])) {
        out.add(_Entry(
          icon: spec.icon,
          title: spec.title.of(context),
          subtitle: spec.group.of(context),
          run: (c) => c.go('/r/${spec.id}'),
        ));
      }
    }
    if (terms.isNotEmpty) {
      final zones = ref.read(zonesProvider).value ?? const [];
      final accountId = ref.read(currentAccountIdProvider);
      for (final z in zones.where((z) => hit([z['name'] as String? ?? ''])).take(8)) {
        out.add(_Entry(
          icon: Icons.public,
          title: z['name'] as String,
          subtitle: context.tr('Switch to this zone', '切换到该域名'),
          run: (c) {
            ref.read(settingsProvider.notifier).setActiveZone(accountId ?? '-', z['id'] as String);
            c.go('/zone');
          },
        ));
      }
      final profile = ref.read(activeProfileProvider);
      final accounts = ref.read(accountsProvider).value ?? const [];
      for (final a in accounts.where((a) => hit([a['name'] as String? ?? ''])).take(5)) {
        out.add(_Entry(
          icon: Icons.account_tree_outlined,
          title: a['name'] as String,
          subtitle: context.tr('Switch account', '切换账户'),
          run: (c) {
            if (profile != null) {
              ref.read(settingsProvider.notifier).setActiveAccount(profile.id, a['id'] as String);
            }
          },
        ));
      }
      final catalog = ref.read(catalogProvider).value;
      if (catalog != null && q.length >= 2) {
        for (final op in catalog.search(q, limit: 25)) {
          out.add(_Entry(
            icon: Icons.terminal,
            title: op.summary.isEmpty ? op.path : op.summary,
            subtitle: op.path,
            trailing: MethodBadge(op.method, small: true),
            run: (c) => c.go('/console?op=${Uri.encodeComponent(op.id)}'),
          ));
        }
      }
    }
    return out;
  }

  void _run(_Entry e) {
    final router = GoRouter.of(context);
    Navigator.pop(context);
    e.run(router.routerDelegate.navigatorKey.currentContext ?? context);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries(context);
    if (_selected >= entries.length) _selected = entries.isEmpty ? 0 : entries.length - 1;
    return Dialog(
      alignment: const Alignment(0, -0.6),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    setState(() => _selected = (_selected + 1).clamp(0, entries.length - 1));
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() => _selected = (_selected - 1).clamp(0, entries.length - 1));
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: context.tr(
                      'Jump to a page, zone, account or API endpoint…',
                      '跳转到页面、域名、账户或 API 接口…',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    _q = v.trim();
                    _selected = 0;
                  }),
                  onSubmitted: (_) {
                    if (entries.isNotEmpty) _run(entries[_selected]);
                  },
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final e = entries[i];
                  return ListTile(
                    dense: true,
                    selected: i == _selected,
                    leading: Icon(e.icon, size: 20),
                    title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: e.subtitle == null
                        ? null
                        : Text(e.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: e.trailing,
                    onTap: () => _run(e),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

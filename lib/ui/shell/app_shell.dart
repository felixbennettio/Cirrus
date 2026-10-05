import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/tr.dart';
import '../widgets/common.dart';
import 'command_palette.dart';
import 'nav.dart';
import 'switchers.dart';

class OpenPaletteIntent extends Intent {
  const OpenPaletteIntent();
}

/// Root layout: persistent sidebar on wide screens, drawer on phones.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, required this.location});

  final Widget child;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = isWide(context);
    final compact = ref.watch(settingsProvider.select((s) => s.compactSidebar));
    final sidebar = Sidebar(location: location, inDrawer: !wide);
    final body = wide
        ? Row(
            children: [
              SizedBox(width: compact ? 248 : 288, child: sidebar),
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ],
          )
        : child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyK, control: true): OpenPaletteIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, meta: true): OpenPaletteIntent(),
      },
      child: Actions(
        actions: {
          OpenPaletteIntent: CallbackAction<OpenPaletteIntent>(
            onInvoke: (_) => showCommandPalette(context),
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: shellScaffoldKey,
            drawer: wide ? null : Drawer(width: 300, child: SafeArea(child: sidebar)),
            body: body,
          ),
        ),
      ),
    );
  }
}

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.location, required this.inDrawer});

  final String location;
  final bool inDrawer;

  /// The most specific nav item matching the current location.
  String? get _selectedPath {
    String? best;
    for (final item in allNavItems) {
      final p = item.path;
      final hit = p == '/' ? location == '/' : (location == p || location.startsWith('$p/'));
      if (hit && (best == null || p.length > best.length)) best = p;
    }
    return best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selectedPath = _selectedPath;
    final zone = ref.watch(currentZoneProvider);
    final accountId = ref.watch(currentAccountIdProvider);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/branding/cirrus_256.png', width: 30, height: 30),
                ),
                const SizedBox(width: 10),
                Text('Cirrus', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: context.tr('Search (Ctrl+K)', '搜索 (Ctrl+K)'),
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    if (inDrawer) Navigator.of(context).pop();
                    showCommandPalette(context);
                  },
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Column(children: [AccountSwitcher(), SizedBox(height: 6), ZoneSwitcher()]),
          ),
          const SizedBox(height: 6),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final section in navSections)
                  if (section.id != 'zone' || zone != null) ...[
                    if (section.id != 'home')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                        child: Text(
                          section.id == 'zone' && zone != null
                              ? (zone['name'] as String? ?? section.label.of(context))
                              : section.label.of(context),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: section.id == 'zone' ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    for (final item in section.items)
                      if (item.scope != NavScope.account || accountId != null)
                        _NavTile(
                          item: item,
                          selected: item.path == selectedPath,
                          onTap: () {
                            if (inDrawer) Navigator.of(context).pop();
                            context.go(item.path);
                          },
                        ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.item, required this.selected, required this.onTap});

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon, size: 20, color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label.of(context),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

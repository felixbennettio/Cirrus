import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/util/tr.dart';
import 'feedback.dart';

/// Key of the root shell scaffold, so module pages can open the drawer.
final shellScaffoldKey = GlobalKey<ScaffoldState>();

/// Width at which the persistent sidebar replaces the drawer.
const wideLayoutBreakpoint = 900.0;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;

/// Standard module page: an app bar with title/actions and a body.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.floatingActionButton,
    this.bottom,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  final PreferredSizeWidget? bottom;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final canPop = GoRouter.of(context).canPop();
    final wide = isWide(context);
    Widget? lead = leading;
    if (lead == null && !canPop && !wide) {
      lead = IconButton(
        icon: const Icon(Icons.menu),
        tooltip: context.tr('Menu', '菜单'),
        onPressed: () => shellScaffoldKey.currentState?.openDrawer(),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: lead,
        automaticallyImplyLeading: canPop,
        titleSpacing: lead == null && !canPop ? 20 : null,
        title: subtitle == null
            ? Text(title, overflow: TextOverflow.ellipsis)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, overflow: TextOverflow.ellipsis),
                  Text(
                    subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
        actions: [...actions, const SizedBox(width: 8)],
        bottom: bottom,
      ),
      floatingActionButton: floatingActionButton,
      body: body,
    );
  }
}

/// A titled card grouping related content.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 12),
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title!, style: theme.textTheme.titleMedium),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Label/value row; long-press or tap the icon to copy the value.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.copy = false, this.mono = false, this.trailing});

  final String label;
  final String value;
  final bool copy;
  final bool mono;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 420;
          final labelW = Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          );
          final valueW = SelectableText(
            value,
            style: mono
                ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
                : theme.textTheme.bodyMedium,
          );
          final tail = [
            if (copy)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: context.tr('Copy', '复制'),
                icon: const Icon(Icons.copy),
                onPressed: () => copyText(context, value),
              ),
            ?trailing,
          ];
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelW,
                Row(children: [Expanded(child: valueW), ...tail]),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: 180, child: labelW),
              Expanded(child: valueW),
              ...tail,
            ],
          );
        },
      ),
    );
  }
}

enum Tone { neutral, good, warn, bad, info }

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.tone = Tone.neutral, this.icon});

  final String label;
  final Tone tone;
  final IconData? icon;

  static Tone toneFor(String? status) {
    final s = (status ?? '').toLowerCase();
    if (const ['active', 'healthy', 'success', 'enabled', 'on', 'deployed', 'verified', 'ready', 'connected', 'valid', 'running', 'complete', 'completed', 'ok', 'up'].contains(s)) {
      return Tone.good;
    }
    if (const ['pending', 'initializing', 'pending_validation', 'pending_deployment', 'pending_issuance', 'queued', 'building', 'degraded', 'moved', 'paused', 'inactive', 'idle', 'waiting', 'unverified', 'staging'].contains(s)) {
      return Tone.warn;
    }
    if (const ['failed', 'failure', 'error', 'deleted', 'down', 'disabled', 'off', 'expired', 'revoked', 'unhealthy', 'blocked', 'canceled', 'cancelled', 'inactive_deleted'].contains(s)) {
      return Tone.bad;
    }
    return Tone.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (bg, fg) = switch (tone) {
      Tone.good => (dark ? const Color(0xFF1E3A2A) : const Color(0xFFDDF4E4), dark ? const Color(0xFF8BE0A8) : const Color(0xFF16683A)),
      Tone.warn => (dark ? const Color(0xFF3D3214) : const Color(0xFFFFF1CC), dark ? const Color(0xFFF5CF6A) : const Color(0xFF7A5A00)),
      Tone.bad => (scheme.errorContainer, scheme.onErrorContainer),
      Tone.info => (scheme.primaryContainer, scheme.onPrimaryContainer),
      Tone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class MethodBadge extends StatelessWidget {
  const MethodBadge(this.method, {super.key, this.small = false});

  final String method;
  final bool small;

  static Color colorFor(String m) => switch (m.toUpperCase()) {
    'GET' => const Color(0xFF2E7D32),
    'POST' => const Color(0xFF1565C0),
    'PUT' => const Color(0xFF6A1B9A),
    'PATCH' => const Color(0xFFEF6C00),
    'DELETE' => const Color(0xFFC62828),
    _ => Colors.blueGrey,
  };

  @override
  Widget build(BuildContext context) {
    final c = colorFor(method);
    return Container(
      width: small ? 50 : 60,
      padding: const EdgeInsets.symmetric(vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        method.toUpperCase(),
        style: TextStyle(
          color: c,
          fontSize: small ? 10 : 11,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Compact search box used above lists.
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.onChanged, this.hint, this.controller, this.autofocus = false});

  final ValueChanged<String> onChanged;
  final String? hint;
  final TextEditingController? controller;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: hint ?? context.tr('Search', '搜索'),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}

/// Centered, width-limited scroll view for detail/settings pages.
class ContentList extends StatelessWidget {
  const ContentList({super.key, required this.children, this.maxWidth = 1100, this.onRefresh, this.padding});

  final List<Widget> children;
  final double maxWidth;
  final Future<void> Function()? onRefresh;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding ?? EdgeInsets.symmetric(horizontal: isWide(context) ? 24 : 12, vertical: 16),
      children: [
        for (final c in children)
          Center(
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: c),
          ),
      ],
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class Mono extends StatelessWidget {
  const Mono(this.text, {super.key, this.size = 13, this.color, this.maxLines});

  final String text;
  final double size;
  final Color? color;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(fontFamily: 'monospace', fontSize: size, color: color),
  );
}

/// Tile-like statistic for dashboards.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.sub});

  final String label;
  final String value;
  final IconData? icon;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            if (sub != null)
              Text(sub!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Grid that adapts column count to available width.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minItemWidth = 220, this.spacing = 12});

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxCols = children.isEmpty ? 1 : (children.length < 6 ? children.length : 6);
        final cols = (c.maxWidth / minItemWidth).floor().clamp(1, maxCols);
        final w = (c.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final child in children) SizedBox(width: w, child: child)],
        );
      },
    );
  }
}

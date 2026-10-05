import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/api/cf_exception.dart';
import '../../core/cache/query_cache.dart';
import '../../core/session/session.dart';
import '../../core/util/tr.dart';
import 'common.dart';
import 'feedback.dart';

/// Handle passed to [ApiQuery.builder] to reload or patch data.
class QueryHandle<T> {
  QueryHandle._(this._state);

  final _ApiQueryState<T> _state;

  bool get refreshing => _state._refreshing;

  Future<void> reload() => _state._load(force: true);

  /// Replaces the data locally (optimistic update) without a request.
  void setData(T data) => _state._setData(data);
}

/// Loads data from the API with stale-while-revalidate caching: cached
/// data renders immediately, then refreshes in the background.
class ApiQuery<T> extends ConsumerStatefulWidget {
  const ApiQuery({
    super.key,
    required this.cacheKey,
    required this.load,
    required this.builder,
    this.cache = true,
    this.loading,
    this.empty,
    this.frame,
  });

  /// Identifies the request; changing it triggers a reload.
  final String cacheKey;
  final Future<T> Function(CfClient client) load;
  final Widget Function(BuildContext context, T data, QueryHandle<T> handle) builder;
  final bool cache;
  final Widget? loading;

  /// Optional widget shown when the data is an empty list.
  final Widget? empty;

  /// Wraps the loading and error states, for pages whose scaffold is
  /// built from the loaded data.
  final Widget Function(Widget child)? frame;

  @override
  ConsumerState<ApiQuery<T>> createState() => _ApiQueryState<T>();
}

class _ApiQueryState<T> extends ConsumerState<ApiQuery<T>> {
  T? _data;
  bool _hasData = false;
  Object? _error;
  bool _refreshing = false;
  int _generation = 0;
  late final QueryHandle<T> _handle = QueryHandle._(this);

  String get _key => '${ref.read(cacheScopeProvider)}|${widget.cacheKey}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ApiQuery<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _hasData = false;
      _data = null;
      _error = null;
      _load();
    }
  }

  void _setData(T data) {
    setState(() {
      _data = data;
      _hasData = true;
    });
    if (widget.cache) QueryCache.instance.write(_key, data);
  }

  Future<void> _load({bool force = false}) async {
    final client = ref.read(clientProvider);
    if (client == null) return;
    final gen = ++_generation;
    final key = _key;
    if (!force && widget.cache) {
      final cached = QueryCache.instance.read(key);
      if (cached != null && cached.data is T) {
        _data = cached.data as T;
        _hasData = true;
        // Fresh enough: skip the network entirely.
        if (DateTime.now().difference(cached.at) < const Duration(seconds: 20)) {
          if (mounted) setState(() {});
          return;
        }
      }
    }
    if (mounted) {
      setState(() {
        _refreshing = true;
        if (!_hasData) _error = null;
      });
    }
    try {
      final data = await widget.load(client);
      if (!mounted || gen != _generation) return;
      if (widget.cache) QueryCache.instance.write(key, data);
      setState(() {
        _data = data;
        _hasData = true;
        _error = null;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e;
        _refreshing = false;
      });
      if (_hasData) showToast(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(clientProvider, (_, _) {
      _hasData = false;
      _load(force: true);
    });
    if (!_hasData) {
      final frame = widget.frame ?? (Widget w) => w;
      if (_error != null) {
        return frame(ErrorView(error: _error!, onRetry: () => _load(force: true)));
      }
      return frame(widget.loading ?? const Center(child: CircularProgressIndicator()));
    }
    final data = _data as T;
    if (widget.empty != null && data is List && data.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(height: c.maxHeight, child: widget.empty),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: widget.builder(context, data, _handle)),
        if (_refreshing) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
      ],
    );
  }
}

/// Full-area error with retry and, for API errors, the token permissions
/// the endpoint requires (looked up from the API catalog).
class ErrorView extends ConsumerWidget {
  const ErrorView({super.key, required this.error, this.onRetry, this.compact = false});

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final e = error;
    List<String> perms = const [];
    String title = context.tr('Something went wrong', '出错了');
    IconData icon = Icons.error_outline;
    if (e is CfApiException) {
      final catalog = ref.watch(catalogProvider).value;
      perms = catalog?.find(e.method, e.path)?.permissions ?? const [];
      if (e.isNetworkError) {
        title = context.tr('Network error', '网络错误');
        icon = Icons.wifi_off;
      } else if (e.isAuthError) {
        title = context.tr('Authentication failed', '认证失败');
        icon = Icons.lock_outline;
      } else if (e.isForbidden) {
        title = context.tr('Permission denied', '权限不足');
        icon = Icons.block;
      } else if (e.isNotFound) {
        title = context.tr('Not found', '未找到');
        icon = Icons.search_off;
      } else if (e.isRateLimited) {
        title = context.tr('Rate limited', '请求过于频繁');
        icon = Icons.speed;
      }
    }
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: compact ? 28 : 44, color: scheme.error),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SelectableText(
            errorText(e),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        if (perms.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            context.tr('This endpoint requires token permissions:', '该接口需要以下 Token 权限：'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [for (final p in perms) Chip(label: Text(p), visualDensity: VisualDensity.compact)],
          ),
        ],
        if (e is CfApiException) ...[
          const SizedBox(height: 8),
          Text(
            '${e.method} ${e.path}${e.statusCode != null ? ' · HTTP ${e.statusCode}' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            if (onRetry != null)
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('Retry', '重试')),
              ),
            TextButton.icon(
              onPressed: () => copyText(context, e.toString()),
              icon: const Icon(Icons.copy, size: 18),
              label: Text(context.tr('Copy details', '复制详情')),
            ),
          ],
        ),
      ],
    );
    return Center(
      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: TextStyle(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Requires a selected zone; shows a hint otherwise.
class ZoneRequired extends ConsumerWidget {
  const ZoneRequired({super.key, required this.builder, this.pageTitle});

  final Widget Function(BuildContext context, String zoneId, Map<String, dynamic> zone) builder;

  /// When set, unmet states are shown inside a page scaffold with this title.
  final String? pageTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(currentZoneProvider);
    if (zone == null) {
      final body = _missing(context, ref);
      return pageTitle == null ? body : PageScaffold(title: pageTitle!, body: body);
    }
    return builder(context, zone['id'] as String, zone);
  }

  Widget _missing(BuildContext context, WidgetRef ref) {
    final zones = ref.watch(zonesProvider);
    {
      if (zones.isLoading) return const Center(child: CircularProgressIndicator());
      if (zones.hasError) {
        return ErrorView(error: zones.error!, onRetry: () => ref.read(zonesProvider.notifier).refresh());
      }
      return EmptyView(
        icon: Icons.public_off,
        title: context.tr('No zone selected', '未选择域名'),
        subtitle: context.tr(
          'Add a domain to this account or pick one from the zone switcher.',
          '请先在该账户中添加域名，或在域名切换器中选择一个。',
        ),
      );
    }
  }
}

/// Requires a selected account.
class AccountRequired extends ConsumerWidget {
  const AccountRequired({super.key, required this.builder, this.pageTitle});

  final Widget Function(BuildContext context, String accountId) builder;

  /// When set, unmet states are shown inside a page scaffold with this title.
  final String? pageTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(currentAccountIdProvider);
    if (id == null) {
      final body = _missing(context, ref);
      return pageTitle == null ? body : PageScaffold(title: pageTitle!, body: body);
    }
    return builder(context, id);
  }

  Widget _missing(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    {
      if (accounts.isLoading) return const Center(child: CircularProgressIndicator());
      if (accounts.hasError) {
        return ErrorView(error: accounts.error!, onRetry: () => ref.read(accountsProvider.notifier).refresh());
      }
      return EmptyView(
        icon: Icons.account_tree_outlined,
        title: context.tr('No account available', '没有可用账户'),
        subtitle: context.tr(
          'This credential cannot list any account. Check the token permissions (Account Settings: Read).',
          '当前凭据无法读取任何账户，请检查 Token 权限（Account Settings: Read）。',
        ),
      );
    }
  }
}

/// Debounces rapid calls (e.g. search-as-you-type).
class Debouncer {
  Debouncer([this.delay = const Duration(milliseconds: 300)]);

  final Duration delay;
  Timer? _timer;

  void call(void Function() fn) {
    _timer?.cancel();
    _timer = Timer(delay, fn);
  }

  void dispose() => _timer?.cancel();
}

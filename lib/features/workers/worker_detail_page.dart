import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:re_editor/re_editor.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/cf_client.dart';
import '../../core/cache/query_cache.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/charts.dart';
import '../../ui/widgets/code_editor.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';
import 'workers_api.dart';

class WorkerDetailPage extends ConsumerWidget {
  const WorkerDetailPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = <(String, Widget)>[
      (context.tr('Overview', '概览'), _Overview(script: name)),
      (context.tr('Code', '代码'), _CodeTab(script: name)),
      (context.tr('Bindings & variables', '绑定与变量'), _SettingsTab(script: name)),
      ('Secrets', _SecretsTab(script: name)),
      (context.tr('Triggers', '触发器'), _TriggersTab(script: name)),
      (context.tr('Deployments', '部署'), _DeploymentsTab(script: name)),
      (context.tr('Live logs', '实时日志'), _TailTab(script: name)),
    ];
    return AccountRequired(
      pageTitle: name,
      builder: (context, accountId) => DefaultTabController(
        length: tabs.length,
        child: PageScaffold(
          title: name,
          subtitle: 'Worker',
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'delete') {
                  final ok = await confirmDanger(
                    context,
                    title: context.tr('Delete Worker?', '删除 Worker？'),
                    message: context.tr('The script, its routes and settings will be deleted.', '脚本及其路由和设置都将被删除。'),
                    typeToConfirm: name,
                  );
                  if (!ok || !context.mounted) return;
                  final client = ref.read(clientProvider)!;
                  final r = await runAction(
                    context,
                    () => client.send('DELETE', '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(name)}', query: {'force': true}),
                    success: context.tr('Deleted', '已删除'),
                  );
                  if (r != null && context.mounted) {
                    QueryCache.instance.invalidate('workers:');
                    context.go('/workers');
                  }
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'delete', child: Text(context.tr('Delete Worker', '删除 Worker'))),
              ],
            ),
          ],
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t.$1)]),
          body: TabBarView(children: [for (final t in tabs) t.$2]),
        ),
      ),
    );
  }
}

String _scriptPath(String accountId, String script) => '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}';

// ---------------------------------------------------------------------------
// Overview

class _Overview extends ConsumerWidget {
  const _Overview({required this.script});

  final String script;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider)!;
    return ApiQuery<(List<WorkerMetricsPoint>, Map<String, dynamic>?, String?)>(
      cacheKey: 'worker-overview:$accountId:$script',
      load: (c) async {
        final metrics = await fetchWorkerMetrics(c, accountId, script).catchError((_) => <WorkerMetricsPoint>[]);
        Map<String, dynamic>? sub;
        String? subdomain;
        try {
          sub = Map<String, dynamic>.from(await c.get('${_scriptPath(accountId, script)}/subdomain') as Map);
          subdomain = (await c.get('/accounts/$accountId/workers/subdomain') as Map?)?['subdomain'] as String?;
        } catch (_) {}
        return (metrics, sub, subdomain);
      },
      builder: (context, data, h) {
        final (metrics, sub, subdomain) = data;
        final req = metrics.fold<double>(0, (a, p) => a + p.requests);
        final err = metrics.fold<double>(0, (a, p) => a + p.errors);
        final sr = metrics.fold<double>(0, (a, p) => a + p.subrequests);
        final p99 = metrics.isEmpty ? 0.0 : metrics.map((p) => p.cpuP99).reduce((a, b) => a > b ? a : b);
        final url = subdomain == null ? null : 'https://$script.$subdomain.workers.dev';
        final client = ref.read(clientProvider)!;
        return ContentList(
          onRefresh: h.reload,
          children: [
            ResponsiveGrid(
              minItemWidth: 170,
              children: [
                StatTile(label: context.tr('Requests (24h)', '请求数（24h）'), value: formatCount(req), icon: Icons.swap_vert),
                StatTile(label: context.tr('Errors (24h)', '错误数（24h）'), value: formatCount(err), icon: Icons.error_outline, sub: req == 0 ? null : '${(err / req * 100).toStringAsFixed(2)}%'),
                StatTile(label: context.tr('Subrequests', '子请求'), value: formatCount(sr), icon: Icons.call_split),
                StatTile(label: 'CPU P99', value: '${p99.toStringAsFixed(1)} µs', icon: Icons.memory),
              ],
            ),
            const SizedBox(height: 12),
            if (metrics.isNotEmpty)
              SectionCard(
                title: context.tr('Requests per hour', '每小时请求'),
                children: [
                  TimeSeriesChart(
                    labels: metrics.map((p) => '${p.at.toLocal().hour.toString().padLeft(2, '0')}:00').toList(),
                    format: formatCount,
                    series: [
                      ChartSeries(name: context.tr('Requests', '请求'), values: metrics.map((p) => p.requests).toList(), color: Theme.of(context).colorScheme.primary),
                      ChartSeries(name: context.tr('Errors', '错误'), values: metrics.map((p) => p.errors).toList(), color: Colors.red),
                    ],
                  ),
                ],
              ),
            if (sub != null)
              SectionCard(
                title: 'workers.dev',
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('Route on workers.dev', '在 workers.dev 上提供访问')),
                    subtitle: url == null
                        ? null
                        : InkWell(onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), child: Text(url, style: const TextStyle(decoration: TextDecoration.underline))),
                    value: sub['enabled'] == true,
                    onChanged: (v) async {
                      await runAction(context, () => client.post('${_scriptPath(accountId, script)}/subdomain', data: {'enabled': v, 'previews_enabled': sub['previews_enabled'] ?? v}));
                      await h.reload();
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('Preview URLs', '预览 URL')),
                    value: sub['previews_enabled'] == true,
                    onChanged: (v) async {
                      await runAction(context, () => client.post('${_scriptPath(accountId, script)}/subdomain', data: {'enabled': sub['enabled'] ?? false, 'previews_enabled': v}));
                      await h.reload();
                    },
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Code

class _CodeTab extends ConsumerStatefulWidget {
  const _CodeTab({required this.script});

  final String script;

  @override
  ConsumerState<_CodeTab> createState() => _CodeTabState();
}

class _CodeTabState extends ConsumerState<_CodeTab> with AutomaticKeepAliveClientMixin {
  WorkerContent? _content;
  Object? _error;
  bool _loading = true;
  bool _dirty = false;
  String? _current;
  final Map<String, CodeLineEditingController> _editors = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final e in _editors.values) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = ref.read(clientProvider)!;
      final content = await fetchWorkerContent(c, ref.read(currentAccountIdProvider)!, widget.script);
      for (final e in _editors.values) {
        e.dispose();
      }
      _editors.clear();
      for (final m in content.modules.where((m) => m.isText)) {
        final ctl = CodeLineEditingController.fromText(m.text);
        ctl.addListener(() {
          if (!_dirty && ctl.text != m.text) setState(() => _dirty = true);
        });
        _editors[m.name] = ctl;
      }
      setState(() {
        _content = content;
        _current = content.main.isText ? content.mainModule : _editors.keys.firstOrNull;
        _loading = false;
        _dirty = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _deploy() async {
    final content = _content;
    if (content == null) return;
    for (final m in content.modules) {
      final ed = _editors[m.name];
      if (ed != null) m.text = ed.text;
    }
    final c = ref.read(clientProvider)!;
    final ok = await runAction(context, () async {
      await uploadWorkerContent(c, ref.read(currentAccountIdProvider)!, widget.script, content);
      return true;
    }, success: context.tr('Deployed', '已部署'));
    if (ok == true) setState(() => _dirty = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    final content = _content!;
    final current = _current;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final m in content.modules)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(m.name + (m.name == content.mainModule ? ' ★' : '')),
                            selected: current == m.name,
                            onSelected: m.isText ? (_) => setState(() => _current = m.name) : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(tooltip: context.tr('Reload', '重新加载'), icon: const Icon(Icons.refresh), onPressed: _load),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _dirty ? _deploy : null,
                icon: const Icon(Icons.rocket_launch_outlined),
                label: Text(context.tr('Save & deploy', '保存并部署')),
              ),
            ],
          ),
        ),
        if (!content.moduleSyntax)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              context.tr('Service Worker syntax detected.', '检测到 Service Worker 语法。'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: current == null || _editors[current] == null
              ? EmptyView(icon: Icons.code_off, title: context.tr('No editable text module', '没有可编辑的文本模块'))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CodeEditorField(
                        key: ValueKey(current),
                        controller: _editors[current]!,
                        language: languageFor(current),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings & bindings

const _bindingLabels = {
  'plain_text': L10nText('Variable', '变量'),
  'json': L10nText('JSON variable', 'JSON 变量'),
  'secret_text': L10nText('Secret', '密钥'),
  'kv_namespace': L10nText('KV namespace', 'KV 命名空间'),
  'r2_bucket': L10nText('R2 bucket', 'R2 存储桶'),
  'd1': L10nText('D1 database', 'D1 数据库'),
  'durable_object_namespace': L10nText('Durable Object', 'Durable Object'),
  'service': L10nText('Service', '服务绑定'),
  'queue': L10nText('Queue', '队列'),
  'ai': L10nText('Workers AI', 'Workers AI'),
  'vectorize': L10nText('Vectorize', 'Vectorize'),
  'hyperdrive': L10nText('Hyperdrive', 'Hyperdrive'),
  'analytics_engine': L10nText('Analytics Engine', 'Analytics Engine'),
  'browser': L10nText('Browser Rendering', '浏览器渲染'),
  'version_metadata': L10nText('Version metadata', '版本元数据'),
  'assets': L10nText('Static assets', '静态资源'),
  'secrets_store_secret': L10nText('Secrets Store', 'Secrets Store'),
  'workflow': L10nText('Workflow', '工作流'),
  'dispatch_namespace': L10nText('Dispatch namespace', '分发命名空间'),
  'mtls_certificate': L10nText('mTLS certificate', 'mTLS 证书'),
};

String _bindingTarget(Map b) {
  for (final k in const ['namespace_id', 'bucket_name', 'id', 'database_id', 'service', 'queue_name', 'index_name', 'class_name', 'dataset', 'certificate_id', 'store_id', 'workflow_name', 'namespace']) {
    if (b[k] != null) return '${b[k]}';
  }
  if (b['type'] == 'plain_text') return '${b['text']}';
  if (b['type'] == 'json') return prettyJson(b['json']);
  return '';
}

class _SettingsTab extends ConsumerWidget {
  const _SettingsTab({required this.script});

  final String script;

  Future<void> _editVar(BuildContext context, WidgetRef ref, Map<String, dynamic> settings, QueryHandle h, [Map? existing]) async {
    final name = TextEditingController(text: existing?['name'] as String?);
    final value = TextEditingController(text: existing?['text'] as String?);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? ctx.tr('Add variable', '添加变量') : ctx.tr('Edit variable', '编辑变量')),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, enabled: existing == null, decoration: InputDecoration(labelText: ctx.tr('Name', '名称'), border: const OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: value, minLines: 1, maxLines: 6, decoration: InputDecoration(labelText: ctx.tr('Value', '值'), border: const OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Save', '保存'))),
        ],
      ),
    );
    final n = name.text.trim();
    final v = value.text;
    name.dispose();
    value.dispose();
    if (ok != true || n.isEmpty || !context.mounted) return;
    final bindings = _rebuildBindings(settings, replace: {'name': n, 'type': 'plain_text', 'text': v});
    await _saveBindings(context, ref, bindings, h);
  }

  /// Builds a full bindings list for a settings PATCH, keeping every
  /// existing non-variable binding as-is (secrets are inherited).
  List<Map<String, dynamic>> _rebuildBindings(Map<String, dynamic> settings, {Map<String, dynamic>? replace, String? remove}) {
    final out = <Map<String, dynamic>>[];
    var replaced = false;
    for (final b in ((settings['bindings'] as List?) ?? const []).cast<Map>()) {
      final name = b['name'];
      if (name == remove) continue;
      if (replace != null && name == replace['name']) {
        out.add(replace);
        replaced = true;
        continue;
      }
      if (b['type'] == 'secret_text' || b['type'] == 'secret_key') {
        out.add({'name': name, 'type': 'inherit'});
      } else {
        out.add(Map<String, dynamic>.from(b));
      }
    }
    if (replace != null && !replaced) out.add(replace);
    return out;
  }

  Future<void> _saveBindings(BuildContext context, WidgetRef ref, List<Map<String, dynamic>> bindings, QueryHandle h) async {
    final c = ref.read(clientProvider)!;
    await runAction(
      context,
      () => patchWorkerSettings(c, ref.read(currentAccountIdProvider)!, script, {'bindings': bindings}),
      success: context.tr('Saved and deployed', '已保存并部署'),
    );
    await h.reload();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider)!;
    return ApiQuery<Map<String, dynamic>>(
      cacheKey: 'worker-settings:$accountId:$script',
      load: (c) async => Map<String, dynamic>.from(await c.get('${_scriptPath(accountId, script)}/settings') as Map),
      builder: (context, s, h) {
        final bindings = ((s['bindings'] as List?) ?? const []).cast<Map>();
        final vars = bindings.where((b) => b['type'] == 'plain_text' || b['type'] == 'json').toList();
        final others = bindings.where((b) => b['type'] != 'plain_text' && b['type'] != 'json').toList();
        final c = ref.read(clientProvider)!;
        return ContentList(
          onRefresh: h.reload,
          children: [
            SectionCard(
              title: context.tr('Environment variables', '环境变量'),
              trailing: TextButton.icon(
                icon: const Icon(Icons.add),
                label: Text(context.tr('Add', '添加')),
                onPressed: () => _editVar(context, ref, s, h),
              ),
              children: [
                if (vars.isEmpty) Text(context.tr('No variables', '没有变量')),
                for (final b in vars)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${b['name']}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                    subtitle: Text(_bindingTarget(b), maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: b['type'] == 'plain_text' ? () => _editVar(context, ref, s, h, b) : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final ok = await confirm(context, title: context.tr('Remove ${b['name']}?', '移除 ${b['name']}？'), destructive: true);
                        if (!ok || !context.mounted) return;
                        await _saveBindings(context, ref, _rebuildBindings(s, remove: b['name'] as String?), h);
                      },
                    ),
                  ),
              ],
            ),
            SectionCard(
              title: context.tr('Bindings', '绑定'),
              trailing: TextButton(
                onPressed: () async {
                  final text = await promptText(
                    context,
                    title: context.tr('Edit bindings (JSON)', '编辑绑定（JSON）'),
                    initial: prettyJson(_rebuildBindings(s)),
                    multiline: true,
                    monospace: true,
                    confirmLabel: context.tr('Save & deploy', '保存并部署'),
                  );
                  if (text == null || !context.mounted) return;
                  try {
                    final parsed = (jsonDecodeList(text)).cast<Map<String, dynamic>>();
                    await _saveBindings(context, ref, parsed, h);
                  } catch (e) {
                    if (context.mounted) showToast(context, e.toString(), error: true);
                  }
                },
                child: Text(context.tr('Edit as JSON', '以 JSON 编辑')),
              ),
              children: [
                if (others.isEmpty) Text(context.tr('No bindings', '没有绑定')),
                for (final b in others)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link),
                    title: Text('${b['name']}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                    subtitle: Text('${_bindingLabels[b['type']]?.of(context) ?? b['type']} · ${_bindingTarget(b)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
            SectionCard(
              title: context.tr('Runtime', '运行时'),
              children: [
                InfoRow(context.tr('Compatibility date', '兼容日期'), str(s['compatibility_date']),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () async {
                        final v = await promptText(context, title: context.tr('Compatibility date', '兼容日期'), initial: s['compatibility_date'] as String?, hint: 'YYYY-MM-DD');
                        if (v == null || !context.mounted) return;
                        await runAction(context, () => patchWorkerSettings(c, accountId, script, {'compatibility_date': v.trim()}), success: context.tr('Saved', '已保存'));
                        await h.reload();
                      },
                    )),
                InfoRow(context.tr('Compatibility flags', '兼容标志'), ((s['compatibility_flags'] as List?) ?? const []).join(', ').ifEmpty('—')),
                InfoRow(context.tr('Usage model', '计费模式'), str(s['usage_model'])),
                InfoRow(context.tr('Placement', '放置'), str((s['placement'] as Map?)?['mode'] ?? s['placement_mode'])),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Workers Logs (observability)', 'Workers 日志（可观测性）')),
                  value: (s['observability'] as Map?)?['enabled'] == true,
                  onChanged: (v) async {
                    await runAction(context, () => patchWorkerSettings(c, accountId, script, {'observability': {'enabled': v}}));
                    await h.reload();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Logpush'),
                  value: s['logpush'] == true,
                  onChanged: (v) async {
                    await runAction(context, () => patchWorkerSettings(c, accountId, script, {'logpush': v}));
                    await h.reload();
                  },
                ),
              ],
            ),
            SectionCard(title: 'JSON', children: [JsonTreeView(s, shrinkWrap: true, initiallyExpandedDepth: 1)]),
          ],
        );
      },
    );
  }
}

List<dynamic> jsonDecodeList(String text) {
  final v = jsonDecode(text);
  if (v is! List) throw const FormatException('Expected a JSON array');
  return v;
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ---------------------------------------------------------------------------
// Secrets

class _SecretsTab extends ConsumerWidget {
  const _SecretsTab({required this.script});

  final String script;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider)!;
    final base = '${_scriptPath(accountId, script)}/secrets';
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'worker-secrets:$accountId:$script',
      load: (c) => c.list(base, paginate: false),
      builder: (context, secrets, h) {
        final c = ref.read(clientProvider)!;
        Future<void> put([String? existing]) async {
          final name = TextEditingController(text: existing);
          final value = TextEditingController();
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(existing == null ? ctx.tr('Add secret', '添加密钥') : ctx.tr('Update secret', '更新密钥')),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: name, enabled: existing == null, decoration: InputDecoration(labelText: ctx.tr('Name', '名称'), border: const OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(controller: value, obscureText: true, decoration: InputDecoration(labelText: ctx.tr('Value', '值'), border: const OutlineInputBorder())),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Save', '保存'))),
              ],
            ),
          );
          final n = name.text.trim();
          final v = value.text;
          name.dispose();
          value.dispose();
          if (ok != true || n.isEmpty || !context.mounted) return;
          await runAction(context, () => c.put(base, data: {'name': n, 'text': v, 'type': 'secret_text'}), success: context.tr('Secret saved', '密钥已保存'));
          await h.reload();
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(child: Text(context.tr('Secret values are write-only.', '密钥值只能写入，无法读取。'))),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  FilledButton.tonalIcon(icon: const Icon(Icons.add), label: Text(context.tr('Add', '添加')), onPressed: put),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final s in secrets)
                    ListTile(
                      leading: const Icon(Icons.password),
                      title: Text('${s['name']}', style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: Text('${s['type']}'),
                      onTap: () => put(s['name'] as String?),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirmDanger(context, title: context.tr('Delete secret?', '删除密钥？'), message: '${s['name']}');
                          if (!ok || !context.mounted) return;
                          await runAction(context, () => c.delete('$base/${Uri.encodeComponent(s['name'] as String)}'));
                          await h.reload();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Triggers: custom domains, routes, cron

class _TriggersTab extends ConsumerWidget {
  const _TriggersTab({required this.script});

  final String script;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider)!;
    final zoneId = ref.watch(currentZoneIdProvider);
    final zone = ref.watch(currentZoneProvider);
    return ApiQuery<(List<Map<String, dynamic>>, List<Map<String, dynamic>>, List<Map<String, dynamic>>)>(
      cacheKey: 'worker-triggers:$accountId:$script:$zoneId',
      load: (c) async {
        final domains = await c.list('/accounts/$accountId/workers/domains', query: {'service': script}, paginate: false).catchError((_) => <Map<String, dynamic>>[]);
        final sched = await c.get('${_scriptPath(accountId, script)}/schedules').catchError((_) => null);
        final schedules = (sched is Map ? (sched['schedules'] as List? ?? const []) : const []).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        var routes = <Map<String, dynamic>>[];
        if (zoneId != null) {
          routes = (await c.list('/zones/$zoneId/workers/routes', paginate: false).catchError((_) => <Map<String, dynamic>>[]))
              .where((r) => r['script'] == script)
              .toList();
        }
        return (domains, schedules, routes);
      },
      builder: (context, data, h) {
        final (domains, schedules, routes) = data;
        final c = ref.read(clientProvider)!;
        return ContentList(
          onRefresh: h.reload,
          children: [
            SectionCard(
              title: context.tr('Custom domains', '自定义域'),
              trailing: zone == null
                  ? null
                  : TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(context.tr('Add', '添加')),
                      onPressed: () async {
                        final host = await promptText(context, title: context.tr('Custom domain', '自定义域'), hint: 'api.${zone['name']}');
                        if (host == null || host.trim().isEmpty || !context.mounted) return;
                        await runAction(
                          context,
                          () => c.put('/accounts/$accountId/workers/domains', data: {
                            'hostname': host.trim(),
                            'service': script,
                            'zone_id': zoneId,
                            'environment': 'production',
                          }),
                          success: context.tr('Domain attached', '已绑定域名'),
                        );
                        await h.reload();
                      },
                    ),
              children: [
                if (domains.isEmpty) Text(context.tr('No custom domains', '没有自定义域')),
                for (final d in domains)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.language),
                    title: Text('${d['hostname']}'),
                    subtitle: Text('${d['zone_name'] ?? ''} · ${d['environment'] ?? ''}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        final ok = await confirm(context, title: context.tr('Detach ${d['hostname']}?', '解绑 ${d['hostname']}？'), destructive: true);
                        if (!ok || !context.mounted) return;
                        await runAction(context, () => c.delete('/accounts/$accountId/workers/domains/${d['id']}'));
                        await h.reload();
                      },
                    ),
                  ),
              ],
            ),
            SectionCard(
              title: context.tr('Routes in ${zone?['name'] ?? 'current zone'}', '${zone?['name'] ?? '当前域名'} 中的路由'),
              trailing: zoneId == null
                  ? null
                  : TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(context.tr('Add', '添加')),
                      onPressed: () async {
                        final pattern = await promptText(context, title: context.tr('Route pattern', '路由规则'), hint: '${zone?['name']}/api/*');
                        if (pattern == null || pattern.trim().isEmpty || !context.mounted) return;
                        await runAction(context, () => c.post('/zones/$zoneId/workers/routes', data: {'pattern': pattern.trim(), 'script': script}));
                        await h.reload();
                      },
                    ),
              children: [
                if (routes.isEmpty) Text(context.tr('No routes in this zone', '该域名下没有路由')),
                for (final r in routes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.alt_route),
                    title: Text('${r['pattern']}', style: const TextStyle(fontFamily: 'monospace')),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await runAction(context, () => c.delete('/zones/$zoneId/workers/routes/${r['id']}'));
                        await h.reload();
                      },
                    ),
                  ),
              ],
            ),
            SectionCard(
              title: context.tr('Cron triggers', 'Cron 触发器'),
              trailing: TextButton.icon(
                icon: const Icon(Icons.edit),
                label: Text(context.tr('Edit', '编辑')),
                onPressed: () async {
                  final text = await promptText(
                    context,
                    title: context.tr('Cron expressions (one per line, UTC)', 'Cron 表达式（每行一个，UTC）'),
                    initial: schedules.map((s) => s['cron']).join('\n'),
                    hint: '*/30 * * * *',
                    multiline: true,
                    monospace: true,
                    confirmLabel: context.tr('Save', '保存'),
                  );
                  if (text == null || !context.mounted) return;
                  final crons = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).map((e) => {'cron': e}).toList();
                  await runAction(context, () => c.put('${_scriptPath(accountId, script)}/schedules', data: crons), success: context.tr('Saved', '已保存'));
                  await h.reload();
                },
              ),
              children: [
                if (schedules.isEmpty) Text(context.tr('No cron triggers', '没有 Cron 触发器')),
                for (final s in schedules)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: Text('${s['cron']}', style: const TextStyle(fontFamily: 'monospace')),
                    subtitle: s['modified_on'] == null ? null : Text(formatDate(s['modified_on'])),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Deployments & versions

class _DeploymentsTab extends ConsumerWidget {
  const _DeploymentsTab({required this.script});

  final String script;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider)!;
    return ApiQuery<(List<dynamic>, List<dynamic>)>(
      cacheKey: 'worker-deployments:$accountId:$script',
      load: (c) async {
        final d = await c.get('${_scriptPath(accountId, script)}/deployments');
        final v = await c.get('${_scriptPath(accountId, script)}/versions');
        return (
          (d is Map ? d['deployments'] as List? : d as List?) ?? const [],
          (v is Map ? (v['items'] ?? v['versions']) as List? : v as List?) ?? const [],
        );
      },
      builder: (context, data, h) {
        final (deployments, versions) = data;
        final active = deployments.isEmpty ? null : deployments.first as Map;
        final activeVersions = ((active?['versions'] as List?) ?? const []).map((e) => (e as Map)['version_id']).toSet();
        final c = ref.read(clientProvider)!;
        return ContentList(
          onRefresh: h.reload,
          children: [
            if (active != null)
              SectionCard(
                title: context.tr('Active deployment', '当前部署'),
                children: [
                  for (final v in (active['versions'] as List? ?? const []).cast<Map>())
                    InfoRow('${v['percentage']}%', '${v['version_id']}', mono: true, copy: true),
                  InfoRow(context.tr('Deployed', '部署时间'), formatDate(active['created_on'])),
                  if (active['author_email'] != null) InfoRow(context.tr('Author', '作者'), '${active['author_email']}'),
                  if ((active['annotations'] as Map?)?['workers/message'] != null)
                    InfoRow(context.tr('Message', '说明'), '${(active['annotations'] as Map)['workers/message']}'),
                ],
              ),
            SectionCard(
              title: context.tr('Versions', '版本'),
              children: [
                for (final v in versions.cast<Map>())
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 16, child: Text('${v['number'] ?? '?'}', style: const TextStyle(fontSize: 12))),
                    title: Text('${v['id']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    subtitle: Text([
                      formatDate((v['metadata'] as Map?)?['created_on']),
                      (v['metadata'] as Map?)?['author_email'],
                      (v['metadata'] as Map?)?['source'],
                      (v['annotations'] as Map?)?['workers/message'],
                    ].whereType<String>().join(' · ')),
                    trailing: activeVersions.contains(v['id'])
                        ? const StatusChip('active', tone: Tone.good)
                        : TextButton(
                            onPressed: () async {
                              final msg = await promptText(
                                context,
                                title: context.tr('Deploy version ${v['number'] ?? ''} (100%)', '部署版本 ${v['number'] ?? ''}（100%）'),
                                label: context.tr('Message (optional)', '说明（可选）'),
                                confirmLabel: context.tr('Deploy', '部署'),
                              );
                              if (msg == null || !context.mounted) return;
                              await runAction(
                                context,
                                () => c.post('${_scriptPath(accountId, script)}/deployments', data: {
                                  'strategy': 'percentage',
                                  'versions': [
                                    {'version_id': v['id'], 'percentage': 100},
                                  ],
                                  if (msg.trim().isNotEmpty) 'annotations': {'workers/message': msg.trim()},
                                }),
                                success: context.tr('Deployed', '已部署'),
                              );
                              await h.reload();
                            },
                            child: Text(context.tr('Deploy', '部署')),
                          ),
                    onTap: () => showJsonDialog(context, v),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Live tail

class _TailTab extends ConsumerStatefulWidget {
  const _TailTab({required this.script});

  final String script;

  @override
  ConsumerState<_TailTab> createState() => _TailTabState();
}

class _TailTabState extends ConsumerState<_TailTab> with AutomaticKeepAliveClientMixin {
  WorkerTailSession? _session;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final List<Map<String, dynamic>> _events = [];
  bool _connecting = false;
  String? _error;
  String _filter = '';

  @override
  bool get wantKeepAlive => true;

  Future<void> _start() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final CfClient c = ref.read(clientProvider)!;
      final s = await WorkerTailSession.start(c, ref.read(currentAccountIdProvider)!, widget.script);
      _session = s;
      _sub = s.events.listen(
        (e) => setState(() {
          _events.insert(0, e);
          if (_events.length > 500) _events.removeLast();
        }),
        onError: (Object e) => setState(() => _error = e.toString()),
        onDone: () {
          if (mounted) setState(() => _session = null);
        },
      );
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    await _session?.close();
    if (mounted) setState(() => _session = null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final live = _session != null;
    final f = _filter.toLowerCase();
    final list = f.isEmpty ? _events : _events.where((e) => e.toString().toLowerCase().contains(f)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Expanded(child: SearchField(hint: context.tr('Filter logs', '过滤日志'), onChanged: (v) => setState(() => _filter = v.trim()))),
              const SizedBox(width: 8),
              if (live)
                FilledButton.tonalIcon(onPressed: _stop, icon: const Icon(Icons.stop), label: Text(context.tr('Stop', '停止')))
              else
                FilledButton.icon(
                  onPressed: _connecting ? null : _start,
                  icon: _connecting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
                  label: Text(context.tr('Start tail', '开始实时日志')),
                ),
              IconButton(tooltip: context.tr('Clear', '清空'), icon: const Icon(Icons.clear_all), onPressed: () => setState(_events.clear)),
            ],
          ),
        ),
        if (live)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.circle, color: Colors.green, size: 10),
                const SizedBox(width: 6),
                Text(context.tr('Streaming live events…', '正在接收实时事件…'), style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
        Expanded(
          child: list.isEmpty
              ? EmptyView(
                  icon: Icons.stream,
                  title: live ? context.tr('Waiting for requests…', '等待请求…') : context.tr('Not streaming', '未开始'),
                  subtitle: context.tr('Send a request to your Worker to see logs here.', '向 Worker 发送请求即可在这里看到日志。'),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => _TailEventTile(event: list[i]),
                ),
        ),
      ],
    );
  }
}

class _TailEventTile extends StatelessWidget {
  const _TailEventTile({required this.event});

  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = ((event['event'] as Map?)?['request'] as Map?) ?? const {};
    final res = ((event['event'] as Map?)?['response'] as Map?) ?? const {};
    final outcome = '${event['outcome'] ?? ''}';
    final logs = (event['logs'] as List? ?? const []).cast<Map>();
    final exceptions = (event['exceptions'] as List? ?? const []).cast<Map>();
    final ts = event['eventTimestamp'];
    final cron = (event['event'] as Map?)?['cron'];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => showJsonDialog(context, event),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusChip(outcome, tone: outcome == 'ok' ? Tone.good : Tone.bad),
                  const SizedBox(width: 8),
                  if (res['status'] != null) Text('${res['status']} ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      cron != null ? 'cron $cron' : '${req['method'] ?? ''} ${req['url'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  Text(ts is num ? formatDate(ts) : '', style: theme.textTheme.bodySmall),
                ],
              ),
              for (final l in logs)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '[${l['level']}] ${(l['message'] is List ? (l['message'] as List).join(' ') : l['message'])}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: l['level'] == 'error' ? theme.colorScheme.error : (l['level'] == 'warn' ? Colors.orange : null),
                    ),
                  ),
                ),
              for (final ex in exceptions)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('⚠ ${ex['name']}: ${ex['message']}', style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: theme.colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

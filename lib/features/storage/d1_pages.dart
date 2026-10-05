import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/code_editor.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';

String _dbs(String accountId) => '/accounts/$accountId/d1/database';

class D1DatabasesPage extends ConsumerWidget {
  const D1DatabasesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: 'D1',
      builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'd1:$accountId',
        frame: (w) => PageScaffold(title: 'D1', body: w),
        load: (c) => c.list(_dbs(accountId), perPage: 100),
        builder: (context, dbs, h) {
          final c = ref.read(clientProvider)!;
          return PageScaffold(
            title: context.tr('D1 databases', 'D1 数据库'),
            actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Create database', '创建数据库')),
              onPressed: () async {
                final name = await promptText(context, title: context.tr('Database name', '数据库名称'), hint: 'prod-db');
                if (name == null || name.trim().isEmpty || !context.mounted) return;
                await runAction(
                  context,
                  () => c.post(_dbs(accountId), data: {'name': name.trim()}),
                  success: context.tr('Created', '已创建'),
                );
                await h.reload();
              },
            ),
            body: dbs.isEmpty
                ? EmptyView(icon: Icons.table_chart_outlined, title: context.tr('No databases', '没有数据库'))
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96, top: 8),
                    itemCount: dbs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, i) {
                      final d = dbs[i];
                      final id = d['uuid'] as String;
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.storage)),
                        title: Text('${d['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            if (d['num_tables'] != null)
                              context.tr('${d['num_tables']} tables', '${d['num_tables']} 张表'),
                            if (d['file_size'] != null) formatBytes(d['file_size'] as num),
                            if (d['version'] != null) '${d['version']}',
                            formatDate(d['created_at'], withTime: false),
                          ].join(' · '),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'copy') {
                              await copyText(context, id);
                            } else if (v == 'delete') {
                              final ok = await confirmDanger(
                                context,
                                title: context.tr('Delete database?', '删除数据库？'),
                                message: context.tr('All data will be permanently lost.', '所有数据将永久丢失。'),
                                typeToConfirm: d['name'] as String?,
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(
                                context,
                                () => c.delete('${_dbs(accountId)}/$id'),
                                success: context.tr('Deleted', '已删除'),
                              );
                              await h.reload();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 'copy', child: Text(context.tr('Copy ID', '复制 ID'))),
                            PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                          ],
                        ),
                        onTap: () => context.push('/d1/$id?name=${Uri.encodeComponent('${d['name']}')}'),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

class _QueryResult {
  _QueryResult({required this.columns, required this.rows, required this.meta, required this.sql});

  final List<String> columns;
  final List<List<Object?>> rows;
  final Map<String, dynamic> meta;
  final String sql;
}

class D1ConsolePage extends ConsumerStatefulWidget {
  const D1ConsolePage({super.key, required this.databaseId, this.name});

  final String databaseId;
  final String? name;

  @override
  ConsumerState<D1ConsolePage> createState() => _D1ConsolePageState();
}

class _D1ConsolePageState extends ConsumerState<D1ConsolePage> {
  final _sql = CodeLineEditingController.fromText('SELECT name, type FROM sqlite_master ORDER BY name;');
  List<_QueryResult> _results = [];
  List<String> _tables = [];
  final List<String> _history = [];
  bool _running = false;
  Object? _error;

  String get _base => '${_dbs(ref.read(currentAccountIdProvider)!)}/${widget.databaseId}';

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  Future<List<_QueryResult>> _exec(String sql) async {
    final c = ref.read(clientProvider)!;
    final r = await c.post('$_base/raw', data: {'sql': sql});
    final list = r is List ? r : [r];
    return [
      for (final s in list.whereType<Map>())
        _QueryResult(
          sql: sql,
          columns: (((s['results'] as Map?)?['columns'] as List?) ?? const []).map((e) => '$e').toList(),
          rows: (((s['results'] as Map?)?['rows'] as List?) ?? const [])
              .map((r) => (r as List).cast<Object?>())
              .toList(),
          meta: Map<String, dynamic>.from(s['meta'] as Map? ?? const {}),
        ),
    ];
  }

  Future<void> _loadTables() async {
    try {
      final r = await _exec(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY name;",
      );
      if (!mounted) return;
      setState(() => _tables = r.isEmpty ? [] : r.first.rows.map((e) => '${e.first}').toList());
    } catch (_) {}
  }

  Future<void> _run([String? sql]) async {
    final q = (sql ?? _sql.text).trim();
    if (q.isEmpty) return;
    final destructive = RegExp(r'\b(drop|delete|truncate|alter)\b', caseSensitive: false).hasMatch(q);
    if (destructive &&
        !await confirm(
          context,
          title: context.tr('Run a destructive statement?', '执行破坏性语句？'),
          message: q.length > 400 ? '${q.substring(0, 400)}…' : q,
          destructive: true,
        )) {
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await _exec(q);
      if (!mounted) return;
      setState(() {
        _results = r;
        _history.remove(q);
        _history.insert(0, q);
        if (_history.length > 30) _history.removeLast();
      });
      if (RegExp(r'\b(create|drop|alter)\b', caseSensitive: false).hasMatch(q)) await _loadTables();
    } catch (e) {
      setState(() => _error = e);
    }
    if (mounted) setState(() => _running = false);
  }

  void _openTable(String t) {
    final q = 'SELECT * FROM "${t.replaceAll('"', '""')}" LIMIT 100;';
    _sql.text = q;
    _run(q);
  }

  Widget _tablesPanel(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          dense: true,
          title: Text(context.tr('Tables', '表'), style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _loadTables),
        ),
        for (final t in _tables)
          ListTile(
            dense: true,
            leading: const Icon(Icons.table_rows_outlined, size: 18),
            title: Text(t, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            onTap: () => _openTable(t),
            trailing: IconButton(
              tooltip: context.tr('Schema', '结构'),
              icon: const Icon(Icons.info_outline, size: 16),
              onPressed: () => _run('PRAGMA table_info("${t.replaceAll('"', '""')}");'),
            ),
          ),
        if (_history.isNotEmpty) ...[
          const Divider(),
          ListTile(
            dense: true,
            title: Text(context.tr('History', '历史'), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          for (final h in _history)
            ListTile(
              dense: true,
              title: Text(
                h,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              onTap: () => _sql.text = h,
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context) && MediaQuery.sizeOf(context).width > 1100;
    final editor = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
      },
      child: SizedBox(
        height: 180,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CodeEditorField(controller: _sql, language: 'sql'),
          ),
        ),
      ),
    );
    final results = _error != null
        ? ErrorView(error: _error!, compact: true)
        : _results.isEmpty
        ? EmptyView(icon: Icons.grid_on, title: context.tr('Run a query to see results', '执行查询以查看结果'))
        : ListView(
            children: [
              for (final r in _results) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    [
                      context.tr('${r.rows.length} rows', '${r.rows.length} 行'),
                      if (r.meta['duration'] != null) '${(r.meta['duration'] as num).toStringAsFixed(2)} ms',
                      if (r.meta['rows_read'] != null) 'read ${r.meta['rows_read']}',
                      if (r.meta['rows_written'] != null) 'written ${r.meta['rows_written']}',
                      if (r.meta['changes'] != null) 'changes ${r.meta['changes']}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                if (r.columns.isNotEmpty) ResultTable(columns: r.columns, rows: r.rows),
              ],
            ],
          );
    return PageScaffold(
      title: widget.name ?? 'D1',
      subtitle: widget.databaseId,
      actions: [
        if (!wide)
          IconButton(
            tooltip: context.tr('Tables', '表'),
            icon: const Icon(Icons.table_view),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => SizedBox(height: 420, child: _tablesPanel(context)),
            ),
          ),
        IconButton(
          tooltip: context.tr('Database info', '数据库信息'),
          icon: const Icon(Icons.info_outline),
          onPressed: () async {
            final c = ref.read(clientProvider)!;
            final info = await runAction(context, () => c.get(_base));
            if (info != null && context.mounted) await showJsonDialog(context, info, title: widget.name);
          },
        ),
      ],
      body: Row(
        children: [
          if (wide) SizedBox(width: 260, child: _tablesPanel(context)),
          if (wide) const VerticalDivider(width: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  editor,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        context.tr('Ctrl/⌘ + Enter to run', 'Ctrl/⌘ + Enter 执行'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _running ? null : _run,
                        icon: _running
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.play_arrow),
                        label: Text(context.tr('Run', '执行')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: results),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scrollable result grid.
class ResultTable extends StatelessWidget {
  const ResultTable({super.key, required this.columns, required this.rows});

  final List<String> columns;
  final List<List<Object?>> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String cell(Object? v) => v == null ? 'NULL' : (v is Map || v is List ? prettyJson(v) : '$v');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 44,
        columnSpacing: 24,
        headingTextStyle: theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'),
        columns: [for (final c in columns) DataColumn(label: Text(c))],
        rows: [
          for (final r in rows.take(2000))
            DataRow(
              cells: [
                for (var i = 0; i < columns.length; i++)
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        i < r.length ? cell(r[i]) : '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: i < r.length && r[i] == null ? theme.colorScheme.outline : null,
                        ),
                      ),
                    ),
                    onTap: () => copyText(context, i < r.length ? cell(r[i]) : ''),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

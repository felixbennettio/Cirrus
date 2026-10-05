import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import 'workers_api.dart';

class WorkersListPage extends ConsumerStatefulWidget {
  const WorkersListPage({super.key});

  @override
  ConsumerState<WorkersListPage> createState() => _WorkersListPageState();
}

class _WorkersListPageState extends ConsumerState<WorkersListPage> {
  String _q = '';

  Future<void> _create(String accountId, QueryHandle h) async {
    final name = TextEditingController();
    var template = workerTemplates.keys.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(ctx.tr('Create Worker', '创建 Worker')),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: ctx.tr('Name', '名称'),
                    hintText: 'my-worker',
                    helperText: ctx.tr('Lowercase letters, numbers and dashes', '小写字母、数字和短横线'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: template,
                  decoration: InputDecoration(labelText: ctx.tr('Template', '模板'), border: const OutlineInputBorder()),
                  items: [for (final t in workerTemplates.keys) DropdownMenuItem(value: t, child: Text(t))],
                  onChanged: (v) => setState(() => template = v ?? template),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Deploy', '部署'))),
          ],
        ),
      ),
    );
    final script = name.text.trim().toLowerCase();
    name.dispose();
    if (ok != true || script.isEmpty || !mounted) return;
    final client = ref.read(clientProvider)!;
    final r = await runAction(context, () async {
      await createWorker(client, accountId, script, workerTemplates[template]!);
      // Expose it on workers.dev so it is reachable right away.
      try {
        await client.post('/accounts/$accountId/workers/scripts/$script/subdomain', data: {'enabled': true});
      } catch (_) {}
      return true;
    }, success: context.tr('Worker deployed', 'Worker 已部署'));
    if (r == true && mounted) {
      await h.reload();
      if (mounted) context.push('/workers/${Uri.encodeComponent(script)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AccountRequired(
      pageTitle: 'Workers',
      builder: (context, accountId) => ApiQuery<(List<Map<String, dynamic>>, Map<String, (double, double)>, String?)>(
        cacheKey: 'workers:$accountId',
        frame: (w) => PageScaffold(title: 'Workers', body: w),
        load: (c) async {
          final results = await Future.wait([
            c.list('/accounts/$accountId/workers/scripts', paginate: false),
            fetchWorkersSummary(c, accountId).catchError((_) => <String, (double, double)>{}),
            c
                .get('/accounts/$accountId/workers/subdomain')
                .then((v) => (v as Map?)?['subdomain'] as String?)
                .catchError((_) => null),
          ]);
          return (
            results[0] as List<Map<String, dynamic>>,
            results[1] as Map<String, (double, double)>,
            results[2] as String?,
          );
        },
        builder: (context, data, h) {
          final (scripts, metrics, subdomain) = data;
          final q = _q.toLowerCase();
          final list = scripts.where((s) => q.isEmpty || '${s['id']}'.toLowerCase().contains(q)).toList()
            ..sort((a, b) => '${b['modified_on']}'.compareTo('${a['modified_on']}'));
          return PageScaffold(
            title: 'Workers',
            subtitle: subdomain == null ? null : '$subdomain.workers.dev',
            actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _create(accountId, h),
              icon: const Icon(Icons.add),
              label: Text(context.tr('Create', '创建')),
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: SearchField(onChanged: (v) => setState(() => _q = v.trim())),
                ),
                Expanded(
                  child: list.isEmpty
                      ? EmptyView(icon: Icons.bolt, title: context.tr('No Workers yet', '还没有 Worker'))
                      : RefreshIndicator(
                          onRefresh: h.reload,
                          child: ListView.separated(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: list.length,
                            separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                            itemBuilder: (context, i) {
                              final s = list[i];
                              final name = s['id'] as String;
                              final m = metrics[name];
                              final handlers = (s['handlers'] as List?)?.join(', ');
                              return ListTile(
                                leading: const CircleAvatar(child: Icon(Icons.bolt)),
                                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  [
                                    '${context.tr('modified', '修改于')} ${formatRelative(s['modified_on'], zh: context.isZh)}',
                                    ?handlers,
                                  ].join(' · '),
                                ),
                                trailing: m == null
                                    ? null
                                    : Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            '${formatCount(m.$1)} req',
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                          if (m.$2 > 0)
                                            Text(
                                              '${formatCount(m.$2)} err',
                                              style: TextStyle(
                                                color: Theme.of(context).colorScheme.error,
                                                fontSize: 12,
                                              ),
                                            ),
                                        ],
                                      ),
                                onTap: () => context.push('/workers/${Uri.encodeComponent(name)}'),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

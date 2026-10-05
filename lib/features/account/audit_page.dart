import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/json_view.dart';

class AuditLogPage extends ConsumerStatefulWidget {
  const AuditLogPage({super.key});

  @override
  ConsumerState<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends ConsumerState<AuditLogPage> {
  String _q = '';
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: context.tr('Audit log', '审计日志'),
      body: AccountRequired(
        builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
          cacheKey: 'audit:$accountId:$_days',
          load: (c) => c.list(
            '/accounts/$accountId/audit_logs',
            query: {
              'direction': 'desc',
              'since': DateTime.now().toUtc().subtract(Duration(days: _days)).toIso8601String(),
            },
            perPage: 100,
            maxItems: 1000,
          ),
          builder: (context, logs, h) {
            final q = _q.toLowerCase();
            final list = q.isEmpty ? logs : logs.where((l) => l.toString().toLowerCase().contains(q)).toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(
                    children: [
                      Expanded(child: SearchField(hint: context.tr('Filter by actor, action, resource', '按操作者、动作、资源过滤'), onChanged: (v) => setState(() => _q = v.trim()))),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _days,
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('24h')),
                          DropdownMenuItem(value: 7, child: Text('7d')),
                          DropdownMenuItem(value: 30, child: Text('30d')),
                          DropdownMenuItem(value: 90, child: Text('90d')),
                        ],
                        onChanged: (v) => setState(() => _days = v ?? 7),
                      ),
                      IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? EmptyView(icon: Icons.history, title: context.tr('No events', '没有事件'))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final l = list[i];
                            final action = l['action'] as Map? ?? const {};
                            final actor = l['actor'] as Map? ?? const {};
                            final resource = l['resource'] as Map? ?? const {};
                            final ok = action['result'] != false;
                            return ListTile(
                              dense: true,
                              leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? Colors.green : Theme.of(context).colorScheme.error),
                              title: Text('${action['type'] ?? ''} · ${resource['type'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${actor['email'] ?? actor['type'] ?? ''} · ${actor['ip'] ?? ''} · ${formatDate(l['when'])}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => showJsonDialog(context, l, title: '${action['type'] ?? 'Event'}'),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

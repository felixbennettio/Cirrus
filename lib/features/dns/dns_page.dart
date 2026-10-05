import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/files.dart';
import '../../ui/widgets/json_view.dart';
import 'dns_record_form.dart';

const _cfOrange = Color(0xFFF38020);

class DnsPage extends ConsumerWidget {
  const DnsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(currentZoneProvider);
    if (zone == null) {
      return PageScaffold(title: 'DNS', body: ZoneRequired(builder: (_, _, _) => const SizedBox()));
    }
    return _DnsView(key: ValueKey(zone['id']), zoneId: zone['id'] as String, zoneName: zone['name'] as String);
  }
}

class _DnsView extends ConsumerStatefulWidget {
  const _DnsView({super.key, required this.zoneId, required this.zoneName});

  final String zoneId;
  final String zoneName;

  @override
  ConsumerState<_DnsView> createState() => _DnsViewState();
}

class _DnsViewState extends ConsumerState<_DnsView> {
  String _q = '';
  String _type = 'ALL';
  bool? _proxied;
  final Set<String> _selected = {};

  String get _base => '/zones/${widget.zoneId}/dns_records';

  CfClient get _client => ref.read(clientProvider)!;

  String _rel(String name) {
    if (name == widget.zoneName) return '@';
    final suffix = '.${widget.zoneName}';
    return name.endsWith(suffix) ? name.substring(0, name.length - suffix.length) : name;
  }

  Future<void> _add(QueryHandle<List<Map<String, dynamic>>> h) async {
    final body = await showDnsRecordDialog(context, zoneName: widget.zoneName);
    if (body == null || !mounted) return;
    final r = await runAction(context, () => _client.send('POST', _base, data: body), success: context.tr('Record added', '记录已添加'));
    if (r != null) await h.reload();
  }

  Future<void> _edit(Map<String, dynamic> rec, QueryHandle<List<Map<String, dynamic>>> h) async {
    final body = await showDnsRecordDialog(context, zoneName: widget.zoneName, record: rec);
    if (body == null || !mounted) return;
    final r = await runAction(
      context,
      () => _client.send('PATCH', '$_base/${rec['id']}', data: body),
      success: context.tr('Record updated', '记录已更新'),
    );
    if (r != null) await h.reload();
  }

  Future<void> _delete(List<Map<String, dynamic>> recs, QueryHandle<List<Map<String, dynamic>>> h) async {
    final ok = await confirmDanger(
      context,
      title: recs.length == 1
          ? context.tr('Delete record?', '删除记录？')
          : context.tr('Delete ${recs.length} records?', '删除 ${recs.length} 条记录？'),
      message: recs.take(8).map((r) => '${r['type']}  ${r['name']}  →  ${r['content'] ?? ''}').join('\n') +
          (recs.length > 8 ? '\n…' : ''),
    );
    if (!ok || !mounted) return;
    final r = await runAction(context, () async {
      if (recs.length == 1) {
        await _client.delete('$_base/${recs.first['id']}');
      } else {
        // Batch API: up to 200 operations per call is plenty for UI use.
        for (var i = 0; i < recs.length; i += 200) {
          final chunk = recs.sublist(i, i + 200 > recs.length ? recs.length : i + 200);
          await _client.post('$_base/batch', data: {
            'deletes': [for (final r in chunk) {'id': r['id']}],
          });
        }
      }
      return true;
    }, success: context.tr('Deleted', '已删除'));
    if (r == true) {
      _selected.clear();
      await h.reload();
    }
  }

  Future<void> _toggleProxy(Map<String, dynamic> rec, QueryHandle<List<Map<String, dynamic>>> h, List<Map<String, dynamic>> all) async {
    final v = !(rec['proxied'] == true);
    // Optimistic update.
    h.setData([for (final r in all) r['id'] == rec['id'] ? {...r, 'proxied': v} : r]);
    final r = await runAction(
      context,
      () => _client.send('PATCH', '$_base/${rec['id']}', data: {'proxied': v}),
      blocking: false,
    );
    if (r == null) await h.reload();
  }

  Future<void> _export() async {
    final r = await runAction(context, () => _client.rawOk('GET', '$_base/export'));
    if (r == null || !mounted) return;
    await saveBytes(context, fileName: '${widget.zoneName}.txt', bytes: r.bytes, mimeType: 'text/plain');
  }

  Future<void> _import(QueryHandle<List<Map<String, dynamic>>> h) async {
    final f = await pickFile();
    if (f == null || !mounted) return;
    var proxied = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(ctx.tr('Import BIND file', '导入 BIND 文件')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${f.name} · ${formatBytes(f.bytes.length)}'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: proxied,
                onChanged: (v) => setState(() => proxied = v ?? false),
                title: Text(ctx.tr('Proxy imported A/AAAA/CNAME records', '代理导入的 A/AAAA/CNAME 记录')),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Import', '导入'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final res = await runAction(
      context,
      () => _client.send(
        'POST',
        '$_base/import',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(f.bytes, filename: f.name),
          'proxied': proxied.toString(),
        }),
      ),
    );
    if (res == null || !mounted) return;
    final result = res.result as Map? ?? const {};
    showToast(
      context,
      context.tr(
        'Imported ${result['recs_added'] ?? '?'} of ${result['total_records_parsed'] ?? '?'} records',
        '已导入 ${result['recs_added'] ?? '?'} / ${result['total_records_parsed'] ?? '?'} 条记录',
      ),
    );
    await h.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'dns:${widget.zoneId}',
      frame: (w) => PageScaffold(title: 'DNS', subtitle: widget.zoneName, body: w),
      load: (c) => c.list(_base, perPage: 1000, maxItems: 100000, query: {'order': 'type'}),
      builder: (context, all, h) {
        final q = _q.toLowerCase();
        final types = {for (final r in all) r['type'] as String}.toList()..sort();
        final list = all.where((r) {
          if (_type != 'ALL' && r['type'] != _type) return false;
          if (_proxied != null && (r['proxied'] == true) != _proxied) return false;
          if (q.isEmpty) return true;
          return '${r['name']} ${r['content']} ${r['comment'] ?? ''} ${(r['tags'] as List?)?.join(' ') ?? ''}'.toLowerCase().contains(q);
        }).toList()
          ..sort((a, b) {
            final n = (a['name'] as String).compareTo(b['name'] as String);
            return n != 0 ? n : (a['type'] as String).compareTo(b['type'] as String);
          });
        final selecting = _selected.isNotEmpty;
        return PageScaffold(
          title: selecting ? context.tr('${_selected.length} selected', '已选 ${_selected.length} 条') : 'DNS',
          subtitle: selecting ? null : widget.zoneName,
          leading: selecting ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)) : null,
          actions: selecting
              ? [
                  IconButton(
                    tooltip: context.tr('Select all', '全选'),
                    icon: const Icon(Icons.select_all),
                    onPressed: () => setState(() => _selected.addAll(list.map((r) => r['id'] as String))),
                  ),
                  IconButton(
                    tooltip: context.tr('Delete', '删除'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(all.where((r) => _selected.contains(r['id'])).toList(), h),
                  ),
                ]
              : [
                  IconButton(tooltip: context.tr('Refresh', '刷新'), icon: const Icon(Icons.refresh), onPressed: h.reload),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'import':
                          _import(h);
                        case 'export':
                          _export();
                        case 'dnssec':
                          showDialog<void>(context: context, builder: (_) => _DnssecDialog(zoneId: widget.zoneId));
                        case 'settings':
                          showDialog<void>(context: context, builder: (_) => _DnsSettingsDialog(zoneId: widget.zoneId));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'import', child: Text(context.tr('Import BIND file…', '导入 BIND 文件…'))),
                      PopupMenuItem(value: 'export', child: Text(context.tr('Export BIND file', '导出 BIND 文件'))),
                      const PopupMenuItem(value: 'dnssec', child: Text('DNSSEC')),
                      PopupMenuItem(value: 'settings', child: Text(context.tr('DNS settings', 'DNS 设置'))),
                    ],
                  ),
                ],
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(h),
            icon: const Icon(Icons.add),
            label: Text(context.tr('Add record', '添加记录')),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SearchField(
                        hint: context.tr('Search name, content, comment, tag', '搜索名称、内容、备注、标签'),
                        onChanged: (v) => setState(() => _q = v.trim()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: types.contains(_type) || _type == 'ALL' ? _type : 'ALL',
                      underline: const SizedBox(),
                      items: [
                        DropdownMenuItem(value: 'ALL', child: Text(context.tr('All types', '全部类型'))),
                        for (final t in types) DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged: (v) => setState(() => _type = v ?? 'ALL'),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<int>(
                      tooltip: context.tr('Proxy status', '代理状态'),
                      icon: Icon(Icons.cloud, color: _proxied == null ? null : (_proxied! ? _cfOrange : Colors.grey)),
                      onSelected: (v) => setState(() => _proxied = v == 0 ? null : v == 1),
                      itemBuilder: (context) => [
                        PopupMenuItem(value: 0, child: Text(context.tr('All', '全部'))),
                        PopupMenuItem(value: 1, child: Text(context.tr('Proxied', '已代理'))),
                        PopupMenuItem(value: 2, child: Text(context.tr('DNS only', '仅 DNS'))),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      context.tr('${list.length} of ${all.length} records', '${list.length} / ${all.length} 条记录'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? EmptyView(icon: Icons.dns_outlined, title: context.tr('No records', '没有记录'))
                    : RefreshIndicator(
                        onRefresh: h.reload,
                        child: ListView.separated(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                          itemBuilder: (context, i) {
                            final r = list[i];
                            final id = r['id'] as String;
                            return _RecordTile(
                              record: r,
                              relName: _rel(r['name'] as String),
                              selected: _selected.contains(id),
                              selecting: selecting,
                              onTap: () => selecting
                                  ? setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id))
                                  : _edit(r, h),
                              onLongPress: () => setState(() => _selected.add(id)),
                              onToggleProxy: () => _toggleProxy(r, h, all),
                              onDelete: () => _delete([r], h),
                              onJson: () => showJsonDialog(context, r, title: '${r['type']} ${r['name']}'),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.relName,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleProxy,
    required this.onDelete,
    required this.onJson,
  });

  final Map<String, dynamic> record;
  final String relName;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleProxy;
  final VoidCallback onDelete;
  final VoidCallback onJson;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = record['type'] as String;
    final proxiable = proxiableTypes.contains(type);
    final proxied = record['proxied'] == true;
    final content = record['content']?.toString() ?? '';
    final priority = record['priority'];
    final comment = record['comment'] as String?;
    final tags = (record['tags'] as List?)?.cast<String>() ?? const [];
    final wide = isWide(context);
    final typeBadge = Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(type, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: theme.colorScheme.onSecondaryContainer)),
    );
    final proxy = proxiable
        ? Tooltip(
            message: proxied ? context.tr('Proxied — click to make DNS only', '已代理——点击切换为仅 DNS') : context.tr('DNS only — click to proxy', '仅 DNS——点击开启代理'),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: selecting ? null : onToggleProxy,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(proxied ? Icons.cloud : Icons.cloud_outlined, color: proxied ? _cfOrange : theme.colorScheme.outline),
              ),
            ),
          )
        : const SizedBox(width: 36);
    return ListTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selecting ? Checkbox(value: selected, onChanged: (_) => onTap()) : typeBadge,
      title: Text.rich(
        TextSpan(children: [
          TextSpan(text: relName, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (wide) ...[
            const TextSpan(text: '   '),
            TextSpan(
              text: '${priority != null ? '$priority ' : ''}$content',
              style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ]),
        maxLines: wide ? 1 : 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!wide)
            Text(
              '${priority != null ? '$priority ' : ''}$content',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          if (comment != null && comment.isNotEmpty || tags.isNotEmpty)
            Text(
              [if (comment != null && comment.isNotEmpty) '💬 $comment', ...tags.map((t) => '#$t')].join('  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide && !selecting) typeBadge,
          const SizedBox(width: 4),
          SizedBox(width: 48, child: Text(ttlLabel(context, record['ttl']), textAlign: TextAlign.center, style: theme.textTheme.bodySmall)),
          proxy,
          if (!selecting)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') onDelete();
                if (v == 'json') onJson();
                if (v == 'copy') copyText(context, content);
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'copy', child: Text(context.tr('Copy content', '复制内容'))),
                PopupMenuItem(value: 'json', child: Text(context.tr('View JSON', '查看 JSON'))),
                PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'), style: TextStyle(color: theme.colorScheme.error))),
              ],
            ),
        ],
      ),
    );
  }
}

class _DnssecDialog extends ConsumerWidget {
  const _DnssecDialog({required this.zoneId});

  final String zoneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('DNSSEC'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: ApiQuery<Map<String, dynamic>>(
          cacheKey: 'dnssec:$zoneId',
          cache: false,
          load: (c) async => Map<String, dynamic>.from(await c.get('/zones/$zoneId/dnssec') as Map),
          builder: (context, d, h) {
            final status = d['status'] as String? ?? 'disabled';
            final on = status == 'active' || status == 'pending';
            final client = ref.read(clientProvider)!;
            return ListView(
              children: [
                Row(
                  children: [
                    StatusChip(status, tone: StatusChip.toneFor(status == 'disabled' ? 'off' : status)),
                    const Spacer(),
                    FilledButton.tonal(
                      onPressed: () async {
                        await runAction(
                          context,
                          () => client.patch('/zones/$zoneId/dnssec', data: {'status': on ? 'disabled' : 'active'}),
                          success: on ? context.tr('DNSSEC disabled', 'DNSSEC 已关闭') : context.tr('DNSSEC enabled', 'DNSSEC 已开启'),
                        );
                        await h.reload();
                      },
                      child: Text(on ? context.tr('Disable', '关闭') : context.tr('Enable', '开启')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (d['ds'] != null) InfoRow(context.tr('DS record', 'DS 记录'), d['ds'].toString(), copy: true, mono: true),
                for (final k in const ['digest', 'digest_type', 'algorithm', 'key_tag', 'flags', 'public_key', 'modified_on'])
                  if (d[k] != null) InfoRow(k, d[k].toString(), copy: k == 'digest' || k == 'public_key', mono: true),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Close', '关闭')))],
    );
  }
}

class _DnsSettingsDialog extends ConsumerWidget {
  const _DnsSettingsDialog({required this.zoneId});

  final String zoneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: Text(context.tr('DNS settings', 'DNS 设置')),
      content: SizedBox(
        width: 560,
        height: 460,
        child: ApiQuery<Map<String, dynamic>>(
          cacheKey: 'dns-settings:$zoneId',
          cache: false,
          load: (c) async => Map<String, dynamic>.from(await c.get('/zones/$zoneId/dns_settings') as Map),
          builder: (context, d, h) {
            final client = ref.read(clientProvider)!;
            Future<void> patch(Map<String, dynamic> body) async {
              await runAction(context, () => client.patch('/zones/$zoneId/dns_settings', data: body), success: context.tr('Saved', '已保存'));
              await h.reload();
            }

            return ListView(
              children: [
                for (final k in const ['flatten_all_cnames', 'foundation_dns', 'multi_provider', 'secondary_overrides'])
                  if (d[k] is bool)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(k),
                      value: d[k] as bool,
                      onChanged: (v) => patch({k: v}),
                    ),
                if (d['ns_ttl'] != null) InfoRow('ns_ttl', '${d['ns_ttl']}'),
                if (d['zone_mode'] != null) InfoRow('zone_mode', '${d['zone_mode']}'),
                const SizedBox(height: 8),
                JsonTreeView(d, shrinkWrap: true, initiallyExpandedDepth: 1),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Close', '关闭')))],
    );
  }
}

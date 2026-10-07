import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../rules/phases.dart';
import '../rules/ruleset_view.dart';
import '../../ui/widgets/glass.dart';

String _lists(String accountId) => '/accounts/$accountId/rules/lists';

const _kinds = {
  'ip': L10nText('IP addresses', 'IP 地址'),
  'redirect': L10nText('Bulk redirects', '批量重定向'),
  'hostname': L10nText('Hostnames', '主机名'),
  'asn': L10nText('ASNs', 'ASN'),
};

class ListsPage extends ConsumerWidget {
  const ListsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: PageScaffold(
        title: context.tr('Lists', '列表'),
        bottom: TabBar(
          tabs: [
            Tab(text: context.tr('Lists', '列表')),
            Tab(text: context.tr('Bulk redirect rules', '批量重定向规则')),
          ],
        ),
        body: AccountRequired(
          builder: (context, accountId) => TabBarView(
            children: [
              _ListsView(accountId: accountId),
              RulesetPhaseView(
                meta: const PhaseMeta(
                  phase: 'http_request_redirect',
                  title: L10nText('Bulk redirect rules', '批量重定向规则'),
                  description: L10nText(
                    'Enable redirect lists with an expression. Rule action must be "redirect" with from_list.',
                    '用表达式启用重定向列表。规则动作需为 redirect 并使用 from_list。',
                  ),
                  icon: Icons.turn_right,
                  actions: ['redirect'],
                  templates: {
                    'redirect': {
                      'from_list': {'name': 'my_redirect_list', 'key': 'http.request.full_uri'},
                    },
                  },
                ),
                basePath: '/accounts/$accountId',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListsView extends ConsumerWidget {
  const _ListsView({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'lists:$accountId',
      load: (c) => c.list(_lists(accountId), paginate: false),
      builder: (context, lists, h) {
        final c = ref.read(clientProvider)!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Reference lists in expressions with \$list_name.', '在表达式中使用 \$list_name 引用列表。'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Create list', '创建列表')),
                    onPressed: () async {
                      final r = await showAppDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => const _CreateListDialog(),
                      );
                      if (r == null || !context.mounted) return;
                      await runAction(
                        context,
                        () => c.post(_lists(accountId), data: r),
                        success: context.tr('List created', '列表已创建'),
                      );
                      await h.reload();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: lists.isEmpty
                  ? EmptyView(icon: Icons.list_alt, title: context.tr('No lists', '没有列表'))
                  : ListView.separated(
                      itemCount: lists.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final l = lists[i];
                        return ListTile(
                          leading: const Icon(Icons.list_alt),
                          title: Text(
                            '\$${l['name']}',
                            style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${_kinds[l['kind']]?.of(context) ?? l['kind']} · ${l['num_items']} ${context.tr('items', '项')}${(l['description'] as String?)?.isNotEmpty == true ? ' · ${l['description']}' : ''}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await confirmDanger(
                                context,
                                title: context.tr('Delete list?', '删除列表？'),
                                message: context.tr('Rules referencing it must be removed first.', '需先删除引用该列表的规则。'),
                                typeToConfirm: l['name'] as String?,
                              );
                              if (!ok || !context.mounted) return;
                              await runAction(context, () => c.delete('${_lists(accountId)}/${l['id']}'));
                              await h.reload();
                            },
                          ),
                          onTap: () => context.push(
                            '/account/lists/${l['id']}?kind=${l['kind']}&name=${Uri.encodeComponent('${l['name']}')}',
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _CreateListDialog extends StatefulWidget {
  const _CreateListDialog();

  @override
  State<_CreateListDialog> createState() => _CreateListDialogState();
}

class _CreateListDialogState extends State<_CreateListDialog> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  String _kind = 'ip';

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('Create list', '创建列表')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: context.tr('Name', '名称'),
                helperText: context.tr('Lowercase letters, numbers and underscores', '小写字母、数字和下划线'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: context.tr('Type', '类型'), border: const OutlineInputBorder()),
              items: [for (final e in _kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value.of(context)))],
              onChanged: (v) => setState(() => _kind = v ?? 'ip'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              decoration: InputDecoration(
                labelText: context.tr('Description', '描述'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, {'name': _name.text.trim(), 'kind': _kind, 'description': _desc.text.trim()}),
          child: Text(context.tr('Create', '创建')),
        ),
      ],
    );
  }
}

class ListItemsPage extends ConsumerStatefulWidget {
  const ListItemsPage({super.key, required this.listId, required this.kind, this.name});

  final String listId;
  final String kind;
  final String? name;

  @override
  ConsumerState<ListItemsPage> createState() => _ListItemsPageState();
}

class _ListItemsPageState extends ConsumerState<ListItemsPage> {
  String _q = '';

  String _label(Map i) => switch (widget.kind) {
    'ip' => '${i['ip']}',
    'asn' => 'AS${i['asn']}',
    'hostname' => '${(i['hostname'] as Map?)?['url_hostname']}',
    'redirect' => '${(i['redirect'] as Map?)?['source_url']}  →  ${(i['redirect'] as Map?)?['target_url']}',
    _ => i.toString(),
  };

  Map<String, dynamic>? _parse(String line) {
    final parts = line.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final comment = parts.length > (widget.kind == 'redirect' ? 3 : 1)
        ? parts.sublist(widget.kind == 'redirect' ? 3 : 1).join(' ')
        : null;
    return switch (widget.kind) {
      'ip' => {'ip': parts[0], 'comment': ?comment},
      'asn' => {'asn': int.tryParse(parts[0].replaceAll(RegExp('as', caseSensitive: false), '')), 'comment': ?comment},
      'hostname' => {
        'hostname': {'url_hostname': parts[0]},
        'comment': ?comment,
      },
      'redirect' =>
        parts.length < 2
            ? null
            : {
                'redirect': {
                  'source_url': parts[0],
                  'target_url': parts[1],
                  'status_code': parts.length > 2 ? int.tryParse(parts[2]) ?? 301 : 301,
                },
                'comment': ?comment,
              },
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(currentAccountIdProvider);
    if (accountId == null) {
      return PageScaffold(
        title: widget.name ?? '',
        body: AccountRequired(builder: (_, _) => const SizedBox()),
      );
    }
    final base = '${_lists(accountId)}/${widget.listId}/items';
    return PageScaffold(
      title: '\$${widget.name ?? widget.listId}',
      subtitle: _kinds[widget.kind]?.of(context),
      body: ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'list-items:$base',
        load: (c) => c.list(base, perPage: 500, cursorPagination: true, maxItems: 100000),
        builder: (context, items, h) {
          final c = ref.read(clientProvider)!;
          final q = _q.toLowerCase();
          final list = q.isEmpty
              ? items
              : items
                    .where((i) => _label(i).toLowerCase().contains(q) || '${i['comment']}'.toLowerCase().contains(q))
                    .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: SearchField(onChanged: (v) => setState(() => _q = v.trim()))),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.add),
                      label: Text(context.tr('Add items', '添加条目')),
                      onPressed: () async {
                        final hint = switch (widget.kind) {
                          'ip' => '203.0.113.7 optional comment\n198.51.100.0/24',
                          'asn' => '13335\nAS15169',
                          'hostname' => 'www.example.com',
                          _ => 'https://old.example.com/a https://new.example.com/b 301',
                        };
                        final text = await promptText(
                          context,
                          title: context.tr('One item per line', '每行一个条目'),
                          hint: hint,
                          multiline: true,
                          monospace: true,
                        );
                        if (text == null || !context.mounted) return;
                        final parsed = text
                            .split('\n')
                            .map((l) => l.trim())
                            .where((l) => l.isNotEmpty)
                            .map(_parse)
                            .whereType<Map<String, dynamic>>()
                            .toList();
                        if (parsed.isEmpty) return;
                        await runAction(
                          context,
                          () => c.post(base, data: parsed),
                          success: context.tr('Items queued (applied asynchronously)', '条目已提交（异步生效）'),
                        );
                        await Future<void>.delayed(const Duration(seconds: 2));
                        await h.reload();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final it = list[i];
                    return ListTile(
                      dense: true,
                      title: Text(_label(it), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      subtitle: Text(
                        [if (it['comment'] != null) '${it['comment']}', formatDate(it['created_on'])].join(' · '),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () async {
                          await runAction(
                            context,
                            () => c.delete(
                              base,
                              data: {
                                'items': [
                                  {'id': it['id']},
                                ],
                              },
                            ),
                          );
                          await Future<void>.delayed(const Duration(seconds: 1));
                          await h.reload();
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

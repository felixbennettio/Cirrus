import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';

/// User-owned and account-owned API tokens.
class TokensPage extends ConsumerWidget {
  const TokensPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentAccountIdProvider);
    return DefaultTabController(
      length: accountId == null ? 1 : 2,
      child: PageScaffold(
        title: context.tr('API tokens', 'API Token'),
        bottom: TabBar(tabs: [
          Tab(text: context.tr('User tokens', '用户 Token')),
          if (accountId != null) Tab(text: context.tr('Account tokens', '账户 Token')),
        ]),
        body: TabBarView(children: [
          const _TokenList(base: '/user/tokens', account: false),
          if (accountId != null) _TokenList(base: '/accounts/$accountId/tokens', account: true),
        ]),
      ),
    );
  }
}

class _TokenList extends ConsumerWidget {
  const _TokenList({required this.base, required this.account});

  final String base;
  final bool account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'tokens:$base',
      load: (c) => c.list(base, perPage: 50),
      builder: (context, tokens, h) {
        final c = ref.read(clientProvider)!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      account
                          ? context.tr('Owned by the account; survive member changes.', '归属账户，不受成员变动影响。')
                          : context.tr('Owned by your user.', '归属当前用户。'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Create token', '创建 Token')),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => _CreateTokenDialog(base: base, account: account),
                      );
                      if (ok == true) await h.reload();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: tokens.isEmpty
                  ? EmptyView(icon: Icons.vpn_key_outlined, title: context.tr('No tokens visible', '没有可见的 Token'))
                  : ListView.separated(
                      itemCount: tokens.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final t = tokens[i];
                        final perms = <String>{
                          for (final p in ((t['policies'] as List?) ?? const []).cast<Map>())
                            for (final g in ((p['permission_groups'] as List?) ?? const []).cast<Map>()) '${g['name'] ?? g['id']}',
                        };
                        return ListTile(
                          leading: const Icon(Icons.vpn_key_outlined),
                          title: Text('${t['name']}'),
                          subtitle: Text(
                            [
                              if (perms.isNotEmpty) perms.take(4).join(', ') + (perms.length > 4 ? ' +${perms.length - 4}' : ''),
                              if (t['expires_on'] != null) '${context.tr('expires', '过期')} ${formatDate(t['expires_on'], withTime: false)}',
                              if (t['last_used_on'] != null) '${context.tr('used', '最近使用')} ${formatRelative(t['last_used_on'], zh: context.isZh)}',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusChip('${t['status']}', tone: StatusChip.toneFor(t['status'] as String?)),
                              PopupMenuButton<String>(
                                onSelected: (v) async {
                                  final id = t['id'];
                                  switch (v) {
                                    case 'roll':
                                      final ok = await confirm(
                                        context,
                                        title: context.tr('Roll token?', '轮换 Token？'),
                                        message: context.tr('The current value stops working immediately.', '当前值会立即失效。'),
                                        destructive: true,
                                      );
                                      if (!ok || !context.mounted) return;
                                      final r = await runAction(context, () => c.put('$base/$id/value', data: const {}));
                                      if (r is String && context.mounted) {
                                        await showSecretDialog(context, title: context.tr('New token value', '新的 Token 值'), values: {'token': r});
                                      }
                                    case 'toggle':
                                      final body = Map<String, dynamic>.from(t)
                                        ..removeWhere((k, _) => const {'id', 'issued_on', 'modified_on', 'last_used_on'}.contains(k))
                                        ..['status'] = t['status'] == 'active' ? 'disabled' : 'active';
                                      await runAction(context, () => c.put('$base/$id', data: body));
                                      await h.reload();
                                    case 'json':
                                      await showJsonDialog(context, t, title: '${t['name']}');
                                    case 'delete':
                                      final ok = await confirmDanger(context, title: context.tr('Delete token?', '删除 Token？'), message: '${t['name']}', typeToConfirm: t['name'] as String?);
                                      if (!ok || !context.mounted) return;
                                      await runAction(context, () => c.delete('$base/$id'), success: context.tr('Deleted', '已删除'));
                                      await h.reload();
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(value: 'roll', child: Text(context.tr('Roll value', '轮换值'))),
                                  PopupMenuItem(value: 'toggle', child: Text(t['status'] == 'active' ? context.tr('Disable', '停用') : context.tr('Enable', '启用'))),
                                  PopupMenuItem(value: 'json', child: Text(context.tr('Details', '详情'))),
                                  PopupMenuItem(value: 'delete', child: Text(context.tr('Delete', '删除'))),
                                ],
                              ),
                            ],
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

class _CreateTokenDialog extends ConsumerStatefulWidget {
  const _CreateTokenDialog({required this.base, required this.account});

  final String base;
  final bool account;

  @override
  ConsumerState<_CreateTokenDialog> createState() => _CreateTokenDialogState();
}

class _CreateTokenDialogState extends ConsumerState<_CreateTokenDialog> {
  final _name = TextEditingController(text: 'Cirrus token');
  final _ips = TextEditingController();
  final _search = TextEditingController();
  final Set<String> _selected = {};
  String _zoneScope = 'all';
  int? _ttlDays;

  @override
  void dispose() {
    _name.dispose();
    _ips.dispose();
    _search.dispose();
    super.dispose();
  }

  String _scopeOf(Map g) {
    final scopes = ((g['scopes'] as List?) ?? const []).cast<String>();
    if (scopes.any((s) => s.endsWith('.zone'))) return 'zone';
    if (scopes.any((s) => s.endsWith('.user'))) return 'user';
    return 'account';
  }

  Future<Map<String, dynamic>?> _create(CfClient c, List<Map<String, dynamic>> groups) async {
    final accountId = ref.read(currentAccountIdProvider);
    final zoneId = ref.read(currentZoneIdProvider);
    final byScope = <String, List<Map<String, dynamic>>>{};
    for (final g in groups.where((g) => _selected.contains(g['id']))) {
      (byScope[_scopeOf(g)] ??= []).add({'id': g['id']});
    }
    final policies = <Map<String, dynamic>>[];
    if (byScope['account'] != null && accountId != null) {
      policies.add({
        'effect': 'allow',
        'resources': {'com.cloudflare.api.account.$accountId': '*'},
        'permission_groups': byScope['account'],
      });
    }
    if (byScope['zone'] != null && accountId != null) {
      policies.add({
        'effect': 'allow',
        'resources': _zoneScope == 'current' && zoneId != null
            ? {'com.cloudflare.api.account.zone.$zoneId': '*'}
            : {
                'com.cloudflare.api.account.$accountId': {'com.cloudflare.api.account.zone.*': '*'},
              },
        'permission_groups': byScope['zone'],
      });
    }
    if (byScope['user'] != null) {
      final user = await c.get('/user').catchError((_) => null);
      final uid = (user as Map?)?['id'];
      if (uid != null) {
        policies.add({
          'effect': 'allow',
          'resources': {'com.cloudflare.api.user.$uid': '*'},
          'permission_groups': byScope['user'],
        });
      }
    }
    final ips = _ips.text.split(RegExp(r'[\s,]+')).where((e) => e.isNotEmpty).toList();
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'policies': policies,
      if (ips.isNotEmpty)
        'condition': {
          'request_ip': {'in': ips},
        },
      if (_ttlDays != null) 'expires_on': '${DateTime.now().toUtc().add(Duration(days: _ttlDays!)).toIso8601String().split('.').first}Z',
    };
    final r = await c.post(widget.base, data: body);
    return r is Map ? Map<String, dynamic>.from(r) : null;
  }

  @override
  Widget build(BuildContext context) {
    final permsPath = '${widget.base}/permission_groups';
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: ApiQuery<List<Map<String, dynamic>>>(
          cacheKey: 'perm-groups:$permsPath',
          load: (c) => c.list(permsPath, paginate: false),
          builder: (context, groups, _) {
            final q = _search.text.trim().toLowerCase();
            final filtered = groups.where((g) => q.isEmpty || '${g['name']}'.toLowerCase().contains(q)).toList()
              ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
            final byScope = <String, List<Map<String, dynamic>>>{};
            for (final g in filtered) {
              (byScope[_scopeOf(g)] ??= []).add(g);
            }
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(context.tr('Create API token', '创建 API Token'), style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextField(controller: _name, decoration: InputDecoration(labelText: context.tr('Token name', 'Token 名称'), border: const OutlineInputBorder())),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _zoneScope,
                          decoration: InputDecoration(labelText: context.tr('Zone resources', '域名资源'), border: const OutlineInputBorder()),
                          items: [
                            DropdownMenuItem(value: 'all', child: Text(context.tr('All zones in this account', '该账户下所有域名'))),
                            DropdownMenuItem(value: 'current', child: Text(context.tr('Current zone only', '仅当前域名'))),
                          ],
                          onChanged: (v) => setState(() => _zoneScope = v ?? 'all'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _ttlDays,
                          decoration: InputDecoration(labelText: context.tr('Expires', '有效期'), border: const OutlineInputBorder()),
                          items: [
                            DropdownMenuItem(value: null, child: Text(context.tr('Never', '永不过期'))),
                            const DropdownMenuItem(value: 1, child: Text('1 day')),
                            const DropdownMenuItem(value: 7, child: Text('7 days')),
                            const DropdownMenuItem(value: 30, child: Text('30 days')),
                            const DropdownMenuItem(value: 90, child: Text('90 days')),
                            const DropdownMenuItem(value: 365, child: Text('1 year')),
                          ],
                          onChanged: (v) => setState(() => _ttlDays = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ips,
                    decoration: InputDecoration(
                      labelText: context.tr('Client IP filter (optional)', '客户端 IP 限制（可选）'),
                      hintText: '203.0.113.0/24, 2001:db8::/32',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(context.tr('Permissions (${_selected.length})', '权限（${_selected.length}）'), style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(width: 12),
                      Expanded(child: SearchField(controller: _search, onChanged: (_) => setState(() {}))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final scope in const ['account', 'zone', 'user'])
                          if (byScope[scope]?.isNotEmpty ?? false) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 4),
                              child: Text(
                                switch (scope) {
                                  'account' => context.tr('Account', '账户'),
                                  'zone' => context.tr('Zone', '域名'),
                                  _ => context.tr('User', '用户'),
                                },
                                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            for (final g in byScope[scope]!)
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                value: _selected.contains(g['id']),
                                title: Text('${g['name']}'),
                                onChanged: (v) => setState(() => v == true ? _selected.add(g['id'] as String) : _selected.remove(g['id'])),
                              ),
                          ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.tr('Cancel', '取消'))),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () async {
                                final c = ref.read(clientProvider)!;
                                final r = await runAction(context, () => _create(c, groups));
                                if (r == null || !context.mounted) return;
                                await showSecretDialog(
                                  context,
                                  title: context.tr('Token created', 'Token 已创建'),
                                  values: {'token': '${r['value'] ?? ''}', 'id': '${r['id'] ?? ''}'},
                                );
                                if (context.mounted) Navigator.pop(context, true);
                              },
                        child: Text(context.tr('Create', '创建')),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

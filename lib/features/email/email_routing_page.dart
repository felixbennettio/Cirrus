import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';

class EmailRoutingPage extends StatelessWidget {
  const EmailRoutingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: PageScaffold(
        title: context.tr('Email Routing', '邮件路由'),
        bottom: TabBar(
          tabs: [
            Tab(text: context.tr('Routing rules', '路由规则')),
            Tab(text: context.tr('Destination addresses', '目标地址')),
            Tab(text: context.tr('Settings', '设置')),
          ],
        ),
        body: const TabBarView(children: [_Rules(), _Destinations(), _Settings()]),
      ),
    );
  }
}

String _describeActions(List? actions) {
  if (actions == null || actions.isEmpty) return '—';
  return actions.map((a) {
    final m = a as Map;
    final v = (m['value'] as List?)?.join(', ') ?? '';
    return switch (m['type']) {
      'forward' => '→ $v',
      'worker' => '⚡ Worker: $v',
      'drop' => '✗ drop',
      _ => '${m['type']} $v',
    };
  }).join('; ');
}

String _describeMatchers(List? matchers) {
  if (matchers == null || matchers.isEmpty) return '—';
  return matchers.map((m) {
    final mm = m as Map;
    return mm['type'] == 'all' ? '*' : '${mm['value']}';
  }).join(', ');
}

class _Rules extends ConsumerWidget {
  const _Rules();

  Future<void> _edit(BuildContext context, WidgetRef ref, String zoneId, String zoneName, QueryHandle h, [Map<String, dynamic>? rule]) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RuleDialog(zoneName: zoneName, rule: rule),
    );
    if (body == null || !context.mounted) return;
    final client = ref.read(clientProvider)!;
    final base = '/zones/$zoneId/email/routing/rules';
    final r = await runAction(
      context,
      () => rule == null ? client.send('POST', base, data: body) : client.send('PUT', '$base/${rule['id'] ?? rule['tag']}', data: body),
      success: context.tr('Saved', '已保存'),
    );
    if (r != null) await h.reload();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, zone) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'email-rules:$zoneId',
        load: (c) => c.list('/zones/$zoneId/email/routing/rules', perPage: 50),
        builder: (context, rules, h) {
          final client = ref.read(clientProvider)!;
          final custom = rules.where((r) => !((r['matchers'] as List?) ?? const []).any((m) => (m as Map)['type'] == 'all')).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(context.tr('${custom.length} custom addresses', '${custom.length} 个自定义地址'))),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.add),
                      label: Text(context.tr('Create address', '创建地址')),
                      onPressed: () => _edit(context, ref, zoneId, zone['name'] as String, h),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: custom.isEmpty
                    ? EmptyView(icon: Icons.alternate_email, title: context.tr('No routing rules', '没有路由规则'))
                    : ListView.separated(
                        itemCount: custom.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = custom[i];
                          final id = r['id'] ?? r['tag'];
                          return ListTile(
                            leading: const Icon(Icons.alternate_email),
                            title: Text(_describeMatchers(r['matchers'] as List?)),
                            subtitle: Text('${_describeActions(r['actions'] as List?)}${(r['name'] as String?)?.isNotEmpty == true ? ' · ${r['name']}' : ''}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: r['enabled'] != false,
                                  onChanged: (v) async {
                                    await runAction(
                                      context,
                                      () => client.put('/zones/$zoneId/email/routing/rules/$id', data: {...r, 'enabled': v}..remove('id')..remove('tag')),
                                      blocking: false,
                                    );
                                    await h.reload();
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await confirmDanger(
                                      context,
                                      title: context.tr('Delete rule?', '删除规则？'),
                                      message: _describeMatchers(r['matchers'] as List?),
                                    );
                                    if (!ok || !context.mounted) return;
                                    await runAction(context, () => client.delete('/zones/$zoneId/email/routing/rules/$id'));
                                    await h.reload();
                                  },
                                ),
                              ],
                            ),
                            onTap: () => _edit(context, ref, zoneId, zone['name'] as String, h, r),
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

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.zoneName, this.rule, this.catchAll = false});

  final String zoneName;
  final Map<String, dynamic>? rule;
  final bool catchAll;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _local = TextEditingController(
    text: () {
      final v = ((widget.rule?['matchers'] as List?)?.firstOrNull as Map?)?['value'] as String?;
      return v?.split('@').first ?? '';
    }(),
  );
  late String _type = (((widget.rule?['actions'] as List?)?.firstOrNull as Map?)?['type'] as String?) ?? 'forward';
  late final _value = TextEditingController(
    text: ((((widget.rule?['actions'] as List?)?.firstOrNull as Map?)?['value'] as List?) ?? const []).join(', '),
  );
  late final _name = TextEditingController(text: widget.rule?['name'] as String?);

  @override
  void dispose() {
    _local.dispose();
    _value.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.catchAll ? context.tr('Catch-all address', '全部捕获地址') : context.tr('Custom address', '自定义地址')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.catchAll)
              TextField(
                controller: _local,
                decoration: InputDecoration(
                  labelText: context.tr('Custom address', '自定义地址'),
                  suffixText: '@${widget.zoneName}',
                  border: const OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: InputDecoration(labelText: context.tr('Action', '动作'), border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: 'forward', child: Text(context.tr('Send to an email', '转发到邮箱'))),
                DropdownMenuItem(value: 'worker', child: Text(context.tr('Send to a Worker', '交给 Worker 处理'))),
                DropdownMenuItem(value: 'drop', child: Text(context.tr('Drop', '丢弃'))),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'forward'),
            ),
            if (_type != 'drop') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _value,
                decoration: InputDecoration(
                  labelText: _type == 'forward' ? context.tr('Destination email(s)', '目标邮箱') : context.tr('Worker name', 'Worker 名称'),
                  helperText: _type == 'forward' ? context.tr('Must be a verified destination address', '必须是已验证的目标地址') : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: context.tr('Name (optional)', '名称（可选）'), border: const OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(
          onPressed: () {
            final values = _value.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            Navigator.pop(context, {
              'name': _name.text.trim(),
              'enabled': widget.rule?['enabled'] ?? true,
              'matchers': widget.catchAll
                  ? [
                      {'type': 'all'},
                    ]
                  : [
                      {'type': 'literal', 'field': 'to', 'value': '${_local.text.trim()}@${widget.zoneName}'},
                    ],
              'actions': [
                {'type': _type, if (_type != 'drop') 'value': values},
              ],
            });
          },
          child: Text(context.tr('Save', '保存')),
        ),
      ],
    );
  }
}

class _Destinations extends ConsumerWidget {
  const _Destinations();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'email-dest:$accountId',
        load: (c) => c.list('/accounts/$accountId/email/routing/addresses', perPage: 50),
        builder: (context, list, h) {
          final client = ref.read(clientProvider)!;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(context.tr('Addresses must be verified before use.', '目标地址需验证后才能使用。'))),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.add),
                      label: Text(context.tr('Add', '添加')),
                      onPressed: () async {
                        final email = await promptText(context, title: context.tr('Destination address', '目标地址'), hint: 'me@example.com');
                        if (email == null || email.trim().isEmpty || !context.mounted) return;
                        final r = await runAction(
                          context,
                          () => client.send('POST', '/accounts/$accountId/email/routing/addresses', data: {'email': email.trim()}),
                          success: context.tr('Verification email sent', '验证邮件已发送'),
                        );
                        if (r != null) await h.reload();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final a in list)
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text('${a['email']}'),
                        subtitle: Text(a['verified'] != null ? '${context.tr('Verified', '已验证')} ${formatDate(a['verified'])}' : context.tr('Pending verification', '等待验证')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusChip(a['verified'] != null ? 'verified' : 'pending', tone: a['verified'] != null ? Tone.good : Tone.warn),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final ok = await confirmDanger(context, title: context.tr('Remove address?', '移除地址？'), message: '${a['email']}');
                                if (!ok || !context.mounted) return;
                                await runAction(context, () => client.delete('/accounts/$accountId/email/routing/addresses/${a['id'] ?? a['tag']}'));
                                await h.reload();
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmailSettings {
  _EmailSettings(this.settings, this.dns, this.catchAll);

  final Map<String, dynamic> settings;
  final List<dynamic> dns;
  final Map<String, dynamic>? catchAll;
}

class _Settings extends ConsumerWidget {
  const _Settings();

  Future<_EmailSettings> _load(CfClient c, String zoneId) async {
    final s = await c.get('/zones/$zoneId/email/routing');
    List<dynamic> dns = const [];
    Map<String, dynamic>? catchAll;
    try {
      final d = await c.get('/zones/$zoneId/email/routing/dns');
      dns = d is List ? d : (d is Map ? (d['records'] as List? ?? [d]) : const []);
    } catch (_) {}
    try {
      catchAll = Map<String, dynamic>.from(await c.get('/zones/$zoneId/email/routing/rules/catch_all') as Map);
    } catch (_) {}
    return _EmailSettings(Map<String, dynamic>.from(s as Map), dns, catchAll);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, zone) => ApiQuery<_EmailSettings>(
        cacheKey: 'email-settings:$zoneId',
        load: (c) => _load(c, zoneId),
        builder: (context, s, h) {
          final client = ref.read(clientProvider)!;
          final enabled = s.settings['enabled'] == true;
          return ContentList(
            onRefresh: h.reload,
            children: [
              SectionCard(
                title: context.tr('Status', '状态'),
                trailing: StatusChip('${s.settings['status'] ?? (enabled ? 'enabled' : 'disabled')}', tone: enabled ? Tone.good : Tone.warn),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('Email Routing enabled', '启用邮件路由')),
                    subtitle: Text(context.tr('Adds the required MX and TXT records.', '会自动添加所需的 MX 和 TXT 记录。')),
                    value: enabled,
                    onChanged: (v) async {
                      await runAction(context, () => client.post('/zones/$zoneId/email/routing/${v ? 'enable' : 'disable'}', data: const {}));
                      await h.reload();
                    },
                  ),
                ],
              ),
              SectionCard(
                title: context.tr('Catch-all address', '全部捕获地址'),
                trailing: TextButton(
                  onPressed: () async {
                    final body = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => _RuleDialog(zoneName: zone['name'] as String, rule: s.catchAll, catchAll: true),
                    );
                    if (body == null || !context.mounted) return;
                    await runAction(context, () => client.put('/zones/$zoneId/email/routing/rules/catch_all', data: body), success: context.tr('Saved', '已保存'));
                    await h.reload();
                  },
                  child: Text(context.tr('Edit', '编辑')),
                ),
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_describeActions(s.catchAll?['actions'] as List?)),
                    trailing: Switch(
                      value: s.catchAll?['enabled'] == true,
                      onChanged: s.catchAll == null
                          ? null
                          : (v) async {
                              await runAction(
                                context,
                                () => client.put('/zones/$zoneId/email/routing/rules/catch_all', data: {
                                  'enabled': v,
                                  'matchers': s.catchAll!['matchers'],
                                  'actions': s.catchAll!['actions'],
                                }),
                              );
                              await h.reload();
                            },
                    ),
                  ),
                ],
              ),
              SectionCard(
                title: context.tr('Required DNS records', '所需 DNS 记录'),
                children: [
                  for (final r in s.dns.whereType<Map>())
                    InfoRow('${r['type']} ${r['name'] ?? ''}', '${r['priority'] != null ? '${r['priority']} ' : ''}${r['content']}', mono: true, copy: true),
                  if (s.dns.isEmpty) Text(context.tr('No records reported', '无记录')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

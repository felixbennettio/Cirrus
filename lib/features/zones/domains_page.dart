import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/settings/app_settings.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';

class DomainsPage extends ConsumerStatefulWidget {
  const DomainsPage({super.key, this.openAdd = false});

  final bool openAdd;

  @override
  ConsumerState<DomainsPage> createState() => _DomainsPageState();
}

class _DomainsPageState extends ConsumerState<DomainsPage> {
  String _q = '';
  String _status = 'all';

  @override
  void initState() {
    super.initState();
    if (widget.openAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => addZone(context, ref));
    }
  }

  @override
  Widget build(BuildContext context) {
    final zones = ref.watch(zonesProvider);
    return PageScaffold(
      title: context.tr('Domains', '域名'),
      actions: [
        IconButton(
          tooltip: context.tr('Refresh', '刷新'),
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.read(zonesProvider.notifier).refresh(),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => addZone(context, ref),
        icon: const Icon(Icons.add),
        label: Text(context.tr('Add domain', '添加域名')),
      ),
      body: AccountRequired(
        builder: (context, accountId) => zones.when(
          data: (list) {
            final q = _q.toLowerCase();
            final filtered = list.where((z) {
              if (q.isNotEmpty && !(z['name'] as String).toLowerCase().contains(q)) return false;
              if (_status == 'paused') return z['paused'] == true;
              if (_status != 'all') return z['status'] == _status;
              return true;
            }).toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(
                    children: [
                      Expanded(child: SearchField(onChanged: (v) => setState(() => _q = v.trim()))),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _status,
                        underline: const SizedBox(),
                        items: [
                          DropdownMenuItem(value: 'all', child: Text(context.tr('All', '全部'))),
                          DropdownMenuItem(value: 'active', child: Text(context.tr('Active', '已激活'))),
                          DropdownMenuItem(value: 'pending', child: Text(context.tr('Pending', '待激活'))),
                          DropdownMenuItem(value: 'paused', child: Text(context.tr('Paused', '已暂停'))),
                          DropdownMenuItem(value: 'moved', child: Text(context.tr('Moved', '已迁出'))),
                        ],
                        onChanged: (v) => setState(() => _status = v ?? 'all'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => ref.read(zonesProvider.notifier).refresh(),
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, i) => _ZoneTile(zone: filtered[i]),
                    ),
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.read(zonesProvider.notifier).refresh()),
        ),
      ),
    );
  }
}

class _ZoneTile extends ConsumerWidget {
  const _ZoneTile({required this.zone});

  final Map<String, dynamic> zone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = zone['id'] as String;
    final name = zone['name'] as String;
    final paused = zone['paused'] == true;
    final status = zone['status'] as String? ?? '';
    return ListTile(
      leading: const Icon(Icons.public),
      title: Text(name),
      subtitle: Text(
        [
          (zone['plan'] as Map?)?['name'],
          zone['type'],
          if (zone['created_on'] != null) formatDate(zone['created_on'], withTime: false),
        ].whereType<String>().join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusChip(paused ? 'paused' : status, tone: paused ? Tone.warn : StatusChip.toneFor(status)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              final client = ref.read(clientProvider)!;
              switch (v) {
                case 'pause':
                  await runAction(
                    context,
                    () => client.patch('/zones/$id', data: {'paused': !paused}),
                    success: paused ? context.tr('Resumed', '已恢复') : context.tr('Paused', '已暂停'),
                  );
                  await ref.read(zonesProvider.notifier).refresh();
                case 'check':
                  await runAction(
                    context,
                    () => client.put('/zones/$id/activation_check'),
                    success: context.tr('Activation check requested', '已请求重新检查激活状态'),
                  );
                case 'copy':
                  await copyText(context, id);
                case 'delete':
                  final ok = await confirmDanger(
                    context,
                    title: context.tr('Delete domain?', '删除域名？'),
                    message: context.tr(
                      'This removes $name and all of its DNS records and settings from Cloudflare.',
                      '这会从 Cloudflare 删除 $name 及其所有 DNS 记录和设置。',
                    ),
                    typeToConfirm: name,
                  );
                  if (!ok || !context.mounted) return;
                  await runAction(context, () => client.delete('/zones/$id'), success: context.tr('Deleted', '已删除'));
                  await ref.read(zonesProvider.notifier).refresh();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'pause',
                child: Text(paused ? context.tr('Resume Cloudflare', '恢复 Cloudflare') : context.tr('Pause Cloudflare', '暂停 Cloudflare')),
              ),
              if (status == 'pending')
                PopupMenuItem(value: 'check', child: Text(context.tr('Re-check nameservers', '重新检查名称服务器'))),
              PopupMenuItem(value: 'copy', child: Text(context.tr('Copy zone ID', '复制 Zone ID'))),
              PopupMenuItem(
                value: 'delete',
                child: Text(context.tr('Delete', '删除'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ],
          ),
        ],
      ),
      onTap: () {
        ref.read(settingsProvider.notifier).setActiveZone(ref.read(currentAccountIdProvider) ?? '-', id);
        context.go('/zone');
      },
    );
  }
}

Future<void> addZone(BuildContext context, WidgetRef ref) async {
  final accountId = ref.read(currentAccountIdProvider);
  if (accountId == null) return;
  final name = TextEditingController();
  var type = 'full';
  var jumpStart = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(ctx.tr('Add a domain', '添加域名')),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: ctx.tr('Domain', '域名'),
                  hintText: 'example.com',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: InputDecoration(labelText: ctx.tr('Setup', '接入方式'), border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem(value: 'full', child: Text(ctx.tr('Full (change nameservers)', '完全接入（修改 NS）'))),
                  DropdownMenuItem(value: 'partial', child: Text(ctx.tr('Partial (CNAME setup)', '部分接入（CNAME）'))),
                  DropdownMenuItem(value: 'secondary', child: Text(ctx.tr('Secondary DNS', '辅助 DNS'))),
                ],
                onChanged: (v) => setState(() => type = v ?? 'full'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: jumpStart,
                onChanged: (v) => setState(() => jumpStart = v ?? true),
                title: Text(ctx.tr('Scan existing DNS records', '扫描现有 DNS 记录')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('Cancel', '取消'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('Add', '添加'))),
        ],
      ),
    ),
  );
  final domain = name.text.trim().toLowerCase();
  name.dispose();
  if (ok != true || domain.isEmpty || !context.mounted) return;
  final client = ref.read(clientProvider)!;
  final res = await runAction(
    context,
    () => client.send('POST', '/zones', data: {
      'name': domain,
      'account': {'id': accountId},
      'type': type,
      'jump_start': jumpStart,
    }),
    success: context.tr('Domain added', '域名已添加'),
  );
  if (res == null || !context.mounted) return;
  await ref.read(zonesProvider.notifier).refresh();
  final zone = res.result as Map? ?? const {};
  final ns = (zone['name_servers'] as List?)?.cast<String>() ?? const [];
  if (ns.isNotEmpty && context.mounted) {
    await showSecretDialog(
      context,
      title: context.tr('Update your nameservers', '请修改名称服务器'),
      note: context.tr(
        'At your registrar, replace the nameservers of $domain with:',
        '请在域名注册商处将 $domain 的名称服务器改为：',
      ),
      values: {for (var i = 0; i < ns.length; i++) 'NS ${i + 1}': ns[i]},
    );
  }
  if (zone['id'] is String && context.mounted) {
    ref.read(settingsProvider.notifier).setActiveZone(accountId, zone['id'] as String);
  }
}

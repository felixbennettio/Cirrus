import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';

String _tunnels(String accountId) => '/accounts/$accountId/cfd_tunnel';

class TunnelsPage extends ConsumerWidget {
  const TunnelsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: context.tr('Tunnels', '隧道'),
      builder: (context, accountId) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'tunnels:$accountId',
        frame: (w) => PageScaffold(title: context.tr('Tunnels', '隧道'), body: w),
        load: (c) => c.list(_tunnels(accountId), query: {'is_deleted': false}, perPage: 100),
        builder: (context, tunnels, h) {
          final c = ref.read(clientProvider)!;
          return PageScaffold(
            title: context.tr('Cloudflare Tunnels', 'Cloudflare 隧道'),
            actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload)],
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: Text(context.tr('Create tunnel', '创建隧道')),
              onPressed: () async {
                final name = await promptText(context, title: context.tr('Tunnel name', '隧道名称'), hint: 'home-lab');
                if (name == null || name.trim().isEmpty || !context.mounted) return;
                final r = await runAction(
                  context,
                  () => c.send('POST', _tunnels(accountId), data: {'name': name.trim(), 'config_src': 'cloudflare'}),
                  success: context.tr('Tunnel created', '隧道已创建'),
                );
                if (r == null || !context.mounted) return;
                await h.reload();
                final t = r.result as Map? ?? const {};
                var token = t['token'] as String?;
                if (token == null && t['id'] != null) {
                  token = await c
                      .get('${_tunnels(accountId)}/${t['id']}/token')
                      .then((v) => v as String?)
                      .catchError((_) => null);
                }
                if (token != null && context.mounted) await showInstallDialog(context, token);
                if (t['id'] != null && context.mounted) context.push('/zt/tunnels/${t['id']}');
              },
            ),
            body: tunnels.isEmpty
                ? EmptyView(
                    icon: Icons.settings_ethernet,
                    title: context.tr('No tunnels', '没有隧道'),
                    subtitle: context.tr('Expose local services securely without opening ports.', '无需开放端口即可安全地暴露内网服务。'),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96, top: 8),
                    itemCount: tunnels.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, i) {
                      final t = tunnels[i];
                      final conns = (t['connections'] as List?) ?? const [];
                      final colos = conns.map((e) => (e as Map)['colo_name']).toSet().join(', ');
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _statusColor(t['status'] as String?).withValues(alpha: 0.15),
                          child: Icon(Icons.settings_ethernet, color: _statusColor(t['status'] as String?)),
                        ),
                        title: Text('${t['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            t['config_src'] == 'cloudflare'
                                ? context.tr('Remotely managed', '远程管理')
                                : context.tr('Locally managed', '本地管理'),
                            if (conns.isNotEmpty) '${conns.length} ${context.tr('connections', '个连接')} ($colos)',
                            formatDate(t['created_at'], withTime: false),
                          ].join(' · '),
                        ),
                        trailing: StatusChip('${t['status']}', tone: StatusChip.toneFor(t['status'] as String?)),
                        onTap: () => context.push('/zt/tunnels/${t['id']}'),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

Color _statusColor(String? s) => switch (s) {
  'healthy' => Colors.green,
  'degraded' => Colors.orange,
  'down' => Colors.red,
  _ => Colors.grey,
};

Future<void> showInstallDialog(BuildContext context, String token) {
  final cmds = {
    context.tr('Install as a service', '安装为系统服务'): 'cloudflared service install $token',
    context.tr('Run in the foreground', '前台运行'): 'cloudflared tunnel run --token $token',
    'Docker':
        'docker run -d --restart unless-stopped cloudflare/cloudflared:latest tunnel --no-autoupdate run --token $token',
  };
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.tr('Install connector', '安装连接器')),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.tr('Run one of these on the machine that can reach your services:', '在能访问你的服务的机器上运行以下任一命令：')),
              const SizedBox(height: 12),
              for (final e in cmds.entries) ...[
                Text(e.key, style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(e.value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ),
                      IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () => copyText(ctx, e.value)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                ctx.tr('The token grants access to run this tunnel — keep it secret.', '该 Token 可运行此隧道，请妥善保管。'),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('Done', '完成')))],
    ),
  );
}

class TunnelDetailPage extends ConsumerWidget {
  const TunnelDetailPage({super.key, required this.tunnelId});

  final String tunnelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AccountRequired(
      pageTitle: context.tr('Tunnel', '隧道'),
      builder: (context, accountId) {
        final base = '${_tunnels(accountId)}/$tunnelId';
        return ApiQuery<Map<String, dynamic>>(
          cacheKey: 'tunnel:$base',
          frame: (w) => PageScaffold(title: context.tr('Tunnel', '隧道'), body: w),
          load: (c) async => Map<String, dynamic>.from(await c.get(base) as Map),
          builder: (context, t, h) {
            final c = ref.read(clientProvider)!;
            final remote = t['config_src'] == 'cloudflare';
            return DefaultTabController(
              length: 4,
              child: PageScaffold(
                title: '${t['name']}',
                subtitle: context.tr('Tunnel', '隧道'),
                actions: [
                  IconButton(
                    tooltip: context.tr('Install / run', '安装 / 运行'),
                    icon: const Icon(Icons.terminal),
                    onPressed: () async {
                      final token = await runAction(context, () => c.get('$base/token'));
                      if (token is String && context.mounted) await showInstallDialog(context, token);
                    },
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'rename') {
                        final n = await promptText(
                          context,
                          title: context.tr('Rename tunnel', '重命名隧道'),
                          initial: t['name'] as String?,
                        );
                        if (n == null || n.trim().isEmpty || !context.mounted) return;
                        await runAction(context, () => c.patch(base, data: {'name': n.trim()}));
                        await h.reload();
                      } else if (v == 'cleanup') {
                        await runAction(
                          context,
                          () => c.delete('$base/connections'),
                          success: context.tr('Stale connections removed', '已清理失效连接'),
                        );
                        await h.reload();
                      } else if (v == 'delete') {
                        final ok = await confirmDanger(
                          context,
                          title: context.tr('Delete tunnel?', '删除隧道？'),
                          message: context.tr(
                            'Connectors will be disconnected and the tunnel removed.',
                            '连接器将断开，隧道将被删除。',
                          ),
                          typeToConfirm: t['name'] as String?,
                        );
                        if (!ok || !context.mounted) return;
                        final r = await runAction(context, () async {
                          try {
                            await c.delete('$base/connections');
                          } catch (_) {}
                          return c.send('DELETE', base);
                        }, success: context.tr('Deleted', '已删除'));
                        if (r != null && context.mounted) context.go('/zt/tunnels');
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 'rename', child: Text(context.tr('Rename', '重命名'))),
                      PopupMenuItem(value: 'cleanup', child: Text(context.tr('Clean up stale connections', '清理失效连接'))),
                      PopupMenuItem(value: 'delete', child: Text(context.tr('Delete tunnel', '删除隧道'))),
                    ],
                  ),
                ],
                bottom: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: context.tr('Overview', '概览')),
                    Tab(text: context.tr('Public hostnames', '公共主机名')),
                    Tab(text: context.tr('Private networks', '私有网络')),
                    const Tab(text: 'JSON'),
                  ],
                ),
                body: TabBarView(
                  children: [
                    _Overview(tunnel: t, onReload: h.reload),
                    remote
                        ? _IngressEditor(base: base, tunnelId: tunnelId)
                        : EmptyView(
                            icon: Icons.computer,
                            title: context.tr('Locally managed tunnel', '本地管理的隧道'),
                            subtitle: context.tr(
                              'Its ingress rules live in config.yml on the connector host.',
                              '其 ingress 规则保存在连接器主机的 config.yml 中。',
                            ),
                          ),
                    _PrivateRoutes(accountId: accountId, tunnelId: tunnelId),
                    JsonTreeView(t),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.tunnel, required this.onReload});

  final Map<String, dynamic> tunnel;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final t = tunnel;
    final conns = ((t['connections'] as List?) ?? const []).cast<Map>();
    return ContentList(
      onRefresh: onReload,
      children: [
        SectionCard(
          title: context.tr('Status', '状态'),
          trailing: StatusChip('${t['status']}', tone: StatusChip.toneFor(t['status'] as String?)),
          children: [
            InfoRow('Tunnel ID', '${t['id']}', copy: true, mono: true),
            InfoRow('CNAME', '${t['id']}.cfargotunnel.com', copy: true, mono: true),
            InfoRow(context.tr('Type', '类型'), '${t['tun_type'] ?? 'cfd_tunnel'}'),
            InfoRow(
              context.tr('Configuration', '配置方式'),
              t['config_src'] == 'cloudflare'
                  ? context.tr('Remote (dashboard/API)', '远程（面板/API）')
                  : context.tr('Local (config.yml)', '本地 (config.yml)'),
            ),
            InfoRow(context.tr('Created', '创建时间'), formatDate(t['created_at'])),
            if (t['conns_active_at'] != null)
              InfoRow(context.tr('Active since', '活跃自'), formatDate(t['conns_active_at'])),
          ],
        ),
        SectionCard(
          title: context.tr('Connections (${conns.length})', '连接（${conns.length}）'),
          children: [
            if (conns.isEmpty) Text(context.tr('No active connectors', '没有活跃的连接器')),
            for (final cn in conns)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cable),
                title: Text('${cn['colo_name'] ?? ''}  ${cn['origin_ip'] ?? ''}'),
                subtitle: Text(
                  [
                    if (cn['client_version'] != null) 'cloudflared ${cn['client_version']}',
                    if (cn['opened_at'] != null) formatRelative(cn['opened_at'], zh: context.isZh),
                    if (cn['is_pending_reconnect'] == true) 'pending reconnect',
                  ].join(' · '),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _IngressEditor extends ConsumerStatefulWidget {
  const _IngressEditor({required this.base, required this.tunnelId});

  final String base;
  final String tunnelId;

  @override
  ConsumerState<_IngressEditor> createState() => _IngressEditorState();
}

class _IngressEditorState extends ConsumerState<_IngressEditor> {
  CfClient get _c => ref.read(clientProvider)!;

  Future<Map<String, dynamic>> _load(CfClient c) async {
    final r = await c.get('${widget.base}/configurations');
    return Map<String, dynamic>.from((r as Map?) ?? const {});
  }

  List<Map<String, dynamic>> _ingress(Map<String, dynamic> cfg) =>
      (((cfg['config'] as Map?)?['ingress'] as List?) ?? const [])
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _save(Map<String, dynamic> cfg, List<Map<String, dynamic>> rules, QueryHandle h) async {
    // cloudflared requires a final catch-all rule.
    final withoutCatchAll = rules.where((r) => r['hostname'] != null || r['path'] != null).toList();
    final catchAll = rules.lastWhere(
      (r) => r['hostname'] == null && r['path'] == null,
      orElse: () => {'service': 'http_status:404'},
    );
    final config = Map<String, dynamic>.from(cfg['config'] as Map? ?? const {});
    config['ingress'] = [...withoutCatchAll, catchAll];
    final r = await runAction(
      context,
      () => _c.put('${widget.base}/configurations', data: {'config': config}),
      success: context.tr('Configuration saved', '配置已保存'),
    );
    if (r != null) await h.reload();
  }

  Future<void> _edit(Map<String, dynamic> cfg, QueryHandle h, [int? index]) async {
    final rules = _ingress(cfg);
    final existing = index == null ? null : rules[index];
    final result = await showDialog<(Map<String, dynamic>, bool)>(
      context: context,
      builder: (_) => _IngressRuleDialog(rule: existing),
    );
    if (result == null || !mounted) return;
    final (rule, createDns) = result;
    if (index == null) {
      final catchAllIdx = rules.indexWhere((r) => r['hostname'] == null && r['path'] == null);
      rules.insert(catchAllIdx < 0 ? rules.length : catchAllIdx, rule);
    } else {
      rules[index] = rule;
    }
    await _save(cfg, rules, h);
    if (createDns && rule['hostname'] is String && mounted) await _ensureDns(rule['hostname'] as String);
  }

  Future<void> _ensureDns(String hostname) async {
    final zones = ref.read(zonesProvider).value ?? const [];
    Map<String, dynamic>? zone;
    for (final z in zones) {
      final n = z['name'] as String;
      if ((hostname == n || hostname.endsWith('.$n')) && (zone == null || n.length > (zone['name'] as String).length)) {
        zone = z;
      }
    }
    if (zone == null) {
      showToast(
        context,
        context.tr(
          'No zone in this account matches $hostname; add the CNAME manually.',
          '账户中没有与 $hostname 匹配的域名，请手动添加 CNAME。',
        ),
        error: true,
      );
      return;
    }
    await runAction(
      context,
      () => _c.post(
        '/zones/${zone!['id']}/dns_records',
        data: {
          'type': 'CNAME',
          'name': hostname,
          'content': '${widget.tunnelId}.cfargotunnel.com',
          'proxied': true,
          'comment': 'Cloudflare Tunnel (Cirrus)',
        },
      ),
      success: context.tr('DNS record created', 'DNS 记录已创建'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ApiQuery<Map<String, dynamic>>(
      cacheKey: 'tunnel-config:${widget.base}',
      load: _load,
      builder: (context, cfg, h) {
        final rules = _ingress(cfg);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Rules are matched top to bottom.', '规则按从上到下的顺序匹配。'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  IconButton(
                    tooltip: context.tr('Edit raw config', '编辑原始配置'),
                    icon: const Icon(Icons.data_object),
                    onPressed: () async {
                      final text = await promptText(
                        context,
                        title: 'config',
                        initial: prettyJson(cfg['config'] ?? {}),
                        multiline: true,
                        monospace: true,
                        confirmLabel: context.tr('Save', '保存'),
                      );
                      if (text == null || !context.mounted) return;
                      try {
                        final parsed = jsonDecode(text);
                        await runAction(
                          context,
                          () => _c.put('${widget.base}/configurations', data: {'config': parsed}),
                          success: context.tr('Saved', '已保存'),
                        );
                        await h.reload();
                      } catch (e) {
                        if (context.mounted) showToast(context, e.toString(), error: true);
                      }
                    },
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Add hostname', '添加主机名')),
                    onPressed: () => _edit(cfg, h),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < rules.length; i++)
                    ListTile(
                      leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                      title: Text(
                        rules[i]['hostname'] == null && rules[i]['path'] == null
                            ? context.tr('Catch-all', '兜底规则')
                            : '${rules[i]['hostname'] ?? '*'}${rules[i]['path'] != null ? '  ${rules[i]['path']}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '→ ${rules[i]['service']}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      trailing: rules[i]['hostname'] == null && rules[i]['path'] == null
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(cfg, h, i)),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await confirm(
                                      context,
                                      title: context.tr(
                                        'Remove ${rules[i]['hostname']}?',
                                        '移除 ${rules[i]['hostname']}？',
                                      ),
                                      destructive: true,
                                    );
                                    if (!ok) return;
                                    final copy = [...rules]..removeAt(i);
                                    await _save(cfg, copy, h);
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
    );
  }
}

class _IngressRuleDialog extends ConsumerStatefulWidget {
  const _IngressRuleDialog({this.rule});

  final Map<String, dynamic>? rule;

  @override
  ConsumerState<_IngressRuleDialog> createState() => _IngressRuleDialogState();
}

class _IngressRuleDialogState extends ConsumerState<_IngressRuleDialog> {
  late final _host = TextEditingController(text: widget.rule?['hostname'] as String?);
  late final _path = TextEditingController(text: widget.rule?['path'] as String?);
  late String _scheme = _initialScheme();
  late final _target = TextEditingController(text: _initialTarget());
  late final _origin = TextEditingController(
    text: widget.rule?['originRequest'] == null ? '' : prettyJson(widget.rule!['originRequest']),
  );
  bool _createDns = true;
  String? _error;

  static const _schemes = ['http', 'https', 'tcp', 'ssh', 'rdp', 'smb', 'unix', 'http_status', 'hello_world'];

  String _initialScheme() {
    final s = widget.rule?['service'] as String? ?? 'http://localhost:8080';
    if (s.startsWith('http_status:')) return 'http_status';
    if (s == 'hello_world') return 'hello_world';
    final i = s.indexOf('://');
    return i > 0 ? s.substring(0, i) : 'http';
  }

  String _initialTarget() {
    final s = widget.rule?['service'] as String? ?? 'http://localhost:8080';
    if (s.startsWith('http_status:')) return s.substring(12);
    if (s == 'hello_world') return '';
    final i = s.indexOf('://');
    return i > 0 ? s.substring(i + 3) : s;
  }

  @override
  void dispose() {
    for (final c in [_host, _path, _target, _origin]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.rule == null ? context.tr('Public hostname', '公共主机名') : context.tr('Edit hostname', '编辑主机名')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _host,
                decoration: InputDecoration(
                  labelText: context.tr('Hostname', '主机名'),
                  hintText: 'app.example.com',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: context.tr('Path (regex, optional)', '路径（正则，可选）'),
                  hintText: '^/api/',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<String>(
                      initialValue: _scheme,
                      decoration: InputDecoration(
                        labelText: context.tr('Service', '服务'),
                        border: const OutlineInputBorder(),
                      ),
                      items: [for (final s in _schemes) DropdownMenuItem(value: s, child: Text(s))],
                      onChanged: (v) => setState(() => _scheme = v ?? 'http'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_scheme != 'hello_world')
                    Expanded(
                      child: TextField(
                        controller: _target,
                        decoration: InputDecoration(
                          labelText: _scheme == 'http_status' ? context.tr('Status code', '状态码') : 'URL',
                          hintText: _scheme == 'http_status' ? '404' : 'localhost:8080',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _origin,
                minLines: 2,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  labelText: 'originRequest (JSON)',
                  hintText: '{"noTLSVerify": true, "httpHostHeader": "internal.local"}',
                  border: const OutlineInputBorder(),
                ),
              ),
              if (widget.rule == null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _createDns,
                  onChanged: (v) => setState(() => _createDns = v ?? true),
                  title: Text(context.tr('Create the proxied CNAME DNS record', '创建已代理的 CNAME DNS 记录')),
                ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel', '取消'))),
        FilledButton(
          onPressed: () {
            final service = switch (_scheme) {
              'http_status' => 'http_status:${_target.text.trim()}',
              'hello_world' => 'hello_world',
              _ => '$_scheme://${_target.text.trim()}',
            };
            final rule = <String, dynamic>{
              if (_host.text.trim().isNotEmpty) 'hostname': _host.text.trim(),
              if (_path.text.trim().isNotEmpty) 'path': _path.text.trim(),
              'service': service,
            };
            if (_origin.text.trim().isNotEmpty) {
              try {
                rule['originRequest'] = jsonDecode(_origin.text);
              } catch (_) {
                setState(() => _error = context.tr('originRequest must be valid JSON', 'originRequest 必须是合法 JSON'));
                return;
              }
            }
            Navigator.pop(context, (rule, _createDns && widget.rule == null));
          },
          child: Text(context.tr('Save', '保存')),
        ),
      ],
    );
  }
}

class _PrivateRoutes extends ConsumerWidget {
  const _PrivateRoutes({required this.accountId, required this.tunnelId});

  final String accountId;
  final String tunnelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = '/accounts/$accountId/teamnet/routes';
    return ApiQuery<List<Map<String, dynamic>>>(
      cacheKey: 'tunnel-routes:$tunnelId',
      load: (c) => c.list(base, query: {'tunnel_id': tunnelId, 'is_deleted': false}),
      builder: (context, routes, h) {
        final c = ref.read(clientProvider)!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(
                        'CIDR routes reachable through this tunnel (WARP to Tunnel).',
                        '通过此隧道可访问的 CIDR 路由（WARP 到隧道）。',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.add),
                    label: Text(context.tr('Add route', '添加路由')),
                    onPressed: () async {
                      final cidr = await promptText(context, title: 'CIDR', hint: '10.0.0.0/24');
                      if (cidr == null || cidr.trim().isEmpty || !context.mounted) return;
                      await runAction(
                        context,
                        () => c.post(base, data: {'network': cidr.trim(), 'tunnel_id': tunnelId}),
                        success: context.tr('Route added', '路由已添加'),
                      );
                      await h.reload();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final r in routes)
                    ListTile(
                      leading: const Icon(Icons.route),
                      title: Text('${r['network']}', style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: Text(
                        '${r['comment'] ?? ''}${r['virtual_network_id'] != null ? ' · vnet ${r['virtual_network_id']}' : ''}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirm(
                            context,
                            title: context.tr('Delete route ${r['network']}?', '删除路由 ${r['network']}？'),
                            destructive: true,
                          );
                          if (!ok || !context.mounted) return;
                          await runAction(context, () => c.delete('$base/${r['id']}'));
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

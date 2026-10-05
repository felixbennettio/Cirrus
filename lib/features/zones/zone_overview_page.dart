import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/charts.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../analytics/analytics_api.dart';

class _ZoneState {
  _ZoneState(this.zone, this.devMode, this.securityLevel);

  final Map<String, dynamic> zone;
  final Map<String, dynamic>? devMode;
  final String? securityLevel;
}

Future<_ZoneState> _load(CfClient c, String zoneId) async {
  final results = await Future.wait([
    c.get('/zones/$zoneId'),
    c.get('/zones/$zoneId/settings/development_mode').catchError((_) => null),
    c.get('/zones/$zoneId/settings/security_level').catchError((_) => null),
  ]);
  return _ZoneState(
    Map<String, dynamic>.from(results[0] as Map),
    results[1] is Map ? Map<String, dynamic>.from(results[1] as Map) : null,
    (results[2] as Map?)?['value'] as String?,
  );
}

class ZoneOverviewPage extends ConsumerWidget {
  const ZoneOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(currentZoneProvider);
    return PageScaffold(
      title: zone?['name'] as String? ?? context.tr('Zone overview', '域名概览'),
      subtitle: context.tr('Zone overview', '域名概览'),
      body: ZoneRequired(
        builder: (context, zoneId, _) => ApiQuery<_ZoneState>(
          cacheKey: 'zone-overview:$zoneId',
          load: (c) => _load(c, zoneId),
          builder: (context, s, handle) => _Overview(state: s, onReload: handle.reload),
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview({required this.state, required this.onReload});

  final _ZoneState state;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = state.zone;
    final id = z['id'] as String;
    final ns = (z['name_servers'] as List?)?.cast<String>() ?? const [];
    final originalNs = (z['original_name_servers'] as List?)?.cast<String>() ?? const [];
    final paused = z['paused'] == true;
    final status = z['status'] as String? ?? '';
    final client = ref.read(clientProvider)!;
    final devOn = state.devMode?['value'] == 'on';
    final devRemaining = state.devMode?['time_remaining'];
    final underAttack = state.securityLevel == 'under_attack';

    return ContentList(
      onRefresh: onReload,
      children: [
        if (status == 'pending')
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('Waiting for nameserver change', '等待名称服务器生效'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr(
                      'Point the domain to the Cloudflare nameservers below at your registrar, then re-check.',
                      '请在域名注册商处把名称服务器改为下面的 Cloudflare 名称服务器，然后重新检查。',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => runAction(
                      context,
                      () => client.put('/zones/$id/activation_check'),
                      success: context.tr('Check requested', '已请求检查'),
                    ),
                    child: Text(context.tr('Re-check now', '立即重新检查')),
                  ),
                ],
              ),
            ),
          ),
        SectionCard(
          title: context.tr('Domain', '域名'),
          trailing: StatusChip(paused ? 'paused' : status, tone: paused ? Tone.warn : StatusChip.toneFor(status)),
          children: [
            InfoRow(context.tr('Plan', '套餐'), str((z['plan'] as Map?)?['name'])),
            InfoRow(context.tr('Setup', '接入方式'), str(z['type'])),
            InfoRow('Zone ID', id, copy: true, mono: true),
            InfoRow(context.tr('Account ID', '账户 ID'), str((z['account'] as Map?)?['id']), copy: true, mono: true),
            for (var i = 0; i < ns.length; i++)
              InfoRow('${context.tr('Nameserver', '名称服务器')} ${i + 1}', ns[i], copy: true, mono: true),
            if (originalNs.isNotEmpty) InfoRow(context.tr('Original nameservers', '原名称服务器'), originalNs.join(', ')),
            if (z['original_registrar'] != null) InfoRow(context.tr('Registrar', '注册商'), str(z['original_registrar'])),
            InfoRow(context.tr('Created', '创建时间'), formatDate(z['created_on'])),
            if (z['activated_on'] != null) InfoRow(context.tr('Activated', '激活时间'), formatDate(z['activated_on'])),
          ],
        ),
        SectionCard(
          title: context.tr('Quick actions', '快捷操作'),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.construction),
              title: Text(context.tr('Development mode', '开发模式')),
              subtitle: Text(
                devOn && devRemaining is num && devRemaining > 0
                    ? context.tr(
                        'Cache bypassed · ${(devRemaining / 60).ceil()} min left',
                        '已绕过缓存 · 剩余 ${(devRemaining / 60).ceil()} 分钟',
                      )
                    : context.tr('Temporarily bypass the cache for 3 hours', '临时绕过缓存 3 小时'),
              ),
              value: devOn,
              onChanged: (v) async {
                await runAction(
                  context,
                  () => client.patch('/zones/$id/settings/development_mode', data: {'value': v ? 'on' : 'off'}),
                );
                await onReload();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.shield_moon_outlined),
              title: Text(context.tr("I'm Under Attack mode", '“正在遭受攻击”模式')),
              subtitle: Text(context.tr('Challenge every visitor with a JS check', '对所有访客启用 JS 质询')),
              value: underAttack,
              onChanged: (v) async {
                await runAction(
                  context,
                  () => client.patch(
                    '/zones/$id/settings/security_level',
                    data: {'value': v ? 'under_attack' : 'medium'},
                  ),
                );
                await onReload();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.pause_circle_outline),
              title: Text(context.tr('Pause Cloudflare on site', '暂停 Cloudflare')),
              subtitle: Text(context.tr('DNS only — traffic goes directly to your origin', '仅 DNS——流量直接发往源站')),
              value: paused,
              onChanged: (v) async {
                if (v &&
                    !await confirm(
                      context,
                      title: context.tr('Pause Cloudflare?', '暂停 Cloudflare？'),
                      message: context.tr(
                        'Your origin IPs will be exposed and protections disabled.',
                        '源站 IP 将暴露，所有防护将失效。',
                      ),
                      destructive: true,
                    )) {
                  return;
                }
                if (!context.mounted) return;
                await runAction(context, () => client.patch('/zones/$id', data: {'paused': v}));
                await ref.read(zonesProvider.notifier).refresh();
                await onReload();
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(context.tr('Purge everything', '清除全部缓存')),
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: context.tr('Purge all cached files?', '清除全部缓存文件？'),
                      message: context.tr('This may temporarily increase load on your origin.', '这可能会暂时增加源站负载。'),
                      destructive: true,
                    );
                    if (!ok || !context.mounted) return;
                    await runAction(
                      context,
                      () => client.post('/zones/$id/purge_cache', data: {'purge_everything': true}),
                      success: context.tr('Cache purged', '缓存已清除'),
                    );
                  },
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/zone/dns'),
                  icon: const Icon(Icons.dns_outlined),
                  label: const Text('DNS'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/zone/ssl'),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('SSL/TLS'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/zone/analytics'),
                  icon: const Icon(Icons.bar_chart),
                  label: Text(context.tr('Analytics', '分析')),
                ),
              ],
            ),
          ],
        ),
        _MiniTraffic(zoneId: id),
      ],
    );
  }
}

class _MiniTraffic extends StatelessWidget {
  const _MiniTraffic({required this.zoneId});

  final String zoneId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: context.tr('Last 7 days', '最近 7 天'),
      children: [
        SizedBox(
          height: 330,
          child: ApiQuery<ZoneTraffic>(
            cacheKey: 'analytics:$zoneId:7d',
            load: (c) => fetchZoneTraffic(c, zoneId, days: 7),
            builder: (context, t, _) => Column(
              children: [
                ResponsiveGrid(
                  minItemWidth: 150,
                  spacing: 8,
                  children: [
                    StatTile(label: context.tr('Requests', '请求数'), value: formatCount(t.requests)),
                    StatTile(label: context.tr('Bandwidth', '带宽'), value: formatBytes(t.bytes)),
                    StatTile(label: context.tr('Cached', '缓存率'), value: '${(t.cacheRatio * 100).toStringAsFixed(1)}%'),
                    StatTile(label: context.tr('Threats', '威胁'), value: formatCount(t.threats)),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TimeSeriesChart(
                    height: 170,
                    labels: t.points.map((p) => p.label).toList(),
                    format: formatCount,
                    series: [
                      ChartSeries(
                        name: context.tr('Requests', '请求'),
                        values: t.points.map((p) => p.requests).toList(),
                        color: scheme.primary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

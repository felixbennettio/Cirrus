import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/session.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../zone_settings/zone_settings.dart';

class CachePage extends StatelessWidget {
  const CachePage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: context.tr('Caching', '缓存'),
      body: ZoneSettingsList(
        groups: const [SettingGroup.caching],
        header: [
          const _PurgeCard(),
          const _CacheFeatures(),
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.rule),
              title: Text(context.tr('Cache rules', '缓存规则')),
              subtitle: Text(context.tr('Customize cache eligibility, TTLs and keys', '自定义缓存资格、TTL 与缓存键')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/zone/rules?phase=http_request_cache_settings'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PurgeCard extends ConsumerStatefulWidget {
  const _PurgeCard();

  @override
  ConsumerState<_PurgeCard> createState() => _PurgeCardState();
}

class _PurgeCardState extends ConsumerState<_PurgeCard> {
  String _mode = 'files';
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _purge(String zoneId) async {
    final client = ref.read(clientProvider)!;
    Map<String, dynamic> body;
    if (_mode == 'everything') {
      final ok = await confirm(
        context,
        title: context.tr('Purge everything?', '清除全部缓存？'),
        message: context.tr('All cached content will be removed from every data center.', '所有数据中心的缓存内容都将被清除。'),
        destructive: true,
      );
      if (!ok) return;
      body = {'purge_everything': true};
    } else {
      final items = _input.text.split(RegExp(r'[\n,\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (items.isEmpty) {
        showToast(context, context.tr('Enter at least one value', '请至少输入一项'), error: true);
        return;
      }
      body = {_mode: items};
    }
    if (!mounted) return;
    final r = await runAction(
      context,
      () => client.send('POST', '/zones/$zoneId/purge_cache', data: body),
      success: context.tr('Purge requested', '已提交清除请求'),
    );
    if (r != null) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final zoneId = ref.watch(currentZoneIdProvider);
    final hint = switch (_mode) {
      'files' => 'https://example.com/style.css\nhttps://example.com/app.js',
      'hosts' => 'www.example.com\nimages.example.com',
      'tags' => 'product-123\nheader',
      'prefixes' => 'www.example.com/blog/\nexample.com/assets/',
      _ => '',
    };
    return SectionCard(
      title: context.tr('Purge cache', '清除缓存'),
      children: [
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'files', label: Text(context.tr('URLs', 'URL'))),
              ButtonSegment(value: 'hosts', label: Text(context.tr('Hostnames', '主机名'))),
              ButtonSegment(value: 'tags', label: Text(context.tr('Tags', '标签'))),
              ButtonSegment(value: 'prefixes', label: Text(context.tr('Prefixes', '前缀'))),
              ButtonSegment(value: 'everything', label: Text(context.tr('Everything', '全部'))),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ),
        const SizedBox(height: 12),
        if (_mode != 'everything')
          TextField(
            controller: _input,
            minLines: 3,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              helperText: context.tr('One per line (up to 30 per request on most plans)', '每行一个（多数套餐每次最多 30 个）'),
              border: const OutlineInputBorder(),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: zoneId == null ? null : () => _purge(zoneId),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(context.tr('Purge', '清除')),
          ),
        ),
      ],
    );
  }
}

class _CacheFeatures extends ConsumerWidget {
  const _CacheFeatures();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoneId = ref.watch(currentZoneIdProvider);
    if (zoneId == null) return const SizedBox();
    final features = [
      ('/zones/$zoneId/argo/tiered_caching', const L10nText('Tiered Cache', '分层缓存'), const L10nText('Use upper-tier data centers to reduce origin load', '使用上层数据中心减少回源')),
      ('/zones/$zoneId/cache/tiered_cache_smart_topology_enable', const L10nText('Smart Tiered Cache topology', '智能分层缓存拓扑'), const L10nText('Pick the best upper tier automatically', '自动选择最佳上层节点')),
      ('/zones/$zoneId/cache/cache_reserve', const L10nText('Cache Reserve', '缓存储备'), const L10nText('Persist cache in R2 (paid add-on)', '将缓存持久化到 R2（付费功能）')),
      ('/zones/$zoneId/cache/regional_tiered_cache', const L10nText('Regional Tiered Cache', '区域分层缓存'), const L10nText('Add a regional tier between lower and upper tiers', '在上下层之间增加区域层')),
      ('/zones/$zoneId/argo/smart_routing', const L10nText('Argo Smart Routing', 'Argo 智能路由'), const L10nText('Route around congestion (paid)', '绕开网络拥塞（付费）')),
    ];
    return SectionCard(
      title: context.tr('Cache features', '缓存功能'),
      children: [for (final f in features) _ToggleEndpoint(path: f.$1, title: f.$2, subtitle: f.$3)],
    );
  }
}

/// A setting exposed as its own endpoint returning `{value: on|off}`.
class _ToggleEndpoint extends ConsumerWidget {
  const _ToggleEndpoint({required this.path, required this.title, required this.subtitle});

  final String path;
  final L10nText title;
  final L10nText subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 64,
      child: ApiQuery<Object?>(
        cacheKey: 'toggle:$path',
        loading: ListTile(contentPadding: EdgeInsets.zero, title: Text(title.of(context)), trailing: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        load: (c) async {
          try {
            return await c.get(path);
          } catch (e) {
            return e;
          }
        },
        builder: (context, data, h) {
          final value = data is Map ? data['value'] : null;
          final available = data is Map && data['editable'] != false;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title.of(context)),
            subtitle: Text(available ? subtitle.of(context) : context.tr('Not available on this plan / token', '当前套餐或 Token 不可用'), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Switch(
              value: value == 'on' || value == true,
              onChanged: !available
                  ? null
                  : (v) async {
                      final client = ref.read(clientProvider)!;
                      final r = await runAction(context, () => client.send('PATCH', path, data: {'value': v ? 'on' : 'off'}), blocking: false);
                      if (r != null) h.setData(r.result);
                    },
            ),
          );
        },
      ),
    );
  }
}

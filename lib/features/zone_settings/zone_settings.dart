import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/cf_client.dart';
import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';

enum SettingGroup { ssl, speed, caching, network, security, scrape, other }

const settingGroupLabels = {
  SettingGroup.ssl: L10nText('SSL/TLS', 'SSL/TLS'),
  SettingGroup.speed: L10nText('Speed', '速度优化'),
  SettingGroup.caching: L10nText('Caching', '缓存'),
  SettingGroup.network: L10nText('Network', '网络'),
  SettingGroup.security: L10nText('Security', '安全'),
  SettingGroup.scrape: L10nText('Scrape Shield', '内容保护'),
  SettingGroup.other: L10nText('Other', '其他'),
};

class SettingMeta {
  const SettingMeta(this.group, this.label, {this.description, this.options, this.numberOptions});

  final SettingGroup group;
  final L10nText label;
  final L10nText? description;

  /// Allowed string values (for enums other than on/off).
  final List<String>? options;

  /// Suggested numeric values (seconds etc.).
  final List<int>? numberOptions;
}

const _ttlOptions = [0, 30, 60, 120, 300, 1200, 1800, 3600, 7200, 10800, 14400, 18000, 28800, 43200, 57600, 72000, 86400, 172800, 259200, 345600, 432000, 691200, 1382400, 2073600, 2678400, 5356800, 16070400, 31536000];

/// Known zone settings. Anything else returned by the API is still shown
/// under "Other" with a generic editor.
const settingsMeta = <String, SettingMeta>{
  // SSL/TLS
  'ssl': SettingMeta(SettingGroup.ssl, L10nText('Encryption mode', '加密模式'), options: ['off', 'flexible', 'full', 'strict'], description: L10nText('How Cloudflare connects to your origin.', 'Cloudflare 连接源站的方式。')),
  'always_use_https': SettingMeta(SettingGroup.ssl, L10nText('Always Use HTTPS', '始终使用 HTTPS'), description: L10nText('Redirect all HTTP requests to HTTPS.', '将所有 HTTP 请求重定向到 HTTPS。')),
  'min_tls_version': SettingMeta(SettingGroup.ssl, L10nText('Minimum TLS version', '最低 TLS 版本'), options: ['1.0', '1.1', '1.2', '1.3']),
  'tls_1_3': SettingMeta(SettingGroup.ssl, L10nText('TLS 1.3', 'TLS 1.3'), options: ['on', 'off', 'zrt']),
  'automatic_https_rewrites': SettingMeta(SettingGroup.ssl, L10nText('Automatic HTTPS Rewrites', '自动 HTTPS 重写')),
  'opportunistic_encryption': SettingMeta(SettingGroup.ssl, L10nText('Opportunistic Encryption', '机会性加密')),
  'tls_client_auth': SettingMeta(SettingGroup.ssl, L10nText('Authenticated Origin Pulls', '源站认证拉取')),
  'ssl_recommender': SettingMeta(SettingGroup.ssl, L10nText('SSL/TLS Recommender', 'SSL/TLS 推荐器')),
  'security_header': SettingMeta(SettingGroup.ssl, L10nText('HSTS', 'HSTS 严格传输安全')),
  'ciphers': SettingMeta(SettingGroup.ssl, L10nText('Cipher suites', '密码套件')),
  'ssl_automatic_mode': SettingMeta(SettingGroup.ssl, L10nText('Automatic SSL/TLS', '自动 SSL/TLS'), options: ['auto', 'custom']),
  // Speed
  'brotli': SettingMeta(SettingGroup.speed, L10nText('Brotli', 'Brotli 压缩')),
  'early_hints': SettingMeta(SettingGroup.speed, L10nText('Early Hints', 'Early Hints')),
  'rocket_loader': SettingMeta(SettingGroup.speed, L10nText('Rocket Loader', 'Rocket Loader')),
  'polish': SettingMeta(SettingGroup.speed, L10nText('Polish (image optimization)', 'Polish 图片优化'), options: ['off', 'lossless', 'lossy']),
  'webp': SettingMeta(SettingGroup.speed, L10nText('WebP', 'WebP 转换')),
  'mirage': SettingMeta(SettingGroup.speed, L10nText('Mirage', 'Mirage')),
  'image_resizing': SettingMeta(SettingGroup.speed, L10nText('Image Resizing', '图片缩放'), options: ['on', 'off', 'open']),
  'h2_prioritization': SettingMeta(SettingGroup.speed, L10nText('HTTP/2 prioritization', 'HTTP/2 优先级'), options: ['on', 'off', 'custom']),
  'prefetch_preload': SettingMeta(SettingGroup.speed, L10nText('Prefetch preload', '预取预加载')),
  'fonts': SettingMeta(SettingGroup.speed, L10nText('Cloudflare Fonts', 'Cloudflare 字体')),
  'speed_brain': SettingMeta(SettingGroup.speed, L10nText('Speed Brain', 'Speed Brain')),
  'automatic_platform_optimization': SettingMeta(SettingGroup.speed, L10nText('Automatic Platform Optimization', '平台自动优化 (APO)')),
  'minify': SettingMeta(SettingGroup.speed, L10nText('Auto Minify (legacy)', '自动压缩（旧版）')),
  'mobile_redirect': SettingMeta(SettingGroup.speed, L10nText('Mobile redirect (legacy)', '移动端重定向（旧版）')),
  // Caching
  'cache_level': SettingMeta(SettingGroup.caching, L10nText('Caching level', '缓存级别'), options: ['basic', 'simplified', 'aggressive']),
  'browser_cache_ttl': SettingMeta(SettingGroup.caching, L10nText('Browser cache TTL', '浏览器缓存 TTL'), numberOptions: _ttlOptions),
  'edge_cache_ttl': SettingMeta(SettingGroup.caching, L10nText('Edge cache TTL', '边缘缓存 TTL'), numberOptions: _ttlOptions),
  'development_mode': SettingMeta(SettingGroup.caching, L10nText('Development mode', '开发模式')),
  'always_online': SettingMeta(SettingGroup.caching, L10nText('Always Online', '始终在线')),
  'sort_query_string_for_cache': SettingMeta(SettingGroup.caching, L10nText('Sort query string', '查询字符串排序')),
  'origin_error_page_pass_thru': SettingMeta(SettingGroup.caching, L10nText('Origin error page pass-through', '透传源站错误页')),
  'crawler_hints': SettingMeta(SettingGroup.caching, L10nText('Crawler Hints', '爬虫提示')),
  // Network
  'http2': SettingMeta(SettingGroup.network, L10nText('HTTP/2', 'HTTP/2')),
  'http3': SettingMeta(SettingGroup.network, L10nText('HTTP/3 (QUIC)', 'HTTP/3 (QUIC)')),
  '0rtt': SettingMeta(SettingGroup.network, L10nText('0-RTT Connection Resumption', '0-RTT 连接恢复')),
  'ipv6': SettingMeta(SettingGroup.network, L10nText('IPv6 compatibility', 'IPv6 兼容')),
  'websockets': SettingMeta(SettingGroup.network, L10nText('WebSockets', 'WebSockets')),
  'grpc': SettingMeta(SettingGroup.network, L10nText('gRPC', 'gRPC')),
  'pseudo_ipv4': SettingMeta(SettingGroup.network, L10nText('Pseudo IPv4', '伪 IPv4'), options: ['off', 'add_header', 'overwrite_header']),
  'ip_geolocation': SettingMeta(SettingGroup.network, L10nText('IP geolocation header', 'IP 地理位置头')),
  'max_upload': SettingMeta(SettingGroup.network, L10nText('Maximum upload size (MB)', '最大上传大小（MB）'), numberOptions: [100, 125, 150, 175, 200, 225, 250, 275, 300, 325, 350, 375, 400, 425, 450, 475, 500]),
  'opportunistic_onion': SettingMeta(SettingGroup.network, L10nText('Onion routing', '洋葱路由')),
  'true_client_ip_header': SettingMeta(SettingGroup.network, L10nText('True-Client-IP header', 'True-Client-IP 头')),
  'orange_to_orange': SettingMeta(SettingGroup.network, L10nText('Orange-to-Orange (O2O)', '橙云到橙云 (O2O)')),
  'response_buffering': SettingMeta(SettingGroup.network, L10nText('Response buffering', '响应缓冲')),
  'proxy_read_timeout': SettingMeta(SettingGroup.network, L10nText('Proxy read timeout (s)', '代理读取超时（秒）')),
  'origin_max_http_version': SettingMeta(SettingGroup.network, L10nText('Max HTTP version to origin', '回源最高 HTTP 版本'), options: ['1', '2']),
  'nel': SettingMeta(SettingGroup.network, L10nText('Network Error Logging', '网络错误日志')),
  'visitor_ip': SettingMeta(SettingGroup.network, L10nText('Visitor IP', '访客 IP')),
  // Security
  'security_level': SettingMeta(SettingGroup.security, L10nText('Security level', '安全级别'), options: ['off', 'essentially_off', 'low', 'medium', 'high', 'under_attack']),
  'challenge_ttl': SettingMeta(SettingGroup.security, L10nText('Challenge passage', '质询通过有效期'), numberOptions: [300, 900, 1800, 2700, 3600, 7200, 10800, 14400, 28800, 57600, 86400, 604800, 2592000, 31536000]),
  'browser_check': SettingMeta(SettingGroup.security, L10nText('Browser integrity check', '浏览器完整性检查')),
  'privacy_pass': SettingMeta(SettingGroup.security, L10nText('Privacy Pass', 'Privacy Pass')),
  'waf': SettingMeta(SettingGroup.security, L10nText('WAF (legacy)', 'WAF（旧版）')),
  'replace_insecure_js': SettingMeta(SettingGroup.security, L10nText('Replace insecure JS libraries', '替换不安全的 JS 库')),
  'advanced_ddos': SettingMeta(SettingGroup.security, L10nText('Advanced DDoS', '高级 DDoS 防护')),
  'aegis': SettingMeta(SettingGroup.security, L10nText('Aegis (dedicated egress IPs)', 'Aegis 专用出口 IP')),
  // Scrape shield
  'email_obfuscation': SettingMeta(SettingGroup.scrape, L10nText('Email address obfuscation', '电子邮件地址混淆')),
  'server_side_exclude': SettingMeta(SettingGroup.scrape, L10nText('Server-side excludes', '服务端排除')),
  'hotlink_protection': SettingMeta(SettingGroup.scrape, L10nText('Hotlink protection', '防盗链')),
};

/// Loads all zone settings as a map id → setting object.
Future<Map<String, Map<String, dynamic>>> loadZoneSettings(CfClient c, String zoneId) async {
  final list = await c.get('/zones/$zoneId/settings') as List? ?? const [];
  return {
    for (final s in list.cast<Map>()) s['id'] as String: Map<String, dynamic>.from(s),
  };
}

String settingValueLabel(BuildContext context, String id, Object? v) {
  if (id.endsWith('_ttl') || id == 'browser_cache_ttl' || id == 'challenge_ttl') {
    if (v == 0) return id == 'browser_cache_ttl' ? context.tr('Respect existing headers', '遵循源站头') : '0';
    if (v is num) {
      final s = v.toInt();
      if (s % 86400 == 0) return context.tr('${s ~/ 86400} day(s)', '${s ~/ 86400} 天');
      if (s % 3600 == 0) return context.tr('${s ~/ 3600} hour(s)', '${s ~/ 3600} 小时');
      if (s % 60 == 0) return context.tr('${s ~/ 60} minute(s)', '${s ~/ 60} 分钟');
      return '$s s';
    }
  }
  if (id == 'ssl') {
    return switch (v) {
      'off' => context.tr('Off (not secure)', '关闭（不安全）'),
      'flexible' => context.tr('Flexible', '灵活'),
      'full' => context.tr('Full', '完全'),
      'strict' => context.tr('Full (strict)', '完全（严格）'),
      _ => '$v',
    };
  }
  if (id == 'tls_1_3' && v == 'zrt') return context.tr('On + 0-RTT', '开启 + 0-RTT');
  return '$v';
}

/// One editable zone setting row.
class ZoneSettingTile extends ConsumerWidget {
  const ZoneSettingTile({super.key, required this.zoneId, required this.setting, required this.onChanged});

  final String zoneId;
  final Map<String, dynamic> setting;
  final ValueChanged<Map<String, dynamic>> onChanged;

  Future<void> _set(BuildContext context, WidgetRef ref, Object? value) async {
    final id = setting['id'] as String;
    final client = ref.read(clientProvider)!;
    final res = await runAction(
      context,
      () => client.send('PATCH', '/zones/$zoneId/settings/$id', data: {'value': value}),
      blocking: false,
    );
    if (res?.result is Map) {
      onChanged(Map<String, dynamic>.from(res!.result as Map));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = setting['id'] as String;
    final meta = settingsMeta[id];
    final value = setting['value'];
    final editable = setting['editable'] != false;
    final title = meta?.label.of(context) ?? id;
    final subtitle = meta?.description?.of(context);
    final mod = setting['modified_on'] != null ? formatRelative(setting['modified_on'], zh: context.isZh) : null;
    final sub = [?subtitle, if (!editable) context.tr('Not available on this plan', '当前套餐不可用'), ?mod].join(' · ');

    Widget? trailing;
    VoidCallback? onTap;
    final isOnOff = value == 'on' || value == 'off';
    if (meta?.options != null || (value is String && !isOnOff)) {
      final options = meta?.options ?? [value as String];
      trailing = DropdownButton<String>(
        value: options.contains(value) ? value as String : null,
        hint: Text('$value'),
        underline: const SizedBox(),
        items: [for (final o in options) DropdownMenuItem(value: o, child: Text(settingValueLabel(context, id, o)))],
        onChanged: editable ? (v) => _set(context, ref, v) : null,
      );
    } else if (isOnOff) {
      trailing = Switch(value: value == 'on', onChanged: editable ? (v) => _set(context, ref, v ? 'on' : 'off') : null);
    } else if (value is num) {
      final opts = meta?.numberOptions;
      if (opts != null) {
        final all = {...opts, value.toInt()}.toList()..sort();
        trailing = DropdownButton<int>(
          value: value.toInt(),
          underline: const SizedBox(),
          items: [for (final o in all) DropdownMenuItem(value: o, child: Text(settingValueLabel(context, id, o)))],
          onChanged: editable ? (v) => _set(context, ref, v) : null,
        );
      } else {
        trailing = TextButton(
          onPressed: !editable
              ? null
              : () async {
                  final t = await promptText(context, title: title, initial: '$value');
                  final n = num.tryParse(t ?? '');
                  if (n != null && context.mounted) await _set(context, ref, n);
                },
          child: Text('$value'),
        );
      }
    } else {
      // Objects / arrays (HSTS, minify, ciphers, NEL...): edit as JSON.
      trailing = const Icon(Icons.chevron_right);
      onTap = !editable
          ? null
          : () async {
              final t = await promptText(
                context,
                title: title,
                initial: prettyJson(value),
                multiline: true,
                monospace: true,
                confirmLabel: context.tr('Save', '保存'),
              );
              if (t == null || !context.mounted) return;
              final Object? parsed;
              try {
                parsed = jsonDecode(t);
              } catch (_) {
                showToast(context, context.tr('Invalid JSON', 'JSON 格式错误'), error: true);
                return;
              }
              await _set(context, ref, parsed);
            };
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: sub.isEmpty
          ? (value is Map || value is List ? Text(prettyJson(value), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)) : null)
          : Text(sub),
      trailing: trailing,
      onTap: onTap,
      enabled: editable,
    );
  }
}

/// Renders settings of the given groups, loaded once for the zone.
class ZoneSettingsList extends ConsumerWidget {
  const ZoneSettingsList({super.key, required this.groups, this.only, this.header = const []});

  final List<SettingGroup> groups;

  /// Restrict to these setting ids (in this order).
  final List<String>? only;
  final List<Widget> header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZoneRequired(
      builder: (context, zoneId, _) => ApiQuery<Map<String, Map<String, dynamic>>>(
        cacheKey: 'zone-settings:$zoneId',
        load: (c) => loadZoneSettings(c, zoneId),
        builder: (context, settings, h) {
          void update(Map<String, dynamic> s) => h.setData({...settings, s['id'] as String: s});
          final sections = <Widget>[];
          for (final g in groups) {
            final order = settingsMeta.keys.toList();
            int rank(String k) {
              final i = order.indexOf(k);
              return i < 0 ? 999 : i;
            }

            final ids = only ??
                (settings.keys.where((k) => (settingsMeta[k]?.group ?? SettingGroup.other) == g).toList()
                  ..sort((a, b) => rank(a).compareTo(rank(b))));
            final tiles = [
              for (final id in ids)
                if (settings[id] != null && (only == null || (settingsMeta[id]?.group ?? SettingGroup.other) == g))
                  ZoneSettingTile(zoneId: zoneId, setting: settings[id]!, onChanged: update),
            ];
            if (tiles.isEmpty) continue;
            sections.add(SectionCard(title: settingGroupLabels[g]!.of(context), children: tiles));
          }
          return ContentList(onRefresh: h.reload, maxWidth: 900, children: [...header, ...sections]);
        },
      ),
    );
  }
}

class ZoneSettingsPage extends StatelessWidget {
  const ZoneSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: context.tr('Zone settings', '域名设置'),
      body: const ZoneSettingsList(groups: SettingGroup.values),
    );
  }
}

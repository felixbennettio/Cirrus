import 'package:flutter/material.dart';

import '../../core/util/tr.dart';

/// Metadata for a Rulesets Engine phase.
class PhaseMeta {
  const PhaseMeta({
    required this.phase,
    required this.title,
    required this.icon,
    required this.actions,
    this.description,
    this.templates = const {},
    this.ratelimit = false,
  });

  final String phase;
  final L10nText title;
  final L10nText? description;
  final IconData icon;
  final List<String> actions;

  /// Example `action_parameters` per action.
  final Map<String, Object?> templates;
  final bool ratelimit;
}

const securityPhases = <PhaseMeta>[
  PhaseMeta(
    phase: 'http_request_firewall_custom',
    title: L10nText('Custom rules', '自定义规则'),
    description: L10nText('Block, challenge or skip requests matching an expression.', '对匹配表达式的请求进行拦截、质询或跳过。'),
    icon: Icons.shield,
    actions: ['block', 'managed_challenge', 'js_challenge', 'challenge', 'log', 'skip'],
    templates: {
      'block': {
        'response': {'status_code': 403, 'content_type': 'text/plain', 'content': 'Forbidden'},
      },
      'skip': {
        'ruleset': 'current',
        'phases': ['http_ratelimit', 'http_request_firewall_managed'],
        'products': ['bic', 'securityLevel', 'uaBlock', 'zoneLockdown', 'hot'],
      },
    },
  ),
  PhaseMeta(
    phase: 'http_ratelimit',
    title: L10nText('Rate limiting rules', '限速规则'),
    description: L10nText('Throttle clients that exceed a request rate.', '限制超过请求速率的客户端。'),
    icon: Icons.speed,
    actions: ['block', 'managed_challenge', 'js_challenge', 'challenge', 'log'],
    ratelimit: true,
  ),
  PhaseMeta(
    phase: 'http_request_firewall_managed',
    title: L10nText('Managed rules', '托管规则'),
    description: L10nText('Deploy Cloudflare-managed WAF rulesets.', '部署 Cloudflare 托管的 WAF 规则集。'),
    icon: Icons.verified_user_outlined,
    actions: ['execute', 'skip'],
    templates: {
      'execute': {'id': 'efb7b8c949ac4650a09736fc376e9aee'},
      'skip': {'ruleset': 'current'},
    },
  ),
  PhaseMeta(
    phase: 'http_response_firewall_managed',
    title: L10nText('Response managed rules', '响应托管规则'),
    description: L10nText('Sensitive data detection on responses.', '响应中的敏感数据检测。'),
    icon: Icons.manage_search,
    actions: ['execute', 'skip'],
  ),
];

const transformPhases = <PhaseMeta>[
  PhaseMeta(
    phase: 'http_request_dynamic_redirect',
    title: L10nText('Redirect rules', '重定向规则'),
    icon: Icons.turn_right,
    actions: ['redirect'],
    templates: {
      'redirect': {
        'from_value': {
          'status_code': 301,
          'target_url': {'expression': 'concat("https://www.example.com", http.request.uri.path)'},
          'preserve_query_string': true,
        },
      },
    },
  ),
  PhaseMeta(
    phase: 'http_request_transform',
    title: L10nText('URL rewrite rules', 'URL 重写规则'),
    icon: Icons.edit_road,
    actions: ['rewrite'],
    templates: {
      'rewrite': {
        'uri': {
          'path': {'value': '/new-path'},
          'query': {'expression': 'http.request.uri.query'},
        },
      },
    },
  ),
  PhaseMeta(
    phase: 'http_request_late_transform',
    title: L10nText('Request header transforms', '请求头转换'),
    icon: Icons.input,
    actions: ['rewrite'],
    templates: {
      'rewrite': {
        'headers': {
          'X-Example': {'operation': 'set', 'value': 'value'},
          'X-Remove-Me': {'operation': 'remove'},
        },
      },
    },
  ),
  PhaseMeta(
    phase: 'http_response_headers_transform',
    title: L10nText('Response header transforms', '响应头转换'),
    icon: Icons.output,
    actions: ['rewrite'],
    templates: {
      'rewrite': {
        'headers': {
          'Strict-Transport-Security': {'operation': 'set', 'value': 'max-age=31536000'},
          'X-Powered-By': {'operation': 'remove'},
        },
      },
    },
  ),
  PhaseMeta(
    phase: 'http_config_settings',
    title: L10nText('Configuration rules', '配置规则'),
    icon: Icons.settings_suggest_outlined,
    actions: ['set_config'],
    templates: {
      'set_config': {'ssl': 'full', 'automatic_https_rewrites': true, 'rocket_loader': false, 'security_level': 'medium'},
    },
  ),
  PhaseMeta(
    phase: 'http_request_origin',
    title: L10nText('Origin rules', '源站规则'),
    icon: Icons.dns,
    actions: ['route'],
    templates: {
      'route': {
        'host_header': 'origin.example.com',
        'origin': {'host': 'origin.example.com', 'port': 8443},
      },
    },
  ),
  PhaseMeta(
    phase: 'http_request_cache_settings',
    title: L10nText('Cache rules', '缓存规则'),
    icon: Icons.cached,
    actions: ['set_cache_settings'],
    templates: {
      'set_cache_settings': {
        'cache': true,
        'edge_ttl': {'mode': 'override_origin', 'default': 3600},
        'browser_ttl': {'mode': 'respect_origin'},
      },
    },
  ),
  PhaseMeta(
    phase: 'http_response_compression',
    title: L10nText('Compression rules', '压缩规则'),
    icon: Icons.compress,
    actions: ['compress_response'],
    templates: {
      'compress_response': {
        'algorithms': [
          {'name': 'zstd'},
          {'name': 'brotli'},
          {'name': 'gzip'},
        ],
      },
    },
  ),
  PhaseMeta(
    phase: 'http_custom_errors',
    title: L10nText('Custom error rules', '自定义错误规则'),
    icon: Icons.error_outline,
    actions: ['serve_error'],
    templates: {
      'serve_error': {'content': '<h1>Something went wrong</h1>', 'content_type': 'text/html', 'status_code': 503},
    },
  ),
  PhaseMeta(
    phase: 'http_log_custom_fields',
    title: L10nText('Custom log fields', '自定义日志字段'),
    icon: Icons.receipt_long_outlined,
    actions: ['log_custom_field'],
    templates: {
      'log_custom_field': {
        'request_fields': [
          {'name': 'content-type'},
        ],
        'cookie_fields': [
          {'name': '__cfruid'},
        ],
      },
    },
  ),
];

const allPhases = [...securityPhases, ...transformPhases];

PhaseMeta? phaseMeta(String phase) {
  for (final p in allPhases) {
    if (p.phase == phase) return p;
  }
  return null;
}

/// Fields offered as quick inserts in the expression editor.
const expressionFields = [
  'http.host',
  'http.request.uri.path',
  'http.request.uri.query',
  'http.request.full_uri',
  'http.request.method',
  'http.user_agent',
  'http.referer',
  'http.cookie',
  'ip.src',
  'ip.src.country',
  'ip.src.asnum',
  'ip.src.continent',
  'cf.client.bot',
  'cf.threat_score',
  'cf.bot_management.score',
  'ssl',
  'http.request.headers["x-example"][0]',
  'http.response.code',
];

const expressionTemplates = <(L10nText, String)>[
  (L10nText('Everything', '全部请求'), 'true'),
  (L10nText('Hostname equals', '主机名等于'), '(http.host eq "www.example.com")'),
  (L10nText('Path starts with', '路径前缀'), 'starts_with(http.request.uri.path, "/admin")'),
  (L10nText('Country in list', '国家/地区在列表中'), '(ip.src.country in {"CN" "RU"})'),
  (L10nText('IP in range', 'IP 段'), '(ip.src in {192.0.2.0/24 2001:db8::/32})'),
  (L10nText('Not a verified bot', '非已验证爬虫'), '(not cf.client.bot)'),
  (L10nText('Uses IP list', '使用 IP 列表'), '(ip.src in \$my_list)'),
];

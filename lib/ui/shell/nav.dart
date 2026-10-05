import 'package:flutter/material.dart';

import '../../core/util/tr.dart';

/// Which context a module needs.
enum NavScope { global, account, zone }

class NavItem {
  const NavItem({
    required this.id,
    required this.path,
    required this.icon,
    required this.label,
    required this.scope,
    this.keywords = const [],
  });

  final String id;
  final String path;
  final IconData icon;
  final L10nText label;
  final NavScope scope;
  final List<String> keywords;
}

class NavSection {
  const NavSection({required this.id, required this.label, required this.items, this.icon});

  final String id;
  final L10nText label;
  final IconData? icon;
  final List<NavItem> items;
}

/// The complete navigation tree of the app.
const navSections = <NavSection>[
  NavSection(
    id: 'home',
    label: L10nText('Overview', '概览'),
    items: [
      NavItem(
        id: 'home',
        path: '/',
        icon: Icons.dashboard_outlined,
        label: L10nText('Home', '首页'),
        scope: NavScope.global,
        keywords: ['dashboard', '仪表盘'],
      ),
      NavItem(
        id: 'domains',
        path: '/domains',
        icon: Icons.language,
        label: L10nText('Domains', '域名'),
        scope: NavScope.account,
        keywords: ['zones', 'websites', '站点', '添加域名'],
      ),
    ],
  ),
  NavSection(
    id: 'zone',
    label: L10nText('Zone', '当前域名'),
    icon: Icons.public,
    items: [
      NavItem(
        id: 'zone.overview',
        path: '/zone',
        icon: Icons.insights_outlined,
        label: L10nText('Zone overview', '域名概览'),
        scope: NavScope.zone,
        keywords: ['pause', 'development mode', '开发模式', '暂停'],
      ),
      NavItem(
        id: 'zone.dns',
        path: '/zone/dns',
        icon: Icons.dns_outlined,
        label: L10nText('DNS', 'DNS 记录'),
        scope: NavScope.zone,
        keywords: ['records', 'a', 'cname', 'mx', 'txt', 'dnssec', '解析'],
      ),
      NavItem(
        id: 'zone.ssl',
        path: '/zone/ssl',
        icon: Icons.lock_outline,
        label: L10nText('SSL/TLS', 'SSL/TLS'),
        scope: NavScope.zone,
        keywords: ['certificate', 'https', 'hsts', 'origin ca', '证书'],
      ),
      NavItem(
        id: 'zone.security',
        path: '/zone/security',
        icon: Icons.shield_outlined,
        label: L10nText('Security & WAF', '安全与 WAF'),
        scope: NavScope.zone,
        keywords: ['firewall', 'waf', 'rate limit', 'bot', 'ip access', '防火墙', '限速'],
      ),
      NavItem(
        id: 'zone.rules',
        path: '/zone/rules',
        icon: Icons.rule,
        label: L10nText('Rules', '规则'),
        scope: NavScope.zone,
        keywords: ['redirect', 'rewrite', 'transform', 'origin rules', 'configuration', 'page rules', '重定向', '重写'],
      ),
      NavItem(
        id: 'zone.cache',
        path: '/zone/cache',
        icon: Icons.cached,
        label: L10nText('Caching', '缓存'),
        scope: NavScope.zone,
        keywords: ['purge', 'cache rules', 'tiered', '清除缓存'],
      ),
      NavItem(
        id: 'zone.settings',
        path: '/zone/settings',
        icon: Icons.tune,
        label: L10nText('Zone settings', '域名设置'),
        scope: NavScope.zone,
        keywords: ['speed', 'network', 'brotli', 'http3', 'ipv6', 'websockets', 'rocket loader', '速度', '网络'],
      ),
      NavItem(
        id: 'zone.analytics',
        path: '/zone/analytics',
        icon: Icons.bar_chart,
        label: L10nText('Analytics', '分析'),
        scope: NavScope.zone,
        keywords: ['traffic', 'requests', 'bandwidth', '流量'],
      ),
      NavItem(
        id: 'zone.workers',
        path: '/zone/workers-routes',
        icon: Icons.alt_route,
        label: L10nText('Workers routes', 'Workers 路由'),
        scope: NavScope.zone,
      ),
      NavItem(
        id: 'zone.email',
        path: '/zone/email',
        icon: Icons.alternate_email,
        label: L10nText('Email Routing', '邮件路由'),
        scope: NavScope.zone,
        keywords: ['email', 'forward', '转发'],
      ),
      NavItem(
        id: 'zone.more',
        path: '/zone/more',
        icon: Icons.apps,
        label: L10nText('More zone features', '更多域名功能'),
        scope: NavScope.zone,
        keywords: [
          'custom hostnames',
          'load balancing',
          'waiting room',
          'health checks',
          'spectrum',
          'page shield',
          'snippets',
          'logpush',
        ],
      ),
    ],
  ),
  NavSection(
    id: 'compute',
    label: L10nText('Compute & AI', '计算与 AI'),
    icon: Icons.memory,
    items: [
      NavItem(
        id: 'workers',
        path: '/workers',
        icon: Icons.bolt,
        label: L10nText('Workers', 'Workers'),
        scope: NavScope.account,
        keywords: ['scripts', 'serverless', 'deploy', 'tail', 'logs', '部署', '日志'],
      ),
      NavItem(
        id: 'pages',
        path: '/pages',
        icon: Icons.web,
        label: L10nText('Pages', 'Pages'),
        scope: NavScope.account,
        keywords: ['deployments', 'static', '部署'],
      ),
      NavItem(
        id: 'ai',
        path: '/ai',
        icon: Icons.auto_awesome,
        label: L10nText('Workers AI', 'Workers AI'),
        scope: NavScope.account,
        keywords: ['llm', 'models', 'playground', '模型'],
      ),
      NavItem(
        id: 'compute.more',
        path: '/compute/more',
        icon: Icons.apps,
        label: L10nText('More compute', '更多计算服务'),
        scope: NavScope.account,
        keywords: ['queues', 'workflows', 'durable objects', 'ai gateway', 'containers', 'browser rendering'],
      ),
    ],
  ),
  NavSection(
    id: 'storage',
    label: L10nText('Storage & Databases', '存储与数据库'),
    icon: Icons.storage,
    items: [
      NavItem(
        id: 'kv',
        path: '/kv',
        icon: Icons.key,
        label: L10nText('Workers KV', 'Workers KV'),
        scope: NavScope.account,
        keywords: ['key value', '键值'],
      ),
      NavItem(
        id: 'r2',
        path: '/r2',
        icon: Icons.cloud_queue,
        label: L10nText('R2', 'R2 对象存储'),
        scope: NavScope.account,
        keywords: ['buckets', 'objects', 's3', '存储桶'],
      ),
      NavItem(
        id: 'd1',
        path: '/d1',
        icon: Icons.table_chart_outlined,
        label: L10nText('D1', 'D1 数据库'),
        scope: NavScope.account,
        keywords: ['sqlite', 'sql', 'database', '数据库'],
      ),
      NavItem(
        id: 'storage.more',
        path: '/storage/more',
        icon: Icons.apps,
        label: L10nText('More storage', '更多存储服务'),
        scope: NavScope.account,
        keywords: ['hyperdrive', 'vectorize', 'secrets store', 'queues'],
      ),
    ],
  ),
  NavSection(
    id: 'zt',
    label: L10nText('Zero Trust', 'Zero Trust'),
    icon: Icons.verified_user_outlined,
    items: [
      NavItem(
        id: 'tunnels',
        path: '/zt/tunnels',
        icon: Icons.settings_ethernet,
        label: L10nText('Tunnels', '隧道'),
        scope: NavScope.account,
        keywords: ['cloudflared', 'public hostname', 'ingress', '内网穿透'],
      ),
      NavItem(
        id: 'access',
        path: '/zt/access',
        icon: Icons.admin_panel_settings_outlined,
        label: L10nText('Access', 'Access 访问控制'),
        scope: NavScope.account,
        keywords: ['applications', 'policies', 'groups', 'service tokens', 'idp', 'sso'],
      ),
      NavItem(
        id: 'gateway',
        path: '/zt/gateway',
        icon: Icons.filter_alt_outlined,
        label: L10nText('Gateway', 'Gateway 网关'),
        scope: NavScope.account,
        keywords: ['dns filtering', 'http policies', 'locations', 'lists'],
      ),
      NavItem(
        id: 'devices',
        path: '/zt/devices',
        icon: Icons.devices_other,
        label: L10nText('Devices (WARP)', '设备（WARP）'),
        scope: NavScope.account,
        keywords: ['warp', 'split tunnel', 'posture', 'profiles'],
      ),
      NavItem(
        id: 'networks',
        path: '/zt/networks',
        icon: Icons.hub_outlined,
        label: L10nText('Networks', '网络'),
        scope: NavScope.account,
        keywords: ['routes', 'virtual networks', 'private network', 'cidr'],
      ),
      NavItem(
        id: 'zt.more',
        path: '/zt/more',
        icon: Icons.apps,
        label: L10nText('More Zero Trust', '更多 Zero Trust'),
        scope: NavScope.account,
        keywords: ['dlp', 'casb', 'dex', 'organization', 'risk'],
      ),
    ],
  ),
  NavSection(
    id: 'account',
    label: L10nText('Account', '账户'),
    icon: Icons.account_circle_outlined,
    items: [
      NavItem(
        id: 'members',
        path: '/account/members',
        icon: Icons.group_outlined,
        label: L10nText('Members', '成员'),
        scope: NavScope.account,
        keywords: ['invite', 'roles', '邀请'],
      ),
      NavItem(
        id: 'tokens',
        path: '/account/tokens',
        icon: Icons.vpn_key_outlined,
        label: L10nText('API tokens', 'API Token'),
        scope: NavScope.global,
        keywords: ['token', 'permissions', '权限'],
      ),
      NavItem(
        id: 'audit',
        path: '/account/audit',
        icon: Icons.history,
        label: L10nText('Audit log', '审计日志'),
        scope: NavScope.account,
      ),
      NavItem(
        id: 'registrar',
        path: '/account/registrar',
        icon: Icons.storefront_outlined,
        label: L10nText('Registrar', '域名注册'),
        scope: NavScope.account,
        keywords: ['domains', 'renew', 'transfer', '续费'],
      ),
      NavItem(
        id: 'lists',
        path: '/account/lists',
        icon: Icons.list_alt,
        label: L10nText('Lists', '列表'),
        scope: NavScope.account,
        keywords: ['ip list', 'redirect list', 'bulk redirects', 'asn'],
      ),
      NavItem(
        id: 'notifications',
        path: '/account/notifications',
        icon: Icons.notifications_outlined,
        label: L10nText('Notifications', '通知'),
        scope: NavScope.account,
        keywords: ['alerts', 'webhooks', '告警'],
      ),
      NavItem(
        id: 'account.more',
        path: '/account/more',
        icon: Icons.apps,
        label: L10nText('More account features', '更多账户功能'),
        scope: NavScope.account,
        keywords: ['billing', 'load balancer pools', 'monitors', 'logpush', 'images', 'stream', 'turnstile'],
      ),
    ],
  ),
  NavSection(
    id: 'tools',
    label: L10nText('Tools', '工具'),
    icon: Icons.build_outlined,
    items: [
      NavItem(
        id: 'console',
        path: '/console',
        icon: Icons.terminal,
        label: L10nText('API console', 'API 控制台'),
        scope: NavScope.global,
        keywords: ['api', 'endpoint', 'explorer', 'all', '全部接口', '调试'],
      ),
      NavItem(
        id: 'graphql',
        path: '/graphql',
        icon: Icons.query_stats,
        label: L10nText('GraphQL explorer', 'GraphQL 查询'),
        scope: NavScope.global,
        keywords: ['analytics', 'graphql'],
      ),
      NavItem(
        id: 'requests',
        path: '/requests',
        icon: Icons.receipt_long_outlined,
        label: L10nText('Request log', '请求日志'),
        scope: NavScope.global,
        keywords: ['debug', 'history'],
      ),
      NavItem(
        id: 'settings',
        path: '/settings',
        icon: Icons.settings_outlined,
        label: L10nText('Settings', '设置'),
        scope: NavScope.global,
        keywords: ['profiles', 'theme', 'language', 'lock', '主题', '语言', '凭据'],
      ),
    ],
  ),
];

Iterable<NavItem> get allNavItems => navSections.expand((s) => s.items);

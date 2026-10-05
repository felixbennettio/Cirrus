import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/util/tr.dart';
import '../features/analytics/zone_analytics_page.dart';
import '../features/cache/cache_page.dart';
import '../features/dns/dns_page.dart';
import '../features/generic/resource_page.dart';
import '../features/generic/resource_specs.dart';
import '../features/ssl/ssl_page.dart';
import '../features/zone_settings/zone_settings.dart';
import '../features/zones/zone_overview_page.dart';

NoTransitionPage<void> _page(GoRouterState s, Widget child) => NoTransitionPage(key: s.pageKey, child: child);

/// Routes of the feature modules (inside the shell).
final featureRoutes = <RouteBase>[
  GoRoute(path: '/zone', pageBuilder: (c, s) => _page(s, const ZoneOverviewPage())),
  GoRoute(path: '/zone/dns', pageBuilder: (c, s) => _page(s, const DnsPage())),
  GoRoute(path: '/zone/ssl', pageBuilder: (c, s) => _page(s, const SslPage())),
  GoRoute(path: '/zone/cache', pageBuilder: (c, s) => _page(s, const CachePage())),
  GoRoute(path: '/zone/settings', pageBuilder: (c, s) => _page(s, const ZoneSettingsPage())),
  GoRoute(path: '/zone/analytics', pageBuilder: (c, s) => _page(s, const ZoneAnalyticsPage())),
  GoRoute(
    path: '/zone/more',
    pageBuilder: (c, s) => _page(
      s,
      ResourceHubPage(
        title: c.tr('More zone features', '更多域名功能'),
        specs: zoneSpecs.where((e) => e.id != 'zone_worker_routes').toList(),
        documents: documentSpecs.where((d) => d.scope == SpecScope.zone).toList(),
      ),
    ),
  ),
  GoRoute(
    path: '/zone/workers-routes',
    pageBuilder: (c, s) => _page(s, ResourcePage(spec: specById['zone_worker_routes']!)),
  ),
  GoRoute(
    path: '/compute/more',
    pageBuilder: (c, s) => _page(s, ResourceHubPage(title: c.tr('More compute', '更多计算服务'), specs: computeSpecs)),
  ),
  GoRoute(
    path: '/storage/more',
    pageBuilder: (c, s) => _page(s, ResourceHubPage(title: c.tr('More storage', '更多存储服务'), specs: storageSpecs)),
  ),
  GoRoute(
    path: '/zt/access',
    pageBuilder: (c, s) => _page(
      s,
      TabbedResourcesPage(title: c.tr('Access', 'Access 访问控制'), tabs: [...accessSpecs, documentById['access_organization']!]),
    ),
  ),
  GoRoute(
    path: '/zt/gateway',
    pageBuilder: (c, s) => _page(
      s,
      TabbedResourcesPage(
        title: c.tr('Gateway', 'Gateway 网关'),
        tabs: [...gatewaySpecs, documentById['gateway_configuration']!, documentById['gateway_logging']!],
      ),
    ),
  ),
  GoRoute(
    path: '/zt/devices',
    pageBuilder: (c, s) => _page(
      s,
      TabbedResourcesPage(
        title: c.tr('Devices (WARP)', '设备（WARP）'),
        tabs: [
          ...deviceSpecs,
          documentById['device_default_profile']!,
          documentById['split_tunnel_exclude']!,
          documentById['split_tunnel_include']!,
          documentById['fallback_domains']!,
          documentById['device_settings']!,
        ],
      ),
    ),
  ),
  GoRoute(
    path: '/zt/networks',
    pageBuilder: (c, s) => _page(s, TabbedResourcesPage(title: c.tr('Networks', '网络'), tabs: networkSpecs)),
  ),
  GoRoute(
    path: '/zt/more',
    pageBuilder: (c, s) => _page(
      s,
      ResourceHubPage(title: c.tr('More Zero Trust', '更多 Zero Trust'), specs: zeroTrustMoreSpecs, documents: [documentById['access_organization']!]),
    ),
  ),
  GoRoute(
    path: '/account/registrar',
    pageBuilder: (c, s) => _page(s, ResourcePage(spec: specById['registrar_domains']!)),
  ),
  GoRoute(
    path: '/account/notifications',
    pageBuilder: (c, s) => _page(
      s,
      TabbedResourcesPage(
        title: c.tr('Notifications', '通知'),
        tabs: [specById['alert_policies']!, specById['alert_webhooks']!, specById['alert_history']!, documentById['available_alerts']!],
      ),
    ),
  ),
  GoRoute(
    path: '/account/more',
    pageBuilder: (c, s) => _page(
      s,
      ResourceHubPage(
        title: c.tr('More account features', '更多账户功能'),
        specs: accountSpecs.where((e) => !const {'registrar_domains', 'alert_policies', 'alert_webhooks', 'alert_history'}.contains(e.id)).toList(),
        documents: documentSpecs.where((d) => d.group == gAccount).toList(),
      ),
    ),
  ),
];

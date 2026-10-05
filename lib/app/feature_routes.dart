import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/util/tr.dart';
import '../features/account/audit_page.dart';
import '../features/account/lists_page.dart';
import '../features/account/members_page.dart';
import '../features/account/tokens_page.dart';
import '../features/ai/ai_page.dart';
import '../features/analytics/zone_analytics_page.dart';
import '../features/cache/cache_page.dart';
import '../features/console/console_page.dart';
import '../features/console/graphql_page.dart';
import '../features/dns/dns_page.dart';
import '../features/email/email_routing_page.dart';
import '../features/generic/resource_page.dart';
import '../features/generic/resource_specs.dart';
import '../features/pages/pages_pages.dart';
import '../features/rules/rules_pages.dart';
import '../features/ssl/ssl_page.dart';
import '../features/storage/d1_pages.dart';
import '../features/storage/kv_pages.dart';
import '../features/storage/r2_pages.dart';
import '../features/zone_settings/zone_settings.dart';
import '../features/workers/worker_detail_page.dart';
import '../features/workers/workers_list_page.dart';
import '../features/zerotrust/tunnels_pages.dart';
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
  GoRoute(path: '/zone/security', pageBuilder: (c, s) => _page(s, const SecurityPage())),
  GoRoute(
    path: '/zone/rules',
    pageBuilder: (c, s) => _page(s, RulesPage(initialPhase: s.uri.queryParameters['phase'])),
  ),
  GoRoute(path: '/zone/email', pageBuilder: (c, s) => _page(s, const EmailRoutingPage())),
  GoRoute(
    path: '/pages',
    pageBuilder: (c, s) => _page(s, const PagesListPage()),
    routes: [
      GoRoute(
        path: ':name',
        builder: (c, s) => PagesProjectPage(name: s.pathParameters['name']!),
      ),
    ],
  ),
  GoRoute(
    path: '/kv',
    pageBuilder: (c, s) => _page(s, const KvNamespacesPage()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (c, s) => KvBrowserPage(namespaceId: s.pathParameters['id']!, title: s.uri.queryParameters['title']),
      ),
    ],
  ),
  GoRoute(
    path: '/r2',
    pageBuilder: (c, s) => _page(s, const R2BucketsPage()),
    routes: [
      GoRoute(
        path: ':bucket',
        builder: (c, s) => R2BucketPage(bucket: s.pathParameters['bucket']!),
      ),
    ],
  ),
  GoRoute(
    path: '/d1',
    pageBuilder: (c, s) => _page(s, const D1DatabasesPage()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (c, s) => D1ConsolePage(databaseId: s.pathParameters['id']!, name: s.uri.queryParameters['name']),
      ),
    ],
  ),
  GoRoute(
    path: '/workers',
    pageBuilder: (c, s) => _page(s, const WorkersListPage()),
    routes: [
      GoRoute(
        path: ':name',
        builder: (c, s) => WorkerDetailPage(name: s.pathParameters['name']!),
      ),
    ],
  ),
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
  GoRoute(path: '/ai', pageBuilder: (c, s) => _page(s, const AiPage())),
  GoRoute(
    path: '/zt/tunnels',
    pageBuilder: (c, s) => _page(s, const TunnelsPage()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (c, s) => TunnelDetailPage(tunnelId: s.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(path: '/account/members', pageBuilder: (c, s) => _page(s, const MembersPage())),
  GoRoute(path: '/account/tokens', pageBuilder: (c, s) => _page(s, const TokensPage())),
  GoRoute(path: '/account/audit', pageBuilder: (c, s) => _page(s, const AuditLogPage())),
  GoRoute(
    path: '/account/lists',
    pageBuilder: (c, s) => _page(s, const ListsPage()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (c, s) => ListItemsPage(
          listId: s.pathParameters['id']!,
          kind: s.uri.queryParameters['kind'] ?? 'ip',
          name: s.uri.queryParameters['name'],
        ),
      ),
    ],
  ),
  GoRoute(
    path: '/console',
    pageBuilder: (c, s) => _page(s, ConsolePage(initialOpId: s.uri.queryParameters['op'])),
    routes: [
      GoRoute(
        path: 'op/:id',
        builder: (c, s) => ConsoleOperationPage(opId: s.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(path: '/graphql', pageBuilder: (c, s) => _page(s, const GraphqlPage())),
  GoRoute(path: '/requests', pageBuilder: (c, s) => _page(s, const RequestLogPage())),
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
      TabbedResourcesPage(
        title: c.tr('Access', 'Access 访问控制'),
        tabs: [...accessSpecs, documentById['access_organization']!],
      ),
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
      ResourceHubPage(
        title: c.tr('More Zero Trust', '更多 Zero Trust'),
        specs: zeroTrustMoreSpecs,
        documents: [documentById['access_organization']!],
      ),
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
        tabs: [
          specById['alert_policies']!,
          specById['alert_webhooks']!,
          specById['alert_history']!,
          documentById['available_alerts']!,
        ],
      ),
    ),
  ),
  GoRoute(
    path: '/account/more',
    pageBuilder: (c, s) => _page(
      s,
      ResourceHubPage(
        title: c.tr('More account features', '更多账户功能'),
        specs: accountSpecs
            .where(
              (e) => !const {'registrar_domains', 'alert_policies', 'alert_webhooks', 'alert_history'}.contains(e.id),
            )
            .toList(),
        documents: documentSpecs.where((d) => d.group == gAccount).toList(),
      ),
    ),
  ),
];

import 'package:flutter/material.dart';

import '../../core/util/tr.dart';
import '../generic/resource_specs.dart';

/// What Cirrus Pro unlocks in store builds. Managing zones (DNS, SSL/TLS,
/// security, rules, caching, zone settings, analytics) stays free.
enum ProFeature {
  compute(Icons.bolt, L10nText('Workers, Pages & Workers AI', 'Workers、Pages 与 Workers AI')),
  storage(Icons.storage_outlined, L10nText('KV, R2, D1 and other storage', 'KV、R2、D1 等存储与数据库')),
  zeroTrust(
    Icons.shield_moon_outlined,
    L10nText('Zero Trust: Tunnels, Access, Gateway, devices', 'Zero Trust：隧道、Access、Gateway、设备'),
  ),
  account(Icons.manage_accounts_outlined, L10nText('Members, API tokens, audit log & more', '成员、API Token、审计日志等账户管理')),
  credentials(Icons.people_alt_outlined, L10nText('More than one credential', '保存多套凭据')),
  consoleWrites(Icons.terminal, L10nText('Write requests in the API console', '在 API 控制台发送写请求')),
  graphql(Icons.hub_outlined, L10nText('GraphQL explorer', 'GraphQL 查询')),
  longAnalytics(Icons.insights_outlined, L10nText('30-day analytics', '30 天流量分析'));

  const ProFeature(this.icon, this.label);

  final IconData icon;
  final L10nText label;
}

/// Path prefixes of whole Pro sections.
const _proPrefixes = <String, ProFeature>{
  '/workers': ProFeature.compute,
  '/pages': ProFeature.compute,
  '/ai': ProFeature.compute,
  '/compute': ProFeature.compute,
  '/kv': ProFeature.storage,
  '/r2': ProFeature.storage,
  '/d1': ProFeature.storage,
  '/storage': ProFeature.storage,
  '/zt': ProFeature.zeroTrust,
  '/account': ProFeature.account,
  '/graphql': ProFeature.graphql,
};

bool _under(String location, String prefix) => location == prefix || location.startsWith('$prefix/');

/// The Pro feature a page belongs to, or null when it is free. Generic
/// resource pages (`/r/...`, `/doc/...`) are free when zone-scoped.
ProFeature? proFeatureFor(String location) {
  final path = Uri.parse(location).path;
  for (final e in _proPrefixes.entries) {
    if (_under(path, e.key)) return e.value;
  }
  final segments = Uri.parse(path).pathSegments;
  if (segments.length >= 2 && (segments.first == 'r' || segments.first == 'doc')) {
    final id = segments[1];
    // Everything listed under "More zone features" stays free.
    if (segments.first == 'r' && zoneSpecs.any((s) => s.id == id)) return null;
    final scope = segments.first == 'r' ? specById[id]?.scope : documentById[id]?.scope;
    if (scope == null || scope == SpecScope.zone) return null;
    return _featureForSpec(id);
  }
  return null;
}

/// Account-level generic resources, grouped like the sidebar.
ProFeature _featureForSpec(String id) {
  bool inList(List<ResourceSpec> l) => l.any((s) => s.id == id);
  if (inList(computeSpecs)) return ProFeature.compute;
  if (inList(storageSpecs)) return ProFeature.storage;
  if ([accessSpecs, gatewaySpecs, deviceSpecs, networkSpecs, zeroTrustMoreSpecs].any(inList)) {
    return ProFeature.zeroTrust;
  }
  return ProFeature.account;
}

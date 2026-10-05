import 'package:flutter/material.dart';

import '../../core/api/cf_client.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/json_view.dart';
import '../generic/resource_page.dart';
import '../generic/resource_specs.dart';
import '../zone_settings/zone_settings.dart';
import 'phases.dart';
import 'ruleset_view.dart';

const ipAccessRulesSpec = ResourceSpec(
  id: 'ip_access_rules',
  title: L10nText('IP access rules', 'IP 访问规则'),
  group: gZone,
  icon: Icons.public_off,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/firewall/access_rules/rules',
  titleFields: ['configuration.value'],
  subtitleFields: ['configuration.target', 'notes', 'created_on'],
  statusField: 'mode',
  updateMethod: 'PATCH',
  keywords: ['block ip', 'allow ip', 'whitelist', 'country block'],
);

const uaRulesSpec = ResourceSpec(
  id: 'ua_rules',
  title: L10nText('User agent blocking', 'User-Agent 拦截'),
  group: gZone,
  icon: Icons.person_off_outlined,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/firewall/ua_rules',
  titleFields: ['configuration.value', 'description'],
  subtitleFields: ['mode', 'description'],
  statusField: 'paused',
  updateMethod: 'PUT',
);

const lockdownSpec = ResourceSpec(
  id: 'zone_lockdowns',
  title: L10nText('Zone lockdown', '区域锁定'),
  group: gZone,
  icon: Icons.lock_person_outlined,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/firewall/lockdowns',
  titleFields: ['description', 'id'],
  subtitleFields: ['urls'],
  statusField: 'paused',
  updateMethod: 'PUT',
);

const pageRulesSpec = ResourceSpec(
  id: 'page_rules',
  title: L10nText('Page Rules (legacy)', '页面规则（旧版）'),
  group: gZone,
  icon: Icons.description_outlined,
  scope: SpecScope.zone,
  listPath: '/zones/{zone_id}/pagerules',
  titleFields: ['targets.0.constraint.value', 'id'],
  subtitleFields: ['priority', 'modified_on'],
  statusField: 'status',
  updateMethod: 'PUT',
  paginate: false,
);

class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      (context.tr('Overview', '概览'), const ZoneSettingsList(groups: [SettingGroup.security, SettingGroup.scrape])),
      for (final p in securityPhases) (p.title.of(context), _ZonePhase(meta: p)),
      (context.tr('Events', '安全事件'), const _SecurityEvents()),
      (ipAccessRulesSpec.title.of(context), const ResourceListView(spec: ipAccessRulesSpec)),
      (context.tr('Bots', '机器人'), DocumentView(spec: documentById['bot_management']!)),
      (uaRulesSpec.title.of(context), const ResourceListView(spec: uaRulesSpec)),
      (lockdownSpec.title.of(context), const ResourceListView(spec: lockdownSpec)),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: PageScaffold(
        title: context.tr('Security & WAF', '安全与 WAF'),
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in tabs) Tab(text: t.$1)],
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

class RulesPage extends StatelessWidget {
  const RulesPage({super.key, this.initialPhase});

  final String? initialPhase;

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      for (final p in transformPhases) (p.title.of(context), _ZonePhase(meta: p)),
      (pageRulesSpec.title.of(context), const ResourceListView(spec: pageRulesSpec)),
      (documentById['managed_headers']!.title.of(context), DocumentView(spec: documentById['managed_headers']!)),
      (documentById['url_normalization']!.title.of(context), DocumentView(spec: documentById['url_normalization']!)),
    ];
    final initial = initialPhase == null
        ? 0
        : transformPhases.indexWhere((p) => p.phase == initialPhase).clamp(0, tabs.length - 1);
    return DefaultTabController(
      length: tabs.length,
      initialIndex: initial,
      child: PageScaffold(
        title: context.tr('Rules', '规则'),
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in tabs) Tab(text: t.$1)],
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

class _ZonePhase extends StatelessWidget {
  const _ZonePhase({required this.meta});

  final PhaseMeta meta;

  @override
  Widget build(BuildContext context) {
    return ZoneRequired(
      builder: (context, zoneId, _) =>
          RulesetPhaseView(key: ValueKey('$zoneId:${meta.phase}'), meta: meta, basePath: '/zones/$zoneId'),
    );
  }
}

const _eventsQuery = r'''
query SecurityEvents($zoneTag: string, $since: Time, $until: Time) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      firewallEventsAdaptive(limit: 200, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
        action
        source
        datetime
        clientIP
        clientCountryName
        clientAsn
        clientRequestHTTPHost
        clientRequestHTTPMethodName
        clientRequestPath
        clientRequestQuery
        userAgent
        ruleId
        rayName
        description
      }
    }
  }
}''';

Future<List<Map<String, dynamic>>> _loadEvents(CfClient c, String zoneId, int hours) async {
  final now = DateTime.now().toUtc();
  final data = await c.graphql(
    _eventsQuery,
    variables: {
      'zoneTag': zoneId,
      'since': now.subtract(Duration(hours: hours)).toIso8601String(),
      'until': now.toIso8601String(),
    },
  );
  final zones = (data['viewer'] as Map?)?['zones'] as List? ?? const [];
  if (zones.isEmpty) return const [];
  return ((zones.first as Map)['firewallEventsAdaptive'] as List? ?? const [])
      .cast<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

class _SecurityEvents extends StatefulWidget {
  const _SecurityEvents();

  @override
  State<_SecurityEvents> createState() => _SecurityEventsState();
}

class _SecurityEventsState extends State<_SecurityEvents> {
  int _hours = 24;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return ZoneRequired(
      builder: (context, zoneId, _) => ApiQuery<List<Map<String, dynamic>>>(
        cacheKey: 'fw-events:$zoneId:$_hours',
        load: (c) => _loadEvents(c, zoneId, _hours),
        builder: (context, events, h) {
          final q = _q.toLowerCase();
          final list = q.isEmpty ? events : events.where((e) => e.toString().toLowerCase().contains(q)).toList();
          final byAction = <String, int>{};
          for (final e in events) {
            final a = '${e['action']}';
            byAction[a] = (byAction[a] ?? 0) + 1;
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: SearchField(onChanged: (v) => setState(() => _q = v.trim()))),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _hours,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1h')),
                        DropdownMenuItem(value: 6, child: Text('6h')),
                        DropdownMenuItem(value: 24, child: Text('24h')),
                        DropdownMenuItem(value: 72, child: Text('3d')),
                      ],
                      onChanged: (v) => setState(() => _hours = v ?? 24),
                    ),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: h.reload),
                  ],
                ),
              ),
              if (byAction.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final e in byAction.entries)
                        Chip(label: Text('${e.key}: ${e.value}'), visualDensity: VisualDensity.compact),
                    ],
                  ),
                ),
              Expanded(
                child: list.isEmpty
                    ? EmptyView(icon: Icons.verified_user, title: context.tr('No security events', '没有安全事件'))
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = list[i];
                          return ListTile(
                            dense: true,
                            leading: StatusChip('${e['action']}', tone: e['action'] == 'block' ? Tone.bad : Tone.warn),
                            title: Text(
                              '${e['clientRequestHTTPMethodName'] ?? ''} ${e['clientRequestHTTPHost'] ?? ''}${e['clientRequestPath'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                            subtitle: Text(
                              '${formatDate(e['datetime'])} · ${e['clientIP']} · ${e['clientCountryName']} · AS${e['clientAsn']} · ${e['source']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => showJsonDialog(context, e, title: '${e['rayName'] ?? 'Event'}'),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

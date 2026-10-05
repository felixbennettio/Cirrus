import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/session/session.dart';
import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/code_editor.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/feedback.dart';
import '../../ui/widgets/json_view.dart';

class _Template {
  const _Template(this.title, this.query, this.variables);

  final L10nText title;
  final String query;
  final Map<String, String> variables; // value placeholders: {zone}, {account}, {since}, {until}, {sinceDate}, {untilDate}
}

const _templates = [
  _Template(
    L10nText('Zone traffic by day', '域名每日流量'),
    r'''query ($zoneTag: string, $since: Date, $until: Date) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      httpRequests1dGroups(limit: 31, filter: { date_geq: $since, date_leq: $until }, orderBy: [date_ASC]) {
        dimensions { date }
        sum { requests cachedRequests bytes threats pageViews }
        uniq { uniques }
      }
    }
  }
}''',
    {'zoneTag': '{zone}', 'since': '{sinceDate}', 'until': '{untilDate}'},
  ),
  _Template(
    L10nText('Top paths (adaptive)', '热门路径（自适应）'),
    r'''query ($zoneTag: string, $since: Time, $until: Time) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      httpRequestsAdaptiveGroups(limit: 20, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [count_DESC]) {
        count
        dimensions { clientRequestPath clientRequestHTTPHost }
      }
    }
  }
}''',
    {'zoneTag': '{zone}', 'since': '{since}', 'until': '{until}'},
  ),
  _Template(
    L10nText('Firewall events', '防火墙事件'),
    r'''query ($zoneTag: string, $since: Time, $until: Time) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      firewallEventsAdaptive(limit: 50, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
        action source datetime clientIP clientCountryName clientRequestPath userAgent ruleId
      }
    }
  }
}''',
    {'zoneTag': '{zone}', 'since': '{since}', 'until': '{until}'},
  ),
  _Template(
    L10nText('Workers invocations', 'Workers 调用'),
    r'''query ($accountTag: string, $since: Time, $until: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      workersInvocationsAdaptive(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }) {
        sum { requests errors subrequests }
        quantiles { cpuTimeP50 cpuTimeP99 }
        dimensions { scriptName status }
      }
    }
  }
}''',
    {'accountTag': '{account}', 'since': '{since}', 'until': '{until}'},
  ),
  _Template(
    L10nText('R2 operations', 'R2 操作'),
    r'''query ($accountTag: string, $since: Time, $until: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      r2OperationsAdaptiveGroups(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }) {
        sum { requests }
        dimensions { bucketName actionType }
      }
    }
  }
}''',
    {'accountTag': '{account}', 'since': '{since}', 'until': '{until}'},
  ),
  _Template(
    L10nText('R2 storage', 'R2 存储量'),
    r'''query ($accountTag: string, $since: Time, $until: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      r2StorageAdaptiveGroups(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
        max { objectCount payloadSize metadataSize }
        dimensions { bucketName datetime }
      }
    }
  }
}''',
    {'accountTag': '{account}', 'since': '{since}', 'until': '{until}'},
  ),
  _Template(
    L10nText('D1 queries', 'D1 查询'),
    r'''query ($accountTag: string, $since: Date, $until: Date) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      d1AnalyticsAdaptiveGroups(limit: 100, filter: { date_geq: $since, date_leq: $until }) {
        sum { readQueries writeQueries rowsRead rowsWritten }
        dimensions { databaseId date }
      }
    }
  }
}''',
    {'accountTag': '{account}', 'since': '{sinceDate}', 'until': '{untilDate}'},
  ),
  _Template(
    L10nText('DNS queries', 'DNS 查询'),
    r'''query ($zoneTag: string, $since: Time, $until: Time) {
  viewer {
    zones(filter: { zoneTag: $zoneTag }) {
      dnsAnalyticsAdaptiveGroups(limit: 50, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [count_DESC]) {
        count
        dimensions { queryName queryType responseCode }
      }
    }
  }
}''',
    {'zoneTag': '{zone}', 'since': '{since}', 'until': '{until}'},
  ),
];

class GraphqlPage extends ConsumerStatefulWidget {
  const GraphqlPage({super.key});

  @override
  ConsumerState<GraphqlPage> createState() => _GraphqlPageState();
}

class _GraphqlPageState extends ConsumerState<GraphqlPage> {
  late final CodeLineEditingController _query = CodeLineEditingController.fromText(_templates.first.query);
  late final CodeLineEditingController _vars = CodeLineEditingController.fromText(_varsFor(_templates.first));
  Object? _result;
  Object? _error;
  bool _running = false;
  int _template = 0;

  String _varsFor(_Template t) {
    final now = DateTime.now().toUtc();
    final ids = ref.read(scopeIdsProvider);
    final values = {
      '{zone}': ids['zone_id'] ?? '',
      '{account}': ids['account_id'] ?? '',
      '{since}': now.subtract(const Duration(hours: 24)).toIso8601String(),
      '{until}': now.toIso8601String(),
      '{sinceDate}': now.subtract(const Duration(days: 7)).toIso8601String().substring(0, 10),
      '{untilDate}': now.toIso8601String().substring(0, 10),
    };
    return prettyJson({for (final e in t.variables.entries) e.key: values[e.value] ?? e.value});
  }

  @override
  void dispose() {
    _query.dispose();
    _vars.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    Map<String, dynamic> vars;
    try {
      vars = _vars.text.trim().isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(_vars.text) as Map);
    } catch (_) {
      showToast(context, context.tr('Variables must be a JSON object', '变量必须是 JSON 对象'), error: true);
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await ref.read(clientProvider)!.graphql(_query.text, variables: vars);
      setState(() => _result = r);
    } catch (e) {
      setState(() => _error = e);
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    Widget box(Widget child, double height) => SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
      ),
    );
    final editor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _template,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Template', '模板'), border: const OutlineInputBorder(), isDense: true),
                items: [for (var i = 0; i < _templates.length; i++) DropdownMenuItem(value: i, child: Text(_templates[i].title.of(context)))],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _template = v);
                  _query.text = _templates[v].query;
                  _vars.text = _varsFor(_templates[v]);
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
              label: Text(context.tr('Run', '执行')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
          },
          child: box(CodeEditorField(controller: _query, language: 'graphql'), wide ? 360 : 260),
        ),
        const SizedBox(height: 8),
        Text(context.tr('Variables', '变量'), style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        box(CodeEditorField(controller: _vars, language: 'json'), 140),
      ],
    );
    final result = _error != null
        ? ErrorView(error: _error!, compact: true)
        : _result == null
        ? EmptyView(icon: Icons.query_stats, title: context.tr('Results appear here', '结果会显示在这里'))
        : JsonViewer(_result);
    return PageScaffold(
      title: context.tr('GraphQL explorer', 'GraphQL 查询'),
      subtitle: 'api.cloudflare.com/client/v4/graphql',
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: SingleChildScrollView(child: editor)),
                  const SizedBox(width: 12),
                  Expanded(child: result),
                ],
              )
            : ListView(children: [editor, const SizedBox(height: 12), SizedBox(height: 520, child: result)]),
      ),
    );
  }
}

class RequestLogPage extends ConsumerWidget {
  const RequestLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    return PageScaffold(
      title: context.tr('Request log', '请求日志'),
      subtitle: context.tr('Recent API calls made by Cirrus (no credentials are recorded)', 'Cirrus 最近发出的 API 请求（不记录凭据）'),
      body: client == null
          ? const SizedBox()
          : ValueListenableBuilder(
              valueListenable: client.requestLog,
              builder: (context, log, _) => log.isEmpty
                  ? EmptyView(icon: Icons.receipt_long_outlined, title: context.tr('No requests yet', '还没有请求'))
                  : ListView.separated(
                      itemCount: log.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = log[i];
                        final ok = r.statusCode != null && r.statusCode! < 400;
                        return ListTile(
                          dense: true,
                          leading: MethodBadge(r.method, small: true),
                          title: Text(r.url.replaceFirst('https://api.cloudflare.com/client/v4', ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                          subtitle: Text('${formatDate(r.at.toIso8601String())} · ${r.duration.inMilliseconds} ms${r.error != null ? ' · ${r.error}' : ''}'),
                          trailing: StatusChip('${r.statusCode ?? 'ERR'}', tone: ok ? Tone.good : Tone.bad),
                        );
                      },
                    ),
            ),
    );
  }
}

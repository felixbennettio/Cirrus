import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/format.dart';
import '../../core/util/tr.dart';
import '../../ui/widgets/async_view.dart';
import '../../ui/widgets/charts.dart';
import '../../ui/widgets/common.dart';
import 'analytics_api.dart';

class ZoneAnalyticsPage extends ConsumerStatefulWidget {
  const ZoneAnalyticsPage({super.key});

  @override
  ConsumerState<ZoneAnalyticsPage> createState() => _ZoneAnalyticsPageState();
}

class _ZoneAnalyticsPageState extends ConsumerState<ZoneAnalyticsPage> {
  String _range = '7d';

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: context.tr('Analytics', '分析'),
      actions: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: '24h', label: Text('24h')),
            ButtonSegment(value: '7d', label: Text('7d')),
            ButtonSegment(value: '30d', label: Text('30d')),
          ],
          selected: {_range},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (s) => setState(() => _range = s.first),
        ),
      ],
      body: ZoneRequired(
        builder: (context, zoneId, zone) => ApiQuery<ZoneTraffic>(
          cacheKey: 'analytics:$zoneId:$_range',
          load: (c) => _range == '24h'
              ? fetchZoneTraffic(c, zoneId, hours: 24)
              : fetchZoneTraffic(c, zoneId, days: _range == '7d' ? 7 : 30),
          builder: (context, t, handle) => ZoneTrafficView(traffic: t, onRefresh: handle.reload),
        ),
      ),
    );
  }
}

class ZoneTrafficView extends StatelessWidget {
  const ZoneTrafficView({super.key, required this.traffic, this.onRefresh});

  final ZoneTraffic traffic;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labels = traffic.points.map((p) => p.label).toList();
    return ContentList(
      onRefresh: onRefresh,
      children: [
        ResponsiveGrid(
          minItemWidth: 170,
          children: [
            StatTile(label: context.tr('Requests', '请求数'), value: formatCount(traffic.requests), icon: Icons.swap_vert),
            StatTile(
              label: context.tr('Cached', '缓存命中'),
              value: '${(traffic.cacheRatio * 100).toStringAsFixed(1)}%',
              icon: Icons.cached,
              sub: formatCount(traffic.cachedRequests),
            ),
            StatTile(label: context.tr('Bandwidth', '带宽'), value: formatBytes(traffic.bytes), icon: Icons.data_usage, sub: '${context.tr('cached', '缓存')} ${formatBytes(traffic.cachedBytes)}'),
            StatTile(label: context.tr('Unique visitors', '独立访客'), value: formatCount(traffic.uniques), icon: Icons.people_outline),
            StatTile(label: context.tr('Page views', '页面浏览'), value: formatCount(traffic.pageViews), icon: Icons.visibility_outlined),
            StatTile(label: context.tr('Threats', '威胁'), value: formatCount(traffic.threats), icon: Icons.gpp_maybe_outlined),
          ],
        ),
        const SizedBox(height: 12),
        if (traffic.points.isEmpty)
          EmptyView(icon: Icons.bar_chart, title: context.tr('No data for this period', '该时间段没有数据'))
        else ...[
          SectionCard(
            title: context.tr('Requests', '请求'),
            children: [
              TimeSeriesChart(
                labels: labels,
                format: (v) => formatCount(v),
                series: [
                  ChartSeries(name: context.tr('Total', '总计'), values: traffic.points.map((p) => p.requests).toList(), color: scheme.primary),
                  ChartSeries(name: context.tr('Cached', '已缓存'), values: traffic.points.map((p) => p.cachedRequests).toList(), color: Colors.teal),
                ],
              ),
            ],
          ),
          SectionCard(
            title: context.tr('Bandwidth', '带宽'),
            children: [
              TimeSeriesChart(
                labels: labels,
                format: (v) => formatBytes(v, decimals: 0),
                series: [
                  ChartSeries(name: context.tr('Total', '总计'), values: traffic.points.map((p) => p.bytes).toList(), color: Colors.indigo),
                  ChartSeries(name: context.tr('Cached', '已缓存'), values: traffic.points.map((p) => p.cachedBytes).toList(), color: Colors.teal),
                ],
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, c) {
              final status = SectionCard(
                title: context.tr('Status codes', '状态码'),
                children: [TopList(items: topN(traffic.statusCodes), format: formatCount)],
              );
              final countries = SectionCard(
                title: context.tr('Top countries', '主要国家/地区'),
                children: [TopList(items: topN(traffic.countries), format: formatCount, color: Colors.teal)],
              );
              if (c.maxWidth < 760) return Column(children: [status, countries]);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Expanded(child: status), const SizedBox(width: 12), Expanded(child: countries)],
              );
            },
          ),
        ],
      ],
    );
  }
}

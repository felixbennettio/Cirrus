import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class ChartSeries {
  const ChartSeries({required this.name, required this.values, required this.color});

  final String name;
  final List<double> values;
  final Color color;
}

/// Line/area chart for time series with shared x labels.
class TimeSeriesChart extends StatelessWidget {
  const TimeSeriesChart({super.key, required this.labels, required this.series, this.height = 220, this.format});

  final List<String> labels;
  final List<ChartSeries> series;
  final double height;
  final String Function(double v)? format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = format ?? (v) => v.toStringAsFixed(0);
    final maxY = series.expand((s) => s.values).fold<double>(0, math.max);
    final step = math.max(1, (labels.length / 6).ceil());
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.only(right: 12, top: 8),
        child: LineChart(
          LineChartData(
            minY: 0,
            maxY: maxY <= 0 ? 1 : maxY * 1.15,
            gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) =>
                  FlLine(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4), strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 52,
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text(fmt(v), style: theme.textTheme.labelSmall),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  interval: 1,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= labels.length || i % step != 0) return const SizedBox();
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(labels[i], style: theme.textTheme.labelSmall),
                    );
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem(
                      '${s.barIndex == 0 ? '${labels[s.x.toInt()]}\n' : ''}${series[s.barIndex].name}: ${fmt(s.y)}',
                      TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                    ),
                ],
              ),
            ),
            lineBarsData: [
              for (final s in series)
                LineChartBarData(
                  spots: [for (var i = 0; i < s.values.length; i++) FlSpot(i.toDouble(), s.values[i])],
                  color: s.color,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  barWidth: 2.2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: true, color: s.color.withValues(alpha: 0.12)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal bar list for "top N" breakdowns.
class TopList extends StatelessWidget {
  const TopList({super.key, required this.items, this.format, this.color});

  final List<(String, double)> items;
  final String Function(double v)? format;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxV = items.fold<double>(0, (m, e) => math.max(m, e.$2));
    final fmt = format ?? (v) => v.toStringAsFixed(0);
    return Column(
      children: [
        for (final (label, v) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 110, child: Text(label, overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : v / maxV,
                      minHeight: 10,
                      color: color ?? theme.colorScheme.primary,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(fmt(v), textAlign: TextAlign.right, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

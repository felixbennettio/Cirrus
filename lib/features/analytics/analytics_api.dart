import 'package:intl/intl.dart';

import '../../core/api/cf_client.dart';

class TrafficPoint {
  TrafficPoint({
    required this.label,
    required this.requests,
    required this.cachedRequests,
    required this.bytes,
    required this.cachedBytes,
    required this.threats,
    required this.pageViews,
    required this.uniques,
  });

  final String label;
  final double requests;
  final double cachedRequests;
  final double bytes;
  final double cachedBytes;
  final double threats;
  final double pageViews;
  final double uniques;
}

class ZoneTraffic {
  ZoneTraffic({required this.points, required this.statusCodes, required this.countries});

  final List<TrafficPoint> points;
  final Map<String, double> statusCodes;
  final Map<String, double> countries;

  double _sum(double Function(TrafficPoint) f) => points.fold(0, (a, p) => a + f(p));
  double get requests => _sum((p) => p.requests);
  double get cachedRequests => _sum((p) => p.cachedRequests);
  double get bytes => _sum((p) => p.bytes);
  double get cachedBytes => _sum((p) => p.cachedBytes);
  double get threats => _sum((p) => p.threats);
  double get pageViews => _sum((p) => p.pageViews);
  double get uniques => points.isEmpty ? 0 : points.map((p) => p.uniques).reduce((a, b) => a > b ? a : b);
  double get cacheRatio => requests == 0 ? 0 : cachedRequests / requests;
}

const _fields = '''
        sum {
          requests
          cachedRequests
          bytes
          cachedBytes
          threats
          pageViews
          responseStatusMap { edgeResponseStatus requests }
          countryMap { clientCountryName requests }
        }
        uniq { uniques }
''';

const zoneDailyQuery =
    '''
query ZoneDaily(\$zoneTag: string, \$since: Date, \$until: Date) {
  viewer {
    zones(filter: { zoneTag: \$zoneTag }) {
      httpRequests1dGroups(limit: 92, filter: { date_geq: \$since, date_leq: \$until }, orderBy: [date_ASC]) {
        dimensions { date }
$_fields
      }
    }
  }
}''';

const zoneHourlyQuery =
    '''
query ZoneHourly(\$zoneTag: string, \$since: Time, \$until: Time) {
  viewer {
    zones(filter: { zoneTag: \$zoneTag }) {
      httpRequests1hGroups(limit: 72, filter: { datetime_geq: \$since, datetime_lt: \$until }, orderBy: [datetime_ASC]) {
        dimensions { datetime }
$_fields
      }
    }
  }
}''';

double _d(Object? v) => v is num ? v.toDouble() : 0;

/// Zone HTTP traffic. `hours <= 48` uses hourly groups, otherwise daily.
Future<ZoneTraffic> fetchZoneTraffic(CfClient c, String zoneId, {int days = 7, int? hours}) async {
  final now = DateTime.now().toUtc();
  final hourly = hours != null;
  final Map<String, dynamic> data;
  if (hourly) {
    final until = DateTime.utc(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
    data = await c.graphql(
      zoneHourlyQuery,
      variables: {
        'zoneTag': zoneId,
        'since': until.subtract(Duration(hours: hours)).toIso8601String(),
        'until': until.toIso8601String(),
      },
    );
  } else {
    final fmt = DateFormat('yyyy-MM-dd');
    data = await c.graphql(
      zoneDailyQuery,
      variables: {
        'zoneTag': zoneId,
        'since': fmt.format(now.subtract(Duration(days: days - 1))),
        'until': fmt.format(now),
      },
    );
  }
  final zones = (data['viewer'] as Map?)?['zones'] as List? ?? const [];
  final groups = zones.isEmpty
      ? const []
      : ((zones.first as Map)[hourly ? 'httpRequests1hGroups' : 'httpRequests1dGroups'] as List? ?? const []);
  final status = <String, double>{};
  final countries = <String, double>{};
  final points = <TrafficPoint>[];
  for (final g in groups.cast<Map>()) {
    final dims = g['dimensions'] as Map? ?? const {};
    final sum = g['sum'] as Map? ?? const {};
    final raw = (hourly ? dims['datetime'] : dims['date'])?.toString() ?? '';
    String label = raw;
    final dt = DateTime.tryParse(raw);
    if (dt != null) {
      label = hourly ? DateFormat('HH:mm').format(dt.toLocal()) : DateFormat('MM-dd').format(dt);
    }
    points.add(
      TrafficPoint(
        label: label,
        requests: _d(sum['requests']),
        cachedRequests: _d(sum['cachedRequests']),
        bytes: _d(sum['bytes']),
        cachedBytes: _d(sum['cachedBytes']),
        threats: _d(sum['threats']),
        pageViews: _d(sum['pageViews']),
        uniques: _d((g['uniq'] as Map?)?['uniques']),
      ),
    );
    for (final s in (sum['responseStatusMap'] as List? ?? const []).cast<Map>()) {
      final k = '${s['edgeResponseStatus']}';
      status[k] = (status[k] ?? 0) + _d(s['requests']);
    }
    for (final s in (sum['countryMap'] as List? ?? const []).cast<Map>()) {
      final k = '${s['clientCountryName']}';
      countries[k] = (countries[k] ?? 0) + _d(s['requests']);
    }
  }
  return ZoneTraffic(points: points, statusCodes: status, countries: countries);
}

List<(String, double)> topN(Map<String, double> m, [int n = 10]) {
  final list = m.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  return list.take(n).toList();
}

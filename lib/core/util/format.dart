import 'dart:convert';

import 'package:intl/intl.dart';

String formatBytes(num? bytes, {int decimals = 1}) {
  if (bytes == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v.abs() >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : decimals)} ${units[i]}';
}

String formatCount(num? n) {
  if (n == null) return '—';
  return NumberFormat.compact().format(n);
}

String formatNumber(num? n) {
  if (n == null) return '—';
  return NumberFormat.decimalPattern().format(n);
}

DateTime? parseDate(Object? v) {
  if (v is DateTime) return v;
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  if (v is num) {
    // Seconds or milliseconds since epoch.
    final ms = v > 1e12 ? v.toInt() : (v * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  return null;
}

String formatDate(Object? v, {bool withTime = true}) {
  final d = parseDate(v);
  if (d == null) return v?.toString() ?? '—';
  final local = d.toLocal();
  return withTime ? DateFormat('yyyy-MM-dd HH:mm').format(local) : DateFormat('yyyy-MM-dd').format(local);
}

String formatRelative(Object? v, {bool zh = false}) {
  final d = parseDate(v);
  if (d == null) return v?.toString() ?? '—';
  final diff = DateTime.now().difference(d);
  final future = diff.isNegative;
  final a = diff.abs();
  String unit;
  if (a.inSeconds < 60) {
    return zh ? '刚刚' : 'just now';
  } else if (a.inMinutes < 60) {
    unit = zh ? '${a.inMinutes} 分钟' : '${a.inMinutes}m';
  } else if (a.inHours < 24) {
    unit = zh ? '${a.inHours} 小时' : '${a.inHours}h';
  } else if (a.inDays < 30) {
    unit = zh ? '${a.inDays} 天' : '${a.inDays}d';
  } else if (a.inDays < 365) {
    unit = zh ? '${a.inDays ~/ 30} 个月' : '${a.inDays ~/ 30}mo';
  } else {
    unit = zh ? '${a.inDays ~/ 365} 年' : '${a.inDays ~/ 365}y';
  }
  if (zh) return future ? '$unit后' : '$unit前';
  return future ? 'in $unit' : '$unit ago';
}

String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

/// Fills `{account_id}`, `{zone_id}` and friends in an API path template.
String expandPath(String template, Map<String, String?> ids) {
  return template.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
    final key = m.group(1)!;
    final v =
        ids[key] ??
        switch (key) {
          'account_identifier' || 'account_tag' => ids['account_id'],
          'zone_identifier' || 'zone_tag' => ids['zone_id'],
          _ => null,
        };
    return v == null ? m.group(0)! : Uri.encodeComponent(v);
  });
}

/// Reads a nested value from decoded JSON using a dotted path (`a.b.0.c`).
Object? pick(Object? json, String path) {
  Object? cur = json;
  for (final part in path.split('.')) {
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}

String str(Object? v, [String fallback = '—']) {
  if (v == null) return fallback;
  if (v is String) return v.isEmpty ? fallback : v;
  return v.toString();
}

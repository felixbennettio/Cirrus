import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// In-memory cache of API results used for stale-while-revalidate:
/// screens render the last known data instantly and refresh in the
/// background.
class QueryCache {
  QueryCache._();

  static final QueryCache instance = QueryCache._();

  final Map<String, ({DateTime at, Object? data})> _entries = {};

  ({DateTime at, Object? data})? read(String key) => _entries[key];

  void write(String key, Object? data) {
    _entries[key] = (at: DateTime.now(), data: data);
    if (_entries.length > 400) {
      final oldest = _entries.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in oldest.take(100)) {
        _entries.remove(e.key);
      }
    }
  }

  /// Drops every entry whose key contains [fragment].
  void invalidate(String fragment) {
    _entries.removeWhere((k, _) => k.contains(fragment));
  }

  void clear() => _entries.clear();
}

/// Small JSON file cache used to make app start instant (accounts, zones).
class DiskCache {
  DiskCache._();

  static Directory? _dir;

  static Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}cache');
    await d.create(recursive: true);
    return _dir = d;
  }

  static Future<File> _file(String key) async {
    final name = sha1.convert(utf8.encode(key)).toString();
    return File('${(await _root()).path}${Platform.pathSeparator}$name.json');
  }

  static Future<Object?> read(String key) async {
    try {
      final f = await _file(key);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, Object? value) async {
    try {
      final f = await _file(key);
      await f.writeAsString(jsonEncode(value));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final d = await _root();
      if (await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }
}

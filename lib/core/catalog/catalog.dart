import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A parameter of an [ApiOperation].
class ApiParam {
  const ApiParam({
    required this.name,
    required this.location,
    required this.required,
    this.schema,
    this.description,
  });

  factory ApiParam.fromJson(Map<String, dynamic> j) => ApiParam(
    name: j['n'] as String,
    location: j['in'] as String,
    required: j['r'] == true,
    schema: j['s'] as Map<String, dynamic>?,
    description: j['d'] as String?,
  );

  final String name;

  /// `path`, `query`, `header` or `cookie`.
  final String location;
  final bool required;
  final Map<String, dynamic>? schema;
  final String? description;
}

/// Request body description of an [ApiOperation].
class ApiBody {
  const ApiBody({
    required this.contentType,
    this.alternatives = const [],
    this.required = false,
    this.schema,
  });

  factory ApiBody.fromJson(Map<String, dynamic> j) => ApiBody(
    contentType: j['ct'] as String,
    alternatives: (j['alt'] as List?)?.cast<String>() ?? const [],
    required: j['r'] == true,
    schema: j['s'] as Map<String, dynamic>?,
  );

  final String contentType;
  final List<String> alternatives;
  final bool required;
  final Map<String, dynamic>? schema;

  bool get isJson => contentType.contains('json');
  bool get isMultipart => contentType.startsWith('multipart/');
}

/// One endpoint of the Cloudflare API.
class ApiOperation {
  ApiOperation({
    required this.id,
    required this.method,
    required this.path,
    required this.summary,
    required this.group,
    this.description,
    this.methodName,
    this.tag,
    this.permissions = const [],
    this.plans = const [],
    this.deprecated = false,
    this.availability,
    this.auth = const [],
    this.params = const [],
    this.body,
  });

  factory ApiOperation.fromJson(Map<String, dynamic> j) => ApiOperation(
    id: j['id'] as String,
    method: j['m'] as String,
    path: j['p'] as String,
    summary: j['s'] as String? ?? '',
    description: j['d'] as String?,
    group: j['g'] as String? ?? 'misc',
    methodName: j['n'] as String?,
    tag: j['t'] as String?,
    permissions: (j['perm'] as List?)?.cast<String>() ?? const [],
    plans: (j['plan'] as List?)?.cast<String>() ?? const [],
    deprecated: j['dep'] == true,
    availability: j['av'] as String?,
    auth: (j['auth'] as List?)?.cast<String>() ?? const [],
    params: [
      for (final p in (j['params'] as List? ?? const []))
        ApiParam.fromJson(p as Map<String, dynamic>),
    ],
    body: j['body'] == null ? null : ApiBody.fromJson(j['body'] as Map<String, dynamic>),
  );

  final String id;
  final String method;
  final String path;
  final String summary;
  final String? description;

  /// SDK group such as `dns.records` or `zero_trust.access.applications`.
  final String group;
  final String? methodName;
  final String? tag;

  /// Required API token permission groups, e.g. `DNS Write`.
  final List<String> permissions;
  final List<String> plans;
  final bool deprecated;
  final String? availability;
  final List<String> auth;
  final List<ApiParam> params;
  final ApiBody? body;

  String get product => group.split('.').first;

  bool get isMutation => method != 'GET';

  Iterable<ApiParam> get pathParams => params.where((p) => p.location == 'path');
  Iterable<ApiParam> get queryParams => params.where((p) => p.location == 'query');
  Iterable<ApiParam> get headerParams => params.where((p) => p.location == 'header');

  bool get isAccountScoped => path.startsWith('/accounts/{');
  bool get isZoneScoped => path.startsWith('/zones/{');

  late final RegExp _matcher = RegExp(
    '^${path.split('/').map((s) => s.startsWith('{') ? '[^/]+' : RegExp.escape(s)).join('/')}\$',
  );

  bool matches(String method, String concretePath) =>
      method.toUpperCase() == this.method && _matcher.hasMatch(concretePath.split('?').first);

  late final String _haystack =
      '${method.toLowerCase()} $path $summary $group ${tag ?? ''} ${methodName ?? ''} $id'
          .toLowerCase();

  /// Scores how well this operation matches all [terms] (0 = no match).
  int score(List<String> terms) {
    var total = 0;
    for (final t in terms) {
      if (!_haystack.contains(t)) return 0;
      if (summary.toLowerCase().contains(t)) total += 3;
      if (group.toLowerCase().contains(t)) total += 2;
      total += 1;
    }
    if (deprecated) total -= 1;
    return total;
  }
}

/// The bundled (or refreshed) index of every Cloudflare API endpoint.
class ApiCatalog {
  ApiCatalog({
    required this.operations,
    required this.schemas,
    this.generated,
    this.apiVersion,
  });

  factory ApiCatalog.fromJson(Map<String, dynamic> json) => ApiCatalog(
    operations: [
      for (final o in json['ops'] as List) ApiOperation.fromJson(o as Map<String, dynamic>),
    ],
    schemas: Map<String, dynamic>.from(json['schemas'] as Map? ?? const {}),
    generated: DateTime.tryParse(json['generated'] as String? ?? ''),
    apiVersion: json['apiVersion'] as String?,
  );

  final List<ApiOperation> operations;
  final Map<String, dynamic> schemas;
  final DateTime? generated;
  final String? apiVersion;

  late final Map<String, ApiOperation> _byId = {for (final o in operations) o.id: o};

  late final Map<String, List<ApiOperation>> byProduct = () {
    final m = <String, List<ApiOperation>>{};
    for (final o in operations) {
      (m[o.product] ??= []).add(o);
    }
    return Map.fromEntries(m.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }();

  ApiOperation? byId(String id) => _byId[id];

  ApiOperation? find(String method, String concretePath) {
    final path = concretePath.split('?').first;
    ApiOperation? best;
    for (final o in operations) {
      if (o.matches(method, path)) {
        // Prefer the template with the most literal segments.
        if (best == null || _literalCount(o.path) > _literalCount(best.path)) best = o;
      }
    }
    return best;
  }

  static int _literalCount(String p) => p.split('/').where((s) => !s.startsWith('{')).length;

  List<ApiOperation> search(String query, {int limit = 200}) {
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return operations.take(limit).toList();
    final scored = <(int, ApiOperation)>[];
    for (final o in operations) {
      final s = o.score(terms);
      if (s > 0) scored.add((s, o));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((e) => e.$2).toList();
  }

  /// Follows `$ref`s and merges `allOf` so callers get a concrete schema.
  Map<String, dynamic> resolve(Map<String, dynamic>? schema, {int depth = 0}) {
    if (schema == null) return const {};
    var s = schema;
    var guard = 0;
    while (s[r'$ref'] is String && guard++ < 16) {
      final target = schemas[s[r'$ref']];
      if (target is! Map<String, dynamic>) return const {};
      s = target;
    }
    final allOf = s['allOf'];
    if (allOf is List && depth < 12) {
      final merged = <String, dynamic>{...s}..remove('allOf');
      final props = <String, dynamic>{...?(s['properties'] as Map<String, dynamic>?)};
      final required = <String>{...?(s['required'] as List?)?.cast<String>()};
      for (final part in allOf) {
        final r = resolve(part as Map<String, dynamic>, depth: depth + 1);
        props.addAll(Map<String, dynamic>.from(r['properties'] as Map? ?? const {}));
        required.addAll((r['required'] as List?)?.cast<String>() ?? const []);
        for (final k in const ['type', 'description', 'enum', 'items', 'oneOf', 'anyOf', 'format']) {
          if (!merged.containsKey(k) && r.containsKey(k)) merged[k] = r[k];
        }
      }
      if (props.isNotEmpty) {
        merged['properties'] = props;
        merged['type'] ??= 'object';
      }
      if (required.isNotEmpty) merged['required'] = required.toList();
      return merged;
    }
    return s;
  }

  /// Generates an example JSON value for [schema], used to pre-fill request
  /// bodies in the API console.
  Object? skeleton(Map<String, dynamic>? schema, {int depth = 0, bool requiredOnly = false}) {
    if (schema == null || depth > 6) return null;
    final s = resolve(schema);
    if (s['example'] != null) return s['example'];
    if (s['default'] != null) return s['default'];
    if (s['enum'] is List && (s['enum'] as List).isNotEmpty) return (s['enum'] as List).first;
    final variants = (s['oneOf'] ?? s['anyOf']) as List?;
    if (variants != null && variants.isNotEmpty) {
      return skeleton(variants.first as Map<String, dynamic>, depth: depth + 1, requiredOnly: requiredOnly);
    }
    final type = s['type'] ?? (s['properties'] != null ? 'object' : null);
    switch (type) {
      case 'object':
        final props = s['properties'] as Map<String, dynamic>? ?? const {};
        final req = (s['required'] as List?)?.cast<String>().toSet() ?? const <String>{};
        final out = <String, dynamic>{};
        for (final e in props.entries) {
          final ps = resolve(e.value as Map<String, dynamic>);
          if (ps['readOnly'] == true) continue;
          if ((requiredOnly || depth > 0) && !req.contains(e.key) && req.isNotEmpty) continue;
          out[e.key] = skeleton(e.value as Map<String, dynamic>, depth: depth + 1, requiredOnly: requiredOnly);
        }
        return out;
      case 'array':
        final item = skeleton(s['items'] as Map<String, dynamic>?, depth: depth + 1, requiredOnly: requiredOnly);
        return item == null ? [] : [item];
      case 'integer':
      case 'number':
        return s['minimum'] ?? 0;
      case 'boolean':
        return false;
      case 'string':
        return switch (s['format']) {
          'date-time' => DateTime.now().toUtc().toIso8601String(),
          'email' => 'user@example.com',
          'uri' || 'url' => 'https://example.com',
          _ => '',
        };
    }
    return null;
  }
}

/// Loads the API catalog: a refreshed copy in app support (if present),
/// otherwise the bundled asset. Decoding runs on a background isolate.
class CatalogLoader {
  static const asset = 'assets/api/catalog.json.gz';

  static Future<File> _localFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}catalog.json.gz');
  }

  static Future<ApiCatalog> load() async {
    Uint8List? bytes;
    try {
      final f = await _localFile();
      if (await f.exists()) bytes = await f.readAsBytes();
    } catch (_) {}
    if (bytes == null) {
      final data = await rootBundle.load(asset);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final input = bytes;
    return Isolate.run(() => decode(input));
  }

  static ApiCatalog decode(Uint8List gz) {
    final json = jsonDecode(utf8.decode(gzip.decode(gz))) as Map<String, dynamic>;
    return ApiCatalog.fromJson(json);
  }

  /// Saves a freshly built catalog so it is used on the next load.
  static Future<void> saveRefreshed(Map<String, dynamic> catalog) async {
    final f = await _localFile();
    await f.parent.create(recursive: true);
    await f.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(catalog))));
  }

  static Future<void> resetToBundled() async {
    final f = await _localFile();
    if (await f.exists()) await f.delete();
  }
}

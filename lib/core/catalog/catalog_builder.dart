// Reduces the official Cloudflare OpenAPI document to the compact catalog
// bundled with Cirrus. Pure Dart: used by tool/build_catalog.dart and by the
// in-app "refresh API catalog" action.

const openApiSchemaUrl =
    'https://raw.githubusercontent.com/cloudflare/api-schemas/main/openapi.json';
const _methods = ['get', 'post', 'put', 'patch', 'delete'];
const _maxOpDescription = 900;
const _maxSchemaDescription = 240;

/// Builds the compact catalog from a decoded OpenAPI document.
Map<String, dynamic> buildCatalog(Map<String, dynamic> doc) {
  final components = (doc['components'] as Map<String, dynamic>?) ?? {};
  final schemas = (components['schemas'] as Map<String, dynamic>?) ?? {};
  final parameters = (components['parameters'] as Map<String, dynamic>?) ?? {};
  final requestBodies =
      (components['requestBodies'] as Map<String, dynamic>?) ?? {};
  final paths = doc['paths'] as Map<String, dynamic>;

  final referenced = <String>{};
  final ops = <Map<String, dynamic>>[];

  Map<String, dynamic> resolveRef(
    Map<String, dynamic> node,
    Map<String, dynamic> pool,
  ) {
    var current = node;
    var guard = 0;
    while (current[r'$ref'] is String && guard++ < 8) {
      final name = (current[r'$ref'] as String).split('/').last;
      final next = pool[name];
      if (next is! Map<String, dynamic>) break;
      current = next;
    }
    return current;
  }

  for (final pathEntry in paths.entries) {
    final path = pathEntry.key;
    final item = pathEntry.value as Map<String, dynamic>;
    final shared = (item['parameters'] as List?) ?? const [];
    for (final method in _methods) {
      final op = item[method];
      if (op is! Map<String, dynamic>) continue;

      final params = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final p in [...(op['parameters'] as List? ?? const []), ...shared]) {
        final param = resolveRef(p as Map<String, dynamic>, parameters);
        final name = param['name'] as String?;
        final location = param['in'] as String?;
        if (name == null || location == null) continue;
        if (!seen.add('$location:$name')) continue;
        if (location == 'header' &&
            const {'x-auth-email', 'x-auth-key', 'authorization', 'x-auth-user-service-key'}
                .contains(name.toLowerCase())) {
          continue;
        }
        final schema = param['schema'] is Map<String, dynamic>
            ? _minSchema(param['schema'] as Map<String, dynamic>, referenced)
            : null;
        params.add({
          'n': name,
          'in': location,
          if (param['required'] == true || location == 'path') 'r': true,
          's': ?schema,
          'd': ?_text(param['description'], _maxSchemaDescription),
        });
      }

      Map<String, dynamic>? body;
      final rb = op['requestBody'];
      if (rb is Map<String, dynamic>) {
        final resolved = resolveRef(rb, requestBodies);
        final content = resolved['content'] as Map<String, dynamic>? ?? {};
        if (content.isNotEmpty) {
          final ct = content.containsKey('application/json')
              ? 'application/json'
              : content.keys.first;
          final media = content[ct] as Map<String, dynamic>? ?? {};
          body = {
            'ct': ct,
            if (content.length > 1) 'alt': content.keys.toList(),
            if (resolved['required'] == true) 'r': true,
            if (media['schema'] is Map<String, dynamic>)
              's': _minSchema(media['schema'] as Map<String, dynamic>, referenced),
          };
        }
      }

      final security = <String>{};
      for (final s in (op['security'] as List? ?? doc['security'] as List? ?? const [])) {
        if (s is Map) security.addAll(s.keys.cast<String>());
      }
      final plan = op['x-cfPlanAvailability'];
      final availability = op['x-fern-availability'];
      final tags = (op['tags'] as List?)?.cast<String>() ?? const <String>[];

      ops.add({
        'id': op['operationId'] ?? '$method $path',
        'm': method.toUpperCase(),
        'p': path,
        's': (op['summary'] as String?)?.trim() ?? '',
        'd': ?_text(op['description'], _maxOpDescription),
        'g': op['x-fern-sdk-group-name'] ?? _groupFromPath(path),
        if (op['x-fern-sdk-method-name'] case final String n) 'n': n,
        if (tags.isNotEmpty) 't': tags.first,
        if (op['x-api-token-group'] case final List perms when perms.isNotEmpty)
          'perm': perms.cast<String>(),
        if (plan is Map)
          'plan': [
            for (final e in plan.entries)
              if (e.value == true) e.key,
          ],
        if (op['deprecated'] == true ||
            op['x-stainless-deprecation-message'] != null ||
            op['x-cfDeprecation'] != null)
          'dep': true,
        if (availability is String && availability != 'generally-available')
          'av': availability,
        if (security.isNotEmpty) 'auth': security.toList()..sort(),
        if (params.isNotEmpty) 'params': params,
        'body': ?body,
      });
    }
  }

  // Pull in schemas referenced transitively.
  final out = <String, dynamic>{};
  final queue = [...referenced];
  while (queue.isNotEmpty) {
    final name = queue.removeLast();
    if (out.containsKey(name)) continue;
    final schema = schemas[name];
    if (schema is! Map<String, dynamic>) continue;
    final nested = <String>{};
    out[name] = _minSchema(schema, nested);
    queue.addAll(nested.where((n) => !out.containsKey(n)));
  }

  ops.sort((a, b) {
    final g = (a['g'] as String).compareTo(b['g'] as String);
    if (g != 0) return g;
    final p = (a['p'] as String).compareTo(b['p'] as String);
    if (p != 0) return p;
    return (a['m'] as String).compareTo(b['m'] as String);
  });

  return {
    'v': 1,
    'generated': DateTime.now().toUtc().toIso8601String(),
    'title': (doc['info'] as Map?)?['title'],
    'apiVersion': (doc['info'] as Map?)?['version'],
    'server': ((doc['servers'] as List?)?.first as Map?)?['url'] ??
        'https://api.cloudflare.com/client/v4',
    'ops': ops,
    'schemas': out,
  };
}

String _groupFromPath(String path) {
  final s = path.split('/').where((e) => e.isNotEmpty && !e.startsWith('{')).toList();
  if (s.length >= 2 && (s[0] == 'accounts' || s[0] == 'zones')) return s[1];
  return s.isEmpty ? 'misc' : s.first;
}

String? _text(Object? value, int max) {
  if (value is! String) return null;
  final t = value.trim();
  if (t.isEmpty) return null;
  if (t.length <= max) return t;
  final cut = t.substring(0, max);
  final lastBreak = cut.lastIndexOf(RegExp(r'[.\n]'));
  return '${lastBreak > max * 0.6 ? cut.substring(0, lastBreak + 1) : cut}…';
}

const _keepKeys = {
  'type',
  'format',
  'enum',
  'items',
  'properties',
  'required',
  'oneOf',
  'anyOf',
  'allOf',
  'description',
  'default',
  'example',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'minItems',
  'maxItems',
  'nullable',
  'readOnly',
  'writeOnly',
  'title',
  'additionalProperties',
  'const',
  'deprecated',
};

Object? _minSchema(Object? node, Set<String> refs) {
  if (node is List) return [for (final n in node) _minSchema(n, refs)];
  if (node is! Map<String, dynamic>) return node;
  final ref = node[r'$ref'];
  if (ref is String) {
    final name = ref.split('/').last;
    refs.add(name);
    return {r'$ref': name};
  }
  final out = <String, dynamic>{};
  for (final e in node.entries) {
    if (!_keepKeys.contains(e.key)) continue;
    switch (e.key) {
      case 'description':
        if (_text(e.value, _maxSchemaDescription) case final d?) out['description'] = d;
      case 'example' || 'default':
        // Keep only small scalar examples/defaults: they seed form fields.
        final v = e.value;
        if (v is num || v is bool || (v is String && v.length <= 120)) {
          out[e.key] = v;
        } else if (v is List && v.length <= 8 && v.every((x) => x is String || x is num)) {
          out[e.key] = v;
        }
      case 'properties':
        final props = e.value as Map<String, dynamic>;
        out['properties'] = {
          for (final p in props.entries) p.key: _minSchema(p.value, refs),
        };
      case 'items' || 'additionalProperties':
        out[e.key] = _minSchema(e.value, refs);
      case 'oneOf' || 'anyOf' || 'allOf':
        out[e.key] = [for (final s in e.value as List) _minSchema(s, refs)];
      default:
        out[e.key] = e.value;
    }
  }
  return out;
}

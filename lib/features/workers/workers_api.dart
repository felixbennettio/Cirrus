import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/api/cf_client.dart';
import '../../core/api/multipart.dart';

class WorkerModule {
  WorkerModule({required this.name, required this.contentType, required this.bytes});

  final String name;
  final String contentType;
  Uint8List bytes;

  bool get isText =>
      contentType.contains('javascript') ||
      contentType.contains('text') ||
      contentType.contains('json') ||
      name.endsWith('.js') ||
      name.endsWith('.mjs') ||
      name.endsWith('.ts') ||
      name.endsWith('.map') ||
      name.endsWith('.json') ||
      name.endsWith('.txt') ||
      name.endsWith('.html');

  String get text => utf8.decode(bytes, allowMalformed: true);
  set text(String v) => bytes = Uint8List.fromList(utf8.encode(v));
}

class WorkerContent {
  WorkerContent({required this.mainModule, required this.modules, required this.moduleSyntax});

  final String mainModule;
  final List<WorkerModule> modules;

  /// ES modules (`export default {}`) vs. legacy service-worker syntax.
  final bool moduleSyntax;

  WorkerModule get main => modules.firstWhere((m) => m.name == mainModule, orElse: () => modules.first);
}

String _ctFor(String name, bool moduleSyntax) {
  if (name.endsWith('.wasm')) return 'application/wasm';
  if (name.endsWith('.map')) return 'application/source-map';
  if (name.endsWith('.json')) return 'application/json';
  if (name.endsWith('.txt')) return 'text/plain';
  if (name.endsWith('.py')) return 'text/x-python';
  return moduleSyntax ? 'application/javascript+module' : 'application/javascript';
}

/// Downloads the current script content (all modules).
Future<WorkerContent> fetchWorkerContent(CfClient c, String accountId, String script) async {
  final r = await c.rawOk('GET', '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}/content/v2');
  final ct = r.header('content-type') ?? '';
  final entry = r.header('cf-entrypoint');
  final boundary = multipartBoundary(ct);
  if (boundary != null) {
    final parts = parseMultipart(r.bytes, boundary);
    final modules = [
      for (final p in parts)
        WorkerModule(
          name: p.filename ?? p.name ?? 'module',
          contentType: p.contentType ?? 'application/javascript+module',
          bytes: p.bytes,
        ),
    ];
    final main = entry ?? modules.firstOrNull?.name ?? 'worker.js';
    final mainModule = modules.where((m) => m.name == main).firstOrNull;
    final moduleSyntax = !(mainModule?.contentType == 'application/javascript' && !(mainModule?.text.contains('export ') ?? false));
    return WorkerContent(mainModule: main, modules: modules, moduleSyntax: moduleSyntax);
  }
  final name = entry ?? 'worker.js';
  final text = r.text;
  final moduleSyntax = text.contains('export default') || text.contains('export {');
  return WorkerContent(
    mainModule: name,
    moduleSyntax: moduleSyntax,
    modules: [WorkerModule(name: name, contentType: _ctFor(name, moduleSyntax), bytes: r.bytes)],
  );
}

FormData _scriptForm(Map<String, dynamic> metadata, List<WorkerModule> modules) {
  final form = FormData();
  form.files.add(MapEntry(
    'metadata',
    MultipartFile.fromString(jsonEncode(metadata), filename: 'metadata.json', contentType: DioMediaType('application', 'json')),
  ));
  for (final m in modules) {
    final ct = DioMediaType.parse(m.contentType.isEmpty ? 'application/octet-stream' : m.contentType);
    form.files.add(MapEntry(m.name, MultipartFile.fromBytes(m.bytes, filename: m.name, contentType: ct)));
  }
  return form;
}

/// Replaces the code only; bindings and settings are kept.
Future<void> uploadWorkerContent(CfClient c, String accountId, String script, WorkerContent content) async {
  final meta = content.moduleSyntax ? {'main_module': content.mainModule} : {'body_part': content.mainModule};
  await c.send(
    'PUT',
    '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}/content',
    data: _scriptForm(meta, content.modules),
  );
}

/// Creates (or fully replaces) a Worker from a single ES module.
Future<void> createWorker(CfClient c, String accountId, String script, String code, {String? compatibilityDate}) async {
  final date = compatibilityDate ?? DateFormat('yyyy-MM-dd').format(DateTime.now().toUtc());
  await c.send(
    'PUT',
    '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}',
    data: _scriptForm(
      {'main_module': 'worker.js', 'compatibility_date': date, 'bindings': <Object>[]},
      [WorkerModule(name: 'worker.js', contentType: 'application/javascript+module', bytes: Uint8List.fromList(utf8.encode(code)))],
    ),
  );
}

/// Patches script settings (multipart `settings` part).
Future<void> patchWorkerSettings(CfClient c, String accountId, String script, Map<String, dynamic> settings) async {
  final form = FormData();
  form.files.add(MapEntry(
    'settings',
    MultipartFile.fromString(jsonEncode(settings), filename: 'settings.json', contentType: DioMediaType('application', 'json')),
  ));
  await c.send('PATCH', '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}/settings', data: form);
}

const workerTemplates = <String, String>{
  'Hello World': '''export default {
  async fetch(request, env, ctx) {
    return new Response("Hello from Cirrus!", {
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
''',
  'JSON API router': '''export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    switch (`\${request.method} \${url.pathname}`) {
      case "GET /":
        return Response.json({ ok: true, time: new Date().toISOString() });
      case "GET /headers":
        return Response.json(Object.fromEntries(request.headers));
      case "POST /echo":
        return Response.json(await request.json());
      default:
        return Response.json({ error: "Not found" }, { status: 404 });
    }
  },
};
''',
  'Redirect': '''const REDIRECTS = new Map([
  ["/old", "https://example.com/new"],
]);

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = REDIRECTS.get(url.pathname);
    if (target) return Response.redirect(target, 301);
    return fetch(request);
  },
};
''',
  'Reverse proxy with cache': '''const ORIGIN = "https://example.com";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const upstream = new URL(url.pathname + url.search, ORIGIN);
    const response = await fetch(upstream, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    const res = new Response(response.body, response);
    res.headers.set("x-proxied-by", "cirrus-worker");
    return res;
  },
};
''',
  'Cron job': '''export default {
  async fetch() {
    return new Response("This Worker runs on a schedule.");
  },
  async scheduled(controller, env, ctx) {
    console.log("Cron fired at", new Date(controller.scheduledTime).toISOString(), controller.cron);
  },
};
''',
};

// ---------------------------------------------------------------------------
// Metrics

class WorkerMetricsPoint {
  WorkerMetricsPoint(this.at, this.requests, this.errors, this.subrequests, this.cpuP50, this.cpuP99);

  final DateTime at;
  final double requests;
  final double errors;
  final double subrequests;
  final double cpuP50;
  final double cpuP99;
}

const _scriptMetricsQuery = r'''
query WorkerMetrics($accountTag: string, $script: string, $since: Time, $until: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      workersInvocationsAdaptive(limit: 500, filter: { scriptName: $script, datetime_geq: $since, datetime_leq: $until }, orderBy: [datetimeHour_ASC]) {
        sum { requests errors subrequests }
        quantiles { cpuTimeP50 cpuTimeP99 }
        dimensions { datetimeHour }
      }
    }
  }
}''';

const _accountMetricsQuery = r'''
query WorkersSummary($accountTag: string, $since: Time, $until: Time) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      workersInvocationsAdaptive(limit: 2000, filter: { datetime_geq: $since, datetime_leq: $until }) {
        sum { requests errors }
        dimensions { scriptName }
      }
    }
  }
}''';

double _d(Object? v) => v is num ? v.toDouble() : 0;

Future<List<WorkerMetricsPoint>> fetchWorkerMetrics(CfClient c, String accountId, String script, {int hours = 24}) async {
  final now = DateTime.now().toUtc();
  final data = await c.graphql(_scriptMetricsQuery, variables: {
    'accountTag': accountId,
    'script': script,
    'since': now.subtract(Duration(hours: hours)).toIso8601String(),
    'until': now.toIso8601String(),
  });
  final accounts = (data['viewer'] as Map?)?['accounts'] as List? ?? const [];
  if (accounts.isEmpty) return const [];
  final rows = ((accounts.first as Map)['workersInvocationsAdaptive'] as List? ?? const []).cast<Map>();
  final byHour = <String, List<double>>{};
  for (final r in rows) {
    final h = '${(r['dimensions'] as Map?)?['datetimeHour']}';
    final s = r['sum'] as Map? ?? const {};
    final q = r['quantiles'] as Map? ?? const {};
    final cur = byHour[h] ?? [0, 0, 0, 0, 0];
    byHour[h] = [
      cur[0] + _d(s['requests']),
      cur[1] + _d(s['errors']),
      cur[2] + _d(s['subrequests']),
      cur[3] > _d(q['cpuTimeP50']) ? cur[3] : _d(q['cpuTimeP50']),
      cur[4] > _d(q['cpuTimeP99']) ? cur[4] : _d(q['cpuTimeP99']),
    ];
  }
  final keys = byHour.keys.toList()..sort();
  return [
    for (final k in keys)
      WorkerMetricsPoint(DateTime.tryParse(k) ?? now, byHour[k]![0], byHour[k]![1], byHour[k]![2], byHour[k]![3], byHour[k]![4]),
  ];
}

/// Requests and errors per script for the last 24 hours.
Future<Map<String, (double, double)>> fetchWorkersSummary(CfClient c, String accountId) async {
  final now = DateTime.now().toUtc();
  final data = await c.graphql(_accountMetricsQuery, variables: {
    'accountTag': accountId,
    'since': now.subtract(const Duration(hours: 24)).toIso8601String(),
    'until': now.toIso8601String(),
  });
  final accounts = (data['viewer'] as Map?)?['accounts'] as List? ?? const [];
  if (accounts.isEmpty) return const {};
  final out = <String, (double, double)>{};
  for (final r in ((accounts.first as Map)['workersInvocationsAdaptive'] as List? ?? const []).cast<Map>()) {
    final name = '${(r['dimensions'] as Map?)?['scriptName']}';
    final s = r['sum'] as Map? ?? const {};
    final cur = out[name] ?? (0, 0);
    out[name] = (cur.$1 + _d(s['requests']), cur.$2 + _d(s['errors']));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Live tail

/// A live `wrangler tail` style session over WebSocket.
class WorkerTailSession {
  WorkerTailSession._(this._client, this._path, this._id, this._channel);

  final CfClient _client;
  final String _path;
  final String _id;
  final WebSocketChannel _channel;

  static Future<WorkerTailSession> start(CfClient c, String accountId, String script) async {
    final path = '/accounts/$accountId/workers/scripts/${Uri.encodeComponent(script)}/tails';
    final r = await c.post(path) as Map;
    final url = r['url'] as String;
    final channel = IOWebSocketChannel.connect(
      Uri.parse(url),
      protocols: const ['trace-v1'],
      headers: {'User-Agent': 'Cirrus/$cirrusVersion'},
    );
    await channel.ready;
    channel.sink.add(jsonEncode({'debug': true}));
    return WorkerTailSession._(c, path, r['id'] as String, channel);
  }

  Stream<Map<String, dynamic>> get events => _channel.stream.map((e) {
    final text = e is String ? e : utf8.decode(e as List<int>);
    try {
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (_) {
      return <String, dynamic>{'raw': text};
    }
  });

  Future<void> close() async {
    await _channel.sink.close();
    try {
      await _client.delete('$_path/$_id');
    } catch (_) {}
  }
}

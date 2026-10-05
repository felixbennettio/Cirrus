import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/credential.dart';
import 'cf_exception.dart';

const cirrusVersion = '0.1.0';

/// Development-only override (`--dart-define=CIRRUS_API_BASE=...`), used to
/// run the app against a local mock server. Release builds never set it.
const _apiBaseOverride = String.fromEnvironment('CIRRUS_API_BASE');
const cfApiBase = _apiBaseOverride == '' ? 'https://api.cloudflare.com/client/v4' : _apiBaseOverride;
const isDevApiBase = _apiBaseOverride != '';

/// Parsed Cloudflare v4 envelope (or a raw non-envelope JSON body).
class CfResponse {
  const CfResponse({
    required this.statusCode,
    required this.result,
    this.resultInfo,
    this.messages = const [],
    this.headers = const {},
    this.raw,
    this.duration = Duration.zero,
  });

  final int statusCode;
  final dynamic result;
  final Map<String, dynamic>? resultInfo;
  final List<CfMessage> messages;
  final Map<String, List<String>> headers;
  final Object? raw;
  final Duration duration;
}

/// Raw response without envelope parsing (object downloads, scripts...).
class CfRawResponse {
  const CfRawResponse({required this.statusCode, required this.bytes, required this.headers, required this.duration});

  final int statusCode;
  final Uint8List bytes;
  final Map<String, List<String>> headers;
  final Duration duration;

  String? header(String name) => headers[name.toLowerCase()]?.firstOrNull;
  String get text => utf8.decode(bytes, allowMalformed: true);
  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// One page of a paginated list endpoint.
class CfPage {
  const CfPage({required this.items, this.page, this.perPage, this.totalPages, this.totalCount, this.cursor});

  final List<dynamic> items;
  final int? page;
  final int? perPage;
  final int? totalPages;
  final int? totalCount;
  final String? cursor;

  bool get hasMore {
    if (cursor != null && cursor!.isNotEmpty) return true;
    if (page != null && totalPages != null) return page! < totalPages!;
    if (perPage != null) return items.length >= perPage!;
    return false;
  }
}

/// A line in the in-app request log (never contains credentials).
class RequestRecord {
  RequestRecord({
    required this.method,
    required this.url,
    required this.statusCode,
    required this.duration,
    required this.at,
    this.error,
  });

  final String method;
  final String url;
  final int? statusCode;
  final Duration duration;
  final DateTime at;
  final String? error;
}

/// Thin, typed wrapper around the Cloudflare REST + GraphQL API.
class CfClient {
  CfClient(this.profile, {Dio? dio, this.baseUrl = cfApiBase}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 20)
      ..receiveTimeout = const Duration(seconds: 90)
      ..sendTimeout = const Duration(minutes: 10)
      ..validateStatus = ((_) => true)
      ..headers['User-Agent'] = 'Cirrus/$cirrusVersion';
  }

  final Profile profile;
  final String baseUrl;
  final Dio _dio;

  /// Recent requests, newest first.
  final ValueNotifier<List<RequestRecord>> requestLog = ValueNotifier(const []);

  Dio get dio => _dio;

  Uri resolve(String path, [Map<String, dynamic>? query]) {
    final url = path.startsWith('http') ? path : '$baseUrl$path';
    final uri = Uri.parse(url);
    if (query == null || query.isEmpty) return uri;
    final merged = <String, dynamic>{...uri.queryParametersAll};
    query.forEach((k, v) {
      if (v == null) return;
      if (v is Iterable) {
        merged[k] = v.map((e) => e.toString()).toList();
      } else {
        merged[k] = v.toString();
      }
    });
    return uri.replace(queryParameters: merged);
  }

  Map<String, String> _headers(String path, Map<String, String>? extra, bool originCa) {
    final useOriginCa = originCa || path.startsWith('/certificates');
    return {...profile.authHeaders(originCa: useOriginCa), ...?extra};
  }

  void _log(RequestRecord r) {
    final list = [r, ...requestLog.value];
    requestLog.value = list.length > 200 ? list.sublist(0, 200) : list;
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    String? contentType,
    Map<String, String>? headers,
    ResponseType responseType = ResponseType.json,
    bool originCa = false,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final uri = resolve(path, query);
    final isIdempotent = method == 'GET' || method == 'HEAD';
    var attempt = 0;
    while (true) {
      attempt++;
      final sw = Stopwatch()..start();
      try {
        final res = await _dio.requestUri<dynamic>(
          uri,
          data: data,
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
          options: Options(
            method: method,
            headers: _headers(path, headers, originCa),
            contentType:
                contentType ??
                (data is FormData
                    ? null
                    : data == null
                    ? null
                    : data is String || data is List<int> || data is Stream
                    ? null
                    : Headers.jsonContentType),
            responseType: responseType,
          ),
        );
        sw.stop();
        _log(
          RequestRecord(
            method: method,
            url: uri.replace(query: '').toString().replaceAll('?', ''),
            statusCode: res.statusCode,
            duration: sw.elapsed,
            at: DateTime.now(),
          ),
        );
        final status = res.statusCode ?? 0;
        final retryable = status == 429 || (isIdempotent && status >= 500);
        if (retryable && attempt <= 3) {
          await Future<void>.delayed(_retryDelay(res, attempt));
          continue;
        }
        return res;
      } on DioException catch (e) {
        sw.stop();
        _log(
          RequestRecord(
            method: method,
            url: uri.replace(query: '').toString().replaceAll('?', ''),
            statusCode: null,
            duration: sw.elapsed,
            at: DateTime.now(),
            error: e.message ?? e.type.name,
          ),
        );
        if (e.type == DioExceptionType.cancel) rethrow;
        final transient =
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout;
        if (isIdempotent && transient && attempt <= 2) {
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          continue;
        }
        throw CfApiException(method: method, path: path, cause: e.error ?? e.message ?? e.type.name);
      }
    }
  }

  Duration _retryDelay(Response<dynamic> res, int attempt) {
    final ra = res.headers.value('retry-after');
    final secs = int.tryParse(ra ?? '');
    if (secs != null) return Duration(seconds: secs.clamp(1, 30));
    return Duration(milliseconds: 600 * (1 << (attempt - 1)));
  }

  /// Sends a request and parses the standard `{success, errors, result}`
  /// envelope. Throws [CfApiException] when the call fails.
  Future<CfResponse> send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    String? contentType,
    Map<String, String>? headers,
    bool originCa = false,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    final sw = Stopwatch()..start();
    final res = await _send(
      method,
      path,
      query: query,
      data: data,
      contentType: contentType,
      headers: headers,
      originCa: originCa,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
    sw.stop();
    return parseEnvelope(
      method: method,
      path: path,
      statusCode: res.statusCode ?? 0,
      body: res.data,
      headers: res.headers.map,
      duration: sw.elapsed,
    );
  }

  /// Exposed for tests.
  static CfResponse parseEnvelope({
    required String method,
    required String path,
    required int statusCode,
    required Object? body,
    Map<String, List<String>> headers = const {},
    Duration duration = Duration.zero,
  }) {
    var data = body;
    if (data is String && data.isNotEmpty) {
      final t = data.trimLeft();
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }
    }
    final ok = statusCode >= 200 && statusCode < 300;
    if (data is Map && data.containsKey('success') && (data.containsKey('result') || data.containsKey('errors'))) {
      final errors = (data['errors'] as List? ?? const []).map(CfMessage.fromJson).toList();
      final messages = (data['messages'] as List? ?? const []).map(CfMessage.fromJson).toList();
      if (data['success'] != true || !ok) {
        throw CfApiException(
          method: method,
          path: path,
          statusCode: statusCode,
          errors: errors.isEmpty ? messages : errors,
          body: errors.isEmpty && messages.isEmpty ? data : null,
        );
      }
      final info = data['result_info'];
      return CfResponse(
        statusCode: statusCode,
        result: data['result'],
        resultInfo: info is Map ? Map<String, dynamic>.from(info) : null,
        messages: messages,
        headers: headers,
        raw: data,
        duration: duration,
      );
    }
    if (data is Map &&
        data.containsKey('errors') &&
        data['errors'] is List &&
        (data['errors'] as List).isNotEmpty &&
        !data.containsKey('data')) {
      throw CfApiException(
        method: method,
        path: path,
        statusCode: statusCode,
        errors: (data['errors'] as List).map(CfMessage.fromJson).toList(),
      );
    }
    if (!ok) {
      throw CfApiException(method: method, path: path, statusCode: statusCode, body: data);
    }
    return CfResponse(statusCode: statusCode, result: data, headers: headers, raw: data, duration: duration);
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async =>
      (await send('GET', path, query: query)).result;

  Future<dynamic> post(String path, {Object? data, Map<String, dynamic>? query}) async =>
      (await send('POST', path, data: data, query: query)).result;

  Future<dynamic> put(String path, {Object? data, Map<String, dynamic>? query}) async =>
      (await send('PUT', path, data: data, query: query)).result;

  Future<dynamic> patch(String path, {Object? data, Map<String, dynamic>? query}) async =>
      (await send('PATCH', path, data: data, query: query)).result;

  Future<dynamic> delete(String path, {Object? data, Map<String, dynamic>? query}) async =>
      (await send('DELETE', path, data: data, query: query)).result;

  /// Fetches one page of a list endpoint. Handles both page/per_page and
  /// cursor based pagination.
  Future<CfPage> page(String path, {Map<String, dynamic>? query, int? page, int? perPage, String? cursor}) async {
    final res = await send(
      'GET',
      path,
      query: {
        ...?query,
        'page': ?page,
        'per_page': ?perPage,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    final info = res.resultInfo;
    final result = res.result;
    final items = switch (result) {
      final List l => l,
      final Map m when m['items'] is List => m['items'] as List,
      final Map m when m['objects'] is List => m['objects'] as List,
      final Map m when m['buckets'] is List => m['buckets'] as List,
      null => const <dynamic>[],
      _ => [result],
    };
    return CfPage(
      items: items,
      page: _int(info?['page']),
      perPage: _int(info?['per_page']) ?? perPage,
      totalPages: _int(info?['total_pages']),
      totalCount: _int(info?['total_count']),
      cursor:
          (info?['cursor'] as String?) ??
          (result is Map ? result['cursor'] as String? : null) ??
          (info?['cursors'] is Map ? (info!['cursors'] as Map)['after'] as String? : null),
    );
  }

  /// Fetches all pages of a list endpoint (bounded by [maxItems]).
  Future<List<Map<String, dynamic>>> list(
    String path, {
    Map<String, dynamic>? query,
    int perPage = 50,
    int maxItems = 5000,
    bool paginate = true,
    bool cursorPagination = false,
  }) async {
    final out = <Map<String, dynamic>>[];
    var pageNo = 1;
    String? cursor;
    while (true) {
      final p = await page(
        path,
        query: query,
        page: (paginate && !cursorPagination && cursor == null) ? pageNo : null,
        perPage: paginate ? perPage : null,
        cursor: cursor,
      );
      for (final item in p.items) {
        if (item is Map) out.add(Map<String, dynamic>.from(item));
      }
      if (!paginate || out.length >= maxItems || p.items.isEmpty) break;
      if (p.cursor != null && p.cursor!.isNotEmpty) {
        if (p.cursor == cursor) break;
        cursor = p.cursor;
        continue;
      }
      if (p.totalPages != null && p.page != null && p.page! < p.totalPages!) {
        pageNo++;
        continue;
      }
      break;
    }
    return out;
  }

  /// Raw request: returns bytes without envelope parsing.
  Future<CfRawResponse> raw(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    String? contentType,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final sw = Stopwatch()..start();
    final res = await _send(
      method,
      path,
      query: query,
      data: data,
      contentType: contentType,
      headers: headers,
      responseType: ResponseType.bytes,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
    sw.stop();
    final body = res.data;
    return CfRawResponse(
      statusCode: res.statusCode ?? 0,
      bytes: body is Uint8List
          ? body
          : body is List<int>
          ? Uint8List.fromList(body)
          : Uint8List(0),
      headers: res.headers.map,
      duration: sw.elapsed,
    );
  }

  /// Like [raw] but throws a [CfApiException] for non-2xx responses.
  Future<CfRawResponse> rawOk(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    String? contentType,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final r = await raw(
      method,
      path,
      query: query,
      data: data,
      contentType: contentType,
      headers: headers,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
    if (!r.ok) {
      // Re-use envelope parsing to extract structured errors.
      parseEnvelope(method: method, path: path, statusCode: r.statusCode, body: r.text);
    }
    return r;
  }

  /// Runs a query against the GraphQL Analytics API.
  Future<Map<String, dynamic>> graphql(String query, {Map<String, dynamic>? variables}) async {
    final res = await _send('POST', '/graphql', data: {'query': query, 'variables': variables ?? const {}});
    var body = res.data;
    if (body is String) body = jsonDecode(body);
    if (body is! Map) {
      throw CfApiException(method: 'POST', path: '/graphql', statusCode: res.statusCode, body: body);
    }
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw CfApiException(
        method: 'POST',
        path: '/graphql',
        statusCode: res.statusCode,
        errors: errors.map(CfMessage.fromJson).toList(),
      );
    }
    if ((res.statusCode ?? 0) >= 400) {
      throw CfApiException(method: 'POST', path: '/graphql', statusCode: res.statusCode, body: body);
    }
    return Map<String, dynamic>.from(body['data'] as Map? ?? const {});
  }

  /// Builds a copy-pasteable cURL command. Secrets are masked unless
  /// [includeSecrets] is set.
  String curl(String method, String path, {Map<String, dynamic>? query, Object? body, bool includeSecrets = false}) {
    final uri = resolve(path, query);
    final b = StringBuffer("curl -X $method '${uri.toString()}'");
    _headers(path, null, false).forEach((k, v) {
      final value = includeSecrets
          ? v
          : k == 'Authorization'
          ? r'Bearer $CLOUDFLARE_API_TOKEN'
          : k == 'X-Auth-Key'
          ? r'$CLOUDFLARE_API_KEY'
          : k == 'X-Auth-Email'
          ? r'$CLOUDFLARE_EMAIL'
          : r'$CLOUDFLARE_ORIGIN_CA_KEY';
      b.write(" \\\n  -H '$k: $value'");
    });
    if (body != null) {
      b.write(" \\\n  -H 'Content-Type: application/json'");
      final json = body is String ? body : const JsonEncoder.withIndent('  ').convert(body);
      b.write(" \\\n  --data '${json.replaceAll("'", r"'\''")}'");
    }
    return b.toString();
  }

  static int? _int(Object? v) => switch (v) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A recorded request.
class FakeCall {
  FakeCall(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Object? body;
}

typedef FakeHandler = (int, Object?, Map<String, List<String>>)? Function(String method, Uri uri, Object? body);

/// Minimal in-memory Cloudflare API for tests.
class FakeApi implements HttpClientAdapter {
  FakeApi(this.handler);

  final FakeHandler handler;
  final List<FakeCall> calls = [];

  static Map<String, dynamic> ok(Object? result, {Map<String, dynamic>? info}) => {
    'success': true,
    'errors': <Object>[],
    'messages': <Object>[],
    'result': result,
    'result_info': ?info,
  };

  static Map<String, dynamic> fail(int code, String message) => {
    'success': false,
    'errors': [
      {'code': code, 'message': message},
    ],
    'messages': <Object>[],
    'result': null,
  };

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Object? body = options.data;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {}
    }
    calls.add(FakeCall(options.method, options.uri, Map<String, dynamic>.from(options.headers), body));
    final r = handler(options.method, options.uri, body) ?? (404, fail(7003, 'No route for ${options.method} ${options.uri.path}'), const <String, List<String>>{});
    final (status, data, headers) = r;
    final bytes = data is Uint8List ? data : utf8.encode(data is String ? data : jsonEncode(data));
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: {
        'content-type': [data is Uint8List ? 'application/octet-stream' : 'application/json'],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

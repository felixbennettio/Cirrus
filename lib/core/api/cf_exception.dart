/// A single entry of the `errors` / `messages` arrays in a Cloudflare
/// API envelope.
class CfMessage {
  const CfMessage({required this.code, required this.message, this.chain = const []});

  factory CfMessage.fromJson(Object? json) {
    if (json is Map) {
      final chain = json['error_chain'];
      return CfMessage(
        code: switch (json['code']) {
          final int c => c,
          final String c => int.tryParse(c) ?? 0,
          _ => 0,
        },
        message: (json['message'] ?? json['msg'] ?? json.toString()).toString(),
        chain: chain is List ? chain.map(CfMessage.fromJson).toList() : const [],
      );
    }
    return CfMessage(code: 0, message: json?.toString() ?? '');
  }

  final int code;
  final String message;
  final List<CfMessage> chain;

  @override
  String toString() {
    final base = code == 0 ? message : '$message ($code)';
    if (chain.isEmpty) return base;
    return '$base: ${chain.join('; ')}';
  }
}

/// Thrown for any failed call to the Cloudflare API.
class CfApiException implements Exception {
  CfApiException({
    required this.method,
    required this.path,
    this.statusCode,
    this.errors = const [],
    this.body,
    this.cause,
  });

  final String method;
  final String path;
  final int? statusCode;
  final List<CfMessage> errors;

  /// Raw response body when it could not be parsed as an envelope.
  final Object? body;

  /// Underlying transport error (timeouts, DNS failures, TLS...).
  final Object? cause;

  bool get isAuthError => statusCode == 401 || errors.any((e) => e.code == 10000 || e.code == 9109);
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isRateLimited => statusCode == 429;
  bool get isNetworkError => statusCode == null && cause != null;

  String get summary {
    if (errors.isNotEmpty) return errors.join('\n');
    if (cause != null) return cause.toString();
    if (body is String && (body as String).isNotEmpty) {
      final s = body as String;
      return s.length > 400 ? '${s.substring(0, 400)}…' : s;
    }
    return 'HTTP ${statusCode ?? '-'}';
  }

  @override
  String toString() => '$method $path → ${statusCode ?? 'network error'}: $summary';
}

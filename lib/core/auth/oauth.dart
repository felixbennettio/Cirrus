import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// Cloudflare OAuth 2.0 for public (native) clients: Authorization Code
/// with PKCE (`S256`) and no client secret.
///
/// See https://developers.cloudflare.com/fundamentals/oauth/.
class OAuthConfig {
  const OAuthConfig({required this.clientId, required this.scopes});

  /// The client built into this binary, from
  /// `--dart-define=CIRRUS_OAUTH_CLIENT_ID=...` and
  /// `--dart-define=CIRRUS_OAUTH_SCOPES="account.read zone.read ..."`.
  /// Null when the build has no client configured.
  static OAuthConfig? get builtIn {
    const id = String.fromEnvironment('CIRRUS_OAUTH_CLIENT_ID');
    const scopes = String.fromEnvironment('CIRRUS_OAUTH_SCOPES');
    if (id.trim().isEmpty) return null;
    return OAuthConfig(clientId: id.trim(), scopes: parseScopes(scopes));
  }

  static const authorizeEndpoint = 'https://dash.cloudflare.com/oauth2/auth';
  static const tokenEndpoint = 'https://dash.cloudflare.com/oauth2/token';
  static const revokeEndpoint = 'https://dash.cloudflare.com/oauth2/revoke';

  /// Hydra only issues refresh tokens when this scope is requested.
  static const offlineScope = 'offline_access';

  final String clientId;

  /// Scope IDs as listed by `GET /oauth/scopes`, e.g. `zone.read`.
  final List<String> scopes;

  /// Scopes sent on the authorization request (always includes
  /// [offlineScope] so the session can be refreshed).
  List<String> get requestScopes => {...scopes, offlineScope}.toList();

  /// Splits a space- or comma-separated scope list.
  static List<String> parseScopes(String raw) =>
      raw.split(RegExp(r'[\s,]+')).map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
}

/// A PKCE verifier and its `S256` challenge (RFC 7636).
class Pkce {
  Pkce(this.verifier) : challenge = challengeFor(verifier);

  factory Pkce.generate([Random? random]) => Pkce(randomUrlSafe(64, random));

  final String verifier;
  final String challenge;

  static String challengeFor(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
}

/// Random string from the RFC 7636 unreserved character set.
String randomUrlSafe(int length, [Random? random]) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final r = random ?? Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}

/// Tokens returned by the token endpoint.
class OAuthTokens {
  const OAuthTokens({required this.accessToken, this.refreshToken, required this.expiresAt, this.scopes = const []});

  factory OAuthTokens.fromTokenResponse(Map<String, dynamic> json, {DateTime? now, String? previousRefreshToken}) {
    final access = json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const OAuthException('invalid_response', 'The token response did not contain an access token.');
    }
    final expiresIn = switch (json['expires_in']) {
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };
    return OAuthTokens(
      accessToken: access,
      // Hydra rotates refresh tokens; keep the old one only if no new one came back.
      refreshToken: (json['refresh_token'] as String?) ?? previousRefreshToken,
      expiresAt: (now ?? DateTime.now()).add(Duration(seconds: expiresIn ?? 3600)),
      scopes: OAuthConfig.parseScopes(json['scope'] as String? ?? ''),
    );
  }

  factory OAuthTokens.fromJson(Map<String, dynamic> json) => OAuthTokens(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String?,
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    scopes: ((json['scopes'] as List?) ?? const []).map((e) => '$e').toList(),
  );

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final List<String> scopes;

  /// True when the access token expires within [margin].
  bool expiresSoon({Duration margin = const Duration(seconds: 60), DateTime? now}) =>
      !(now ?? DateTime.now()).add(margin).isBefore(expiresAt);

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': ?refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'scopes': scopes,
  };
}

/// An OAuth error (RFC 6749 §5.2 / §4.1.2.1).
class OAuthException implements Exception {
  const OAuthException(this.code, [this.description]);

  final String code;
  final String? description;

  /// The grant is gone (revoked, expired or already used): sign in again.
  bool get needsReauth => code == 'invalid_grant' || code == 'unauthorized_client' || code == 'invalid_client';

  @override
  String toString() => description == null || description!.isEmpty ? code : '$code: $description';
}

/// Talks to the Cloudflare OAuth endpoints.
class OAuthApi {
  OAuthApi({Dio? dio})
    : _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 30)));

  final Dio _dio;

  Uri authorizeUri(OAuthConfig config, {required Uri redirectUri, required String state, required Pkce pkce}) =>
      Uri.parse(OAuthConfig.authorizeEndpoint).replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': config.clientId,
          'redirect_uri': redirectUri.toString(),
          'scope': config.requestScopes.join(' '),
          'state': state,
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      );

  Future<OAuthTokens> exchangeCode(
    OAuthConfig config, {
    required String code,
    required Uri redirectUri,
    required Pkce pkce,
  }) async {
    final json = await _post(OAuthConfig.tokenEndpoint, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri.toString(),
      'client_id': config.clientId,
      'code_verifier': pkce.verifier,
    });
    return OAuthTokens.fromTokenResponse(json);
  }

  Future<OAuthTokens> refresh(String clientId, String refreshToken) async {
    final json = await _post(OAuthConfig.tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    });
    return OAuthTokens.fromTokenResponse(json, previousRefreshToken: refreshToken);
  }

  /// Revokes a token (RFC 7009). Best effort: errors are swallowed and the
  /// call gives up after a few seconds (e.g. when offline).
  Future<void> revoke(String clientId, String token, {String hint = 'refresh_token'}) async {
    try {
      await _post(OAuthConfig.revokeEndpoint, {
        'token': token,
        'token_type_hint': hint,
        'client_id': clientId,
      }).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _post(String url, Map<String, String> form) async {
    final Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        url,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/json'},
          // OAuth errors arrive as 4xx JSON bodies; parse them below.
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw OAuthException('network_error', e.message ?? e.type.name);
    }
    final body = res.data is String && (res.data as String).isNotEmpty ? res.data as String : '{}';
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(body) as Map);
    } catch (_) {
      json = const {};
    }
    final status = res.statusCode ?? 0;
    if (status >= 400 || json['error'] != null) {
      throw OAuthException(
        json['error'] as String? ?? 'http_$status',
        json['error_description'] as String? ?? (json.isEmpty ? body : null),
      );
    }
    return json;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../licensing/license_config.dart';
import '../settings/app_settings.dart';
import 'oauth.dart';

/// The scopes configured on Cirrus's OAuth client, as the Cirrus website
/// reads them from Cloudflare: `GET {licence server}/api/v1/oauth/config`.
///
/// [scopes] is everything the client is configured for (what to request,
/// without `offline_access`/`openid`); [optionalScopes] are those the consent
/// screen lets the user untick. An empty [clientId] means the server did not
/// name a client: the list applies to the built-in one. A 404
/// (`not_configured`) is treated like any other failure.
class RemoteOAuthConfig {
  const RemoteOAuthConfig({required this.clientId, required this.scopes, this.optionalScopes = const [], this.source});

  factory RemoteOAuthConfig.fromJson(Map<String, dynamic> json) => RemoteOAuthConfig(
    clientId: (json['client_id'] as String? ?? '').trim(),
    scopes: _scopeList(json['scopes']),
    optionalScopes: _scopeList(json['optional_scopes']),
    source: json['source'] as String?,
  );

  final String clientId;
  final List<String> scopes;
  final List<String> optionalScopes;

  /// Where the server got the list from: `cloudflare` or `env`.
  final String? source;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'scopes': scopes,
    'optional_scopes': optionalScopes,
    'source': ?source,
  };

  /// Accepts a JSON array or a space-separated string.
  static List<String> _scopeList(Object? raw) => switch (raw) {
    final List<dynamic> l => OAuthConfig.parseScopes(l.map((e) => '$e').join(' ')),
    final String s => OAuthConfig.parseScopes(s),
    _ => const [],
  };
}

/// Loads the [RemoteOAuthConfig]; throws when it cannot (including a 404
/// when the server has none configured).
abstract interface class OAuthConfigFetcher {
  Future<RemoteOAuthConfig> fetch();
}

class HttpOAuthConfigFetcher implements OAuthConfigFetcher {
  /// [dio] is injectable (tests, or a client with its own DNS resolution).
  HttpOAuthConfigFetcher(this.server, {Dio? dio})
    : _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 4), receiveTimeout: const Duration(seconds: 4)));

  /// Base URL of the Cirrus website, without a trailing slash.
  final String server;
  final Dio _dio;

  Uri get uri => Uri.parse('$server/api/v1/oauth/config');

  @override
  Future<RemoteOAuthConfig> fetch() async {
    final res = await _dio.getUri<dynamic>(
      uri,
      options: Options(responseType: ResponseType.plain, headers: {'Accept': 'application/json'}),
    );
    final body = res.data;
    final json = jsonDecode(body is String ? body : '$body');
    if (json is! Map) throw const FormatException('Unexpected OAuth config response');
    return RemoteOAuthConfig.fromJson(Map<String, dynamic>.from(json));
  }
}

/// Chooses the scopes to request with the built-in OAuth client: the
/// server's list when it describes the same client, else the last good list
/// (when offline), else [OAuthConfig.defaultScopes].
class OAuthScopeResolver {
  OAuthScopeResolver({required this.fetcher, required this.prefs, this.timeout = const Duration(seconds: 4)});

  static const cacheKey = 'cirrus.oauth.remoteConfig.v1';

  final OAuthConfigFetcher fetcher;
  final SharedPreferences prefs;
  final Duration timeout;

  /// The last config fetched successfully for any client, if any.
  RemoteOAuthConfig? get cached {
    final raw = prefs.getString(cacheKey);
    if (raw == null) return null;
    try {
      return RemoteOAuthConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  bool _fits(RemoteOAuthConfig? c, OAuthConfig builtIn) =>
      c != null && (c.clientId.isEmpty || c.clientId == builtIn.clientId) && c.scopes.isNotEmpty;

  /// [builtIn] with the scopes to request.
  Future<OAuthConfig> resolve(OAuthConfig builtIn) async {
    RemoteOAuthConfig remote;
    try {
      remote = await fetcher.fetch().timeout(timeout);
    } catch (_) {
      final last = cached;
      return _fits(last, builtIn) ? OAuthConfig(clientId: builtIn.clientId, scopes: last!.scopes) : builtIn;
    }
    if (!_fits(remote, builtIn)) return builtIn;
    await prefs.setString(cacheKey, jsonEncode(remote.toJson()));
    return OAuthConfig(clientId: builtIn.clientId, scopes: remote.scopes);
  }
}

/// Fetches the OAuth config from the licence server (overridden in tests).
final oauthConfigFetcherProvider = Provider<OAuthConfigFetcher>(
  (ref) => HttpOAuthConfigFetcher(ref.watch(licenseConfigProvider).server),
);

final oauthScopeResolverProvider = Provider<OAuthScopeResolver>(
  (ref) => OAuthScopeResolver(fetcher: ref.watch(oauthConfigFetcherProvider), prefs: ref.watch(sharedPrefsProvider)),
);

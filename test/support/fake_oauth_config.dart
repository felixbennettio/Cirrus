import 'dart:async';

import 'package:cirrus/core/auth/oauth_remote_config.dart';

/// Stands in for `GET /api/v1/oauth/config` on the Cirrus website.
class FakeOAuthConfigFetcher implements OAuthConfigFetcher {
  FakeOAuthConfigFetcher({this.config, this.error, this.hang = false});

  RemoteOAuthConfig? config;

  /// Thrown instead of answering (e.g. a network error).
  Object? error;

  /// Never answers (the resolver's timeout has to kick in).
  bool hang;
  int calls = 0;

  @override
  Future<RemoteOAuthConfig> fetch() {
    calls++;
    if (hang) return Completer<RemoteOAuthConfig>().future;
    if (error != null) return Future.error(error!);
    return Future.value(config!);
  }
}

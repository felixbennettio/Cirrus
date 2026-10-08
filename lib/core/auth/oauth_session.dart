import 'dart:async';

import '../api/cf_client.dart';
import 'credential.dart';
import 'oauth.dart';

/// Persists OAuth tokens per profile. They are kept apart from the profile
/// list so that a refresh never rewrites (or races with) profile edits.
abstract interface class OAuthTokenStore {
  Future<OAuthTokens?> readTokens(String profileId);
  Future<void> writeTokens(String profileId, OAuthTokens tokens);
  Future<void> deleteTokens(String profileId);
}

/// Hands out access tokens for one OAuth profile and refreshes them shortly
/// before they expire. Cloudflare's authorization server rotates refresh
/// tokens and treats a reused one as stolen, revoking the whole grant (the
/// user then has to sign in again). So every refresh token is used at most
/// once: concurrent callers share one load and one in-flight refresh, and a
/// caller holding tokens that were already replaced gets the new ones.
class OAuthSession implements AccessTokenSource {
  OAuthSession({
    required this.profileId,
    required this.clientId,
    required this.store,
    OAuthApi? api,
    OAuthTokens? initial,
  }) : api = api ?? OAuthApi(),
       _tokens = initial;

  final String profileId;
  final String clientId;
  final OAuthTokenStore store;
  final OAuthApi api;
  OAuthTokens? _tokens;
  Future<OAuthTokens?>? _loading;
  Future<OAuthTokens>? _refreshing;

  @override
  String? get currentToken => _tokens?.accessToken;

  OAuthTokens? get tokens => _tokens;

  /// The stored tokens, loading them if needed (null when signed out).
  Future<OAuthTokens?> loadTokens() async {
    if (_tokens != null) return _tokens;
    final loaded = await (_loading ??= store.readTokens(profileId));
    // A refresh may have finished while the store was read: keep its tokens.
    return _tokens ??= loaded;
  }

  @override
  Future<String> accessToken({String? rejected}) async {
    var t = await loadTokens();
    if (t == null) {
      throw const OAuthException('not_signed_in', 'This credential has no OAuth session. Sign in again.');
    }
    // A request was rejected with this token: refresh unless another caller
    // already replaced it.
    final stale = rejected != null && rejected == t.accessToken;
    if (stale || t.expiresSoon()) t = await _refresh(t);
    return t.accessToken;
  }

  Future<OAuthTokens> _refresh(OAuthTokens current) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    // Already replaced by an earlier refresh: never send its refresh token again.
    final latest = _tokens;
    if (latest != null && latest.accessToken != current.accessToken && !latest.expiresSoon()) {
      return Future.value(latest);
    }
    final f = _doRefresh(current);
    _refreshing = f;
    f.whenComplete(() {
      if (identical(_refreshing, f)) _refreshing = null;
    }).ignore();
    return f;
  }

  Future<OAuthTokens> _doRefresh(OAuthTokens current) async {
    final rt = current.refreshToken;
    if (rt == null || rt.isEmpty) {
      throw const OAuthException('invalid_grant', 'The session cannot be renewed. Sign in again.');
    }
    OAuthTokens next;
    try {
      next = await api.refresh(clientId, rt);
    } on OAuthException catch (e) {
      // Another instance of the app may have rotated the token and stored
      // the new one: use that rather than giving up.
      final stored = e.needsReauth ? await store.readTokens(profileId) : null;
      final storedRt = stored?.refreshToken;
      if (stored == null || storedRt == null || storedRt == rt) rethrow;
      next = stored.expiresSoon() ? await api.refresh(clientId, storedRt) : stored;
      if (identical(next, stored)) {
        _tokens = stored;
        return stored;
      }
    }
    // A refresh response may leave out `scope`: the grant is unchanged then.
    if (next.scopes.isEmpty && current.scopes.isNotEmpty) {
      next = OAuthTokens(
        accessToken: next.accessToken,
        refreshToken: next.refreshToken,
        expiresAt: next.expiresAt,
        scopes: current.scopes,
      );
    }
    _tokens = next;
    await store.writeTokens(profileId, next);
    return next;
  }

  /// Revokes the refresh token (best effort) and forgets the session.
  Future<void> signOut() async {
    final t = _tokens ?? await store.readTokens(profileId);
    final rt = t?.refreshToken;
    if (rt != null) await api.revoke(clientId, rt);
    _tokens = null;
    _loading = null;
    await store.deleteTokens(profileId);
  }
}

/// One [OAuthSession] per profile, shared by every [CfClient] built for it.
class OAuthSessions {
  OAuthSessions(this.store, {this.api});

  final OAuthTokenStore store;
  final OAuthApi? api;
  final _byProfile = <String, OAuthSession>{};

  OAuthSession forProfile(Profile p) => _byProfile.putIfAbsent(
    p.id,
    () => OAuthSession(profileId: p.id, clientId: p.oauthClientId ?? '', store: store, api: api),
  );

  /// Stores freshly issued tokens for [p] and returns its session.
  Future<OAuthSession> adopt(Profile p, OAuthTokens tokens) async {
    await store.writeTokens(p.id, tokens);
    return _byProfile[p.id] = OAuthSession(
      profileId: p.id,
      clientId: p.oauthClientId ?? '',
      store: store,
      api: api,
      initial: tokens,
    );
  }

  /// Signs [p] out and drops its session.
  Future<void> remove(Profile p) async {
    await forProfile(p).signOut();
    _byProfile.remove(p.id);
  }
}

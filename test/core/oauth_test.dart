import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cirrus/core/api/cf_client.dart';
import 'package:cirrus/core/api/cf_exception.dart';
import 'package:cirrus/core/auth/credential.dart';
import 'package:cirrus/core/auth/oauth.dart';
import 'package:cirrus/core/auth/oauth_login.dart';
import 'package:cirrus/core/auth/oauth_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_api.dart';

class MemoryTokenStore implements OAuthTokenStore {
  final data = <String, OAuthTokens>{};

  @override
  Future<OAuthTokens?> readTokens(String profileId) async => data[profileId];

  @override
  Future<void> writeTokens(String profileId, OAuthTokens tokens) async => data[profileId] = tokens;

  @override
  Future<void> deleteTokens(String profileId) async => data.remove(profileId);
}

const config = OAuthConfig(clientId: 'client-1', scopes: ['account.read', 'zone.read']);

const oauthProfile = Profile(
  id: 'o1',
  name: 'OAuth',
  kind: AuthKind.oauth,
  oauthClientId: 'client-1',
  oauthScopes: ['account.read', 'zone.read'],
);

/// A token endpoint that issues `access-N` / `refresh-N` and records grants.
(OAuthApi, FakeApi) tokenServer({int expiresIn = 3600, void Function(Map body)? onGrant}) {
  var n = 0;
  final fake = FakeApi((method, uri, body) {
    if (uri.toString() == OAuthConfig.revokeEndpoint) return (200, '', const <String, List<String>>{});
    if (uri.toString() != OAuthConfig.tokenEndpoint) return null;
    final form = Map<String, dynamic>.from(body as Map);
    onGrant?.call(form);
    if (form['refresh_token'] == 'revoked') {
      return (400, {'error': 'invalid_grant', 'error_description': 'token revoked'}, const <String, List<String>>{});
    }
    n++;
    return (
      200,
      {
        'access_token': 'access-$n',
        'refresh_token': 'refresh-$n',
        'expires_in': expiresIn,
        'token_type': 'bearer',
        'scope': 'account.read zone.read offline_access',
      },
      const <String, List<String>>{},
    );
  });
  return (OAuthApi(dio: Dio()..httpClientAdapter = fake), fake);
}

OAuthTokens tokens(String access, {String? refresh = 'refresh-0', Duration ttl = const Duration(hours: 1)}) =>
    OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: DateTime.now().add(ttl));

void main() {
  group('PKCE', () {
    test('matches the RFC 7636 appendix B example', () {
      final p = Pkce('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk');
      expect(p.challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('generates unreserved verifiers of the right length', () {
      final v = Pkce.generate().verifier;
      expect(v.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue);
    });
  });

  test('scopes always include offline_access once', () {
    expect(OAuthConfig.parseScopes(' account.read, zone.read  zone.read\n'), ['account.read', 'zone.read']);
    final c = OAuthConfig(clientId: 'x', scopes: OAuthConfig.parseScopes('offline_access zone.read'));
    expect(c.requestScopes, ['offline_access', 'zone.read']);
    expect(config.requestScopes, ['account.read', 'zone.read', 'offline_access']);
  });

  test('authorize URL carries PKCE, state and the redirect', () {
    final pkce = Pkce('v' * 50);
    final uri = OAuthApi().authorizeUri(
      config,
      redirectUri: Uri.parse('http://127.0.0.1:5000/oauth/callback'),
      state: 'st',
      pkce: pkce,
    );
    expect(uri.toString(), startsWith(OAuthConfig.authorizeEndpoint));
    expect(uri.queryParameters, {
      'response_type': 'code',
      'client_id': 'client-1',
      'redirect_uri': 'http://127.0.0.1:5000/oauth/callback',
      'scope': 'account.read zone.read offline_access',
      'state': 'st',
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
    });
  });

  group('token endpoint', () {
    test('exchanges a code with the verifier and no secret', () async {
      Map? sent;
      final (api, _) = tokenServer(onGrant: (b) => sent = b);
      final pkce = Pkce('v' * 50);
      final t = await api.exchangeCode(
        config,
        code: 'c0de',
        redirectUri: Uri.parse('io.felixbennett.cirrus:/oauth/callback'),
        pkce: pkce,
      );
      expect(sent, {
        'grant_type': 'authorization_code',
        'code': 'c0de',
        'redirect_uri': 'io.felixbennett.cirrus:/oauth/callback',
        'client_id': 'client-1',
        'code_verifier': pkce.verifier,
      });
      expect(t.accessToken, 'access-1');
      expect(t.refreshToken, 'refresh-1');
      expect(t.scopes, contains('offline_access'));
      expect(t.expiresSoon(), isFalse);
    });

    test('maps OAuth errors and flags grants that need a new sign-in', () async {
      final (api, _) = tokenServer();
      await expectLater(
        api.refresh('client-1', 'revoked'),
        throwsA(isA<OAuthException>().having((e) => e.needsReauth, 'needsReauth', isTrue)),
      );
    });

    test('keeps the previous refresh token when none is returned', () {
      final t = OAuthTokens.fromTokenResponse({'access_token': 'a', 'expires_in': 60}, previousRefreshToken: 'r');
      expect(t.refreshToken, 'r');
      expect(t.expiresSoon(margin: const Duration(seconds: 61)), isTrue);
      final round = OAuthTokens.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect(round.accessToken, 'a');
      expect(round.refreshToken, 'r');
      expect(round.expiresAt.difference(t.expiresAt).inSeconds.abs(), lessThan(1));
    });
  });

  group('OAuthSession', () {
    test('serves the stored token while it is fresh', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('fresh');
      final (api, fake) = tokenServer();
      final s = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: api);
      expect(await s.accessToken(), 'fresh');
      expect(fake.calls, isEmpty);
    });

    test('refreshes an expiring token once for concurrent callers and persists the rotation', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('old', ttl: const Duration(seconds: 5));
      final (api, fake) = tokenServer();
      final s = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: api);
      final results = await Future.wait([s.accessToken(), s.accessToken(), s.accessToken()]);
      expect(results, ['access-1', 'access-1', 'access-1']);
      expect(fake.calls, hasLength(1));
      expect((fake.calls.single.body as Map)['refresh_token'], 'refresh-0');
      expect(store.data['o1']!.refreshToken, 'refresh-1');
    });

    test('a rejected token forces one refresh; an already replaced one does not', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('a0');
      final (api, fake) = tokenServer();
      final s = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: api);
      expect(await s.accessToken(rejected: 'a0'), 'access-1');
      expect(await s.accessToken(rejected: 'a0'), 'access-1');
      expect(fake.calls, hasLength(1));
    });

    test('sign-out revokes the refresh token and forgets it', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('a0', refresh: 'r0');
      final (api, fake) = tokenServer();
      final s = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: api);
      await s.signOut();
      expect(fake.calls.single.uri.toString(), OAuthConfig.revokeEndpoint);
      expect(fake.calls.single.body, {'token': 'r0', 'token_type_hint': 'refresh_token', 'client_id': 'client-1'});
      expect(store.data, isEmpty);
      await expectLater(s.accessToken(), throwsA(isA<OAuthException>()));
    });
  });

  group('CfClient with OAuth', () {
    test('sends the bearer token and retries once after a refresh on 401', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('stale');
      final (oauth, tokenCalls) = tokenServer();
      final session = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: oauth);
      final seen = <String>[];
      // Record the Authorization header and reject anything but the refreshed token.
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            seen.add(o.headers['Authorization'] as String);
            final ok = o.headers['Authorization'] == 'Bearer access-1';
            h.resolve(
              Response(
                requestOptions: o,
                statusCode: ok ? 200 : 401,
                data: ok ? FakeApi.ok({'id': 'u1'}) : FakeApi.fail(10000, 'Authentication error'),
              ),
            );
          },
        ),
      );
      final c = CfClient(oauthProfile, dio: dio, tokens: session);
      final user = await c.get('/user');
      expect(user, {'id': 'u1'});
      expect(seen, ['Bearer stale', 'Bearer access-1']);
      expect(tokenCalls.calls, hasLength(1));
      expect(c.curl('GET', '/user'), contains(r'Bearer $CLOUDFLARE_API_TOKEN'));
    });

    test('an expired grant surfaces as an auth error', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('old', refresh: 'revoked', ttl: Duration.zero);
      final (oauth, _) = tokenServer();
      final session = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: oauth);
      final c = CfClient(oauthProfile, dio: Dio()..httpClientAdapter = FakeApi((m, u, b) => null), tokens: session);
      await expectLater(
        c.get('/accounts'),
        throwsA(isA<CfApiException>().having((e) => e.isAuthError, 'isAuthError', isTrue)),
      );
    });

    test('Origin CA endpoints still use the Origin CA key when one is set', () async {
      final store = MemoryTokenStore()..data['o1'] = tokens('a');
      final session = OAuthSession(profileId: 'o1', clientId: 'client-1', store: store, api: OAuthApi());
      final fake = FakeApi((m, u, b) => (200, FakeApi.ok(<Object>[]), const <String, List<String>>{}));
      final p = oauthProfile.copyWith(originCaKey: 'v1.0-origin');
      await CfClient(p, dio: Dio()..httpClientAdapter = fake, tokens: session).get('/certificates');
      expect(fake.calls.single.headers['X-Auth-User-Service-Key'], 'v1.0-origin');
      expect(fake.calls.single.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('sign-in flow', () {
    Future<OAuthTokens> runLoopback({required Map<String, String> Function(Uri authorize) respond}) {
      final (api, _) = tokenServer();
      return signInWithCloudflare(
        config,
        api: api,
        receiver: LoopbackReceiver(),
        launch: (url) async {
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          expect(redirect.host, '127.0.0.1');
          expect(redirect.path, '/oauth/callback');
          expect(redirect.port, isNot(0));
          // Play the browser: follow the redirect back to the app.
          final client = HttpClient();
          final req = await client.getUrl(redirect.replace(queryParameters: respond(url)));
          final res = await req.close();
          expect(res.statusCode, 200);
          expect(await res.transform(utf8.decoder).join(), contains('Cirrus'));
          client.close();
        },
      );
    }

    test('completes through the loopback redirect', () async {
      final t = await runLoopback(respond: (u) => {'code': 'abc', 'state': u.queryParameters['state']!});
      expect(t.accessToken, 'access-1');
    });

    test('rejects a mismatched state', () async {
      await expectLater(
        runLoopback(respond: (u) => {'code': 'abc', 'state': 'forged'}),
        throwsA(isA<OAuthException>().having((e) => e.code, 'code', 'state_mismatch')),
      );
    });

    test('reports a declined consent', () async {
      await expectLater(
        runLoopback(respond: (u) => {'error': 'access_denied', 'state': u.queryParameters['state']!}),
        throwsA(isA<OAuthException>().having((e) => e.code, 'code', 'access_denied')),
      );
    });

    test('completes through an app-scheme deep link', () async {
      final links = StreamController<Uri>();
      final (api, _) = tokenServer();
      final t = await signInWithCloudflare(
        config,
        api: api,
        receiver: AppLinkReceiver(links: links.stream),
        launch: (url) async {
          expect(url.queryParameters['redirect_uri'], 'io.felixbennett.cirrus:/oauth/callback');
          links.add(Uri.parse('https://example.com/other'));
          // A replayed callback from an earlier, abandoned attempt is ignored.
          links.add(Uri.parse('io.felixbennett.cirrus:/oauth/callback?code=old&state=stale'));
          links.add(Uri.parse('io.felixbennett.cirrus:/oauth/callback?code=xyz&state=${url.queryParameters['state']}'));
        },
      );
      expect(t.accessToken, 'access-1');
      await links.close();
    });

    test('can be cancelled while waiting for the browser', () async {
      final cancel = Completer<void>();
      final (api, _) = tokenServer();
      final f = signInWithCloudflare(
        config,
        api: api,
        receiver: LoopbackReceiver(),
        launch: (_) async => cancel.complete(),
        cancel: cancel.future,
      );
      await expectLater(f, throwsA(isA<OAuthException>().having((e) => e.code, 'code', 'cancelled')));
    });
  });

  test('profiles round-trip OAuth fields', () {
    final p = Profile.fromJson(jsonDecode(jsonEncode(oauthProfile.toJson())) as Map<String, dynamic>);
    expect(p.kind, AuthKind.oauth);
    expect(p.oauthClientId, 'client-1');
    expect(p.oauthScopes, ['account.read', 'zone.read']);
    expect(p.kindLabel, 'OAuth');
    expect(p.authHeaders(), isEmpty);
  });
}

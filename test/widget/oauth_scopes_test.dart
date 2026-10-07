import 'dart:async';

import 'package:cirrus/core/api/cf_exception.dart';
import 'package:cirrus/core/auth/credential.dart';
import 'package:cirrus/core/auth/credential_store.dart';
import 'package:cirrus/core/auth/oauth.dart';
import 'package:cirrus/core/catalog/catalog.dart';
import 'package:cirrus/core/session/session.dart';
import 'package:cirrus/core/settings/app_settings.dart';
import 'package:cirrus/ui/widgets/async_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore extends CredentialStore {
  _MemoryStore(this.profiles);

  List<Profile> profiles;
  final tokens = <String, OAuthTokens>{};

  @override
  Future<List<Profile>> load() async => profiles;

  @override
  Future<void> save(List<Profile> p) async => profiles = p;

  @override
  Future<OAuthTokens?> readTokens(String profileId) async => tokens[profileId];

  @override
  Future<void> writeTokens(String profileId, OAuthTokens t) async => tokens[profileId] = t;

  @override
  Future<void> deleteTokens(String profileId) async => tokens.remove(profileId);
}

const _oauth = Profile(
  id: 'o1',
  name: 'Signed in',
  kind: AuthKind.oauth,
  oauthClientId: 'client-1',
  oauthScopes: ['zone.read', 'dns.write', 'workers-scripts.edit'],
);

const _token = Profile(id: 't1', name: 'Token', kind: AuthKind.apiToken, token: 'tok_1234567890abcdef');

final _forbidden = CfApiException(
  method: 'GET',
  path: '/accounts/acc1/workers/scripts',
  statusCode: 403,
  // What Cloudflare answers when the credential lacks the permission.
  errors: const [CfMessage(code: 10000, message: 'Authentication error')],
);

Future<void> _pump(WidgetTester tester, Profile profile) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = _MemoryStore([profile])
    ..tokens['o1'] = OAuthTokens(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      scopes: const ['zone.read', 'dns.write', 'offline_access'],
    );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        credentialStoreProvider.overrideWithValue(store),
        catalogProvider.overrideWith((ref) => Completer<ApiCatalog>().future),
      ],
      child: MaterialApp(
        home: Scaffold(body: ErrorView(error: _forbidden)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a 403 with an OAuth profile explains the grant and offers to sign in again', (tester) async {
    await _pump(tester, _oauth);
    expect(find.textContaining('may not have been granted when you signed in'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in again'));
    await tester.pumpAndSettle();
    // The credential's edit page: re-authorize, and see what was granted.
    expect(find.text('Edit credential'), findsOneWidget);
    expect(find.text('Granted permissions'), findsOneWidget);
    expect(find.text('2 scopes'), findsOneWidget);
    await tester.tap(find.text('Granted permissions'));
    await tester.pumpAndSettle();
    expect(find.text('zone.read'), findsOneWidget);
    expect(find.text('dns.write'), findsOneWidget);
    expect(find.text('offline_access'), findsNothing);
    expect(find.text('Requested but not granted'), findsOneWidget);
    expect(find.text('workers-scripts.edit'), findsOneWidget);
  });

  testWidgets('a 403 with an API token keeps the plain error', (tester) async {
    await _pump(tester, _token);
    expect(find.text('Authentication failed'), findsOneWidget);
    expect(find.textContaining('may not have been granted'), findsNothing);
    expect(find.text('Sign in again'), findsNothing);
  });
}

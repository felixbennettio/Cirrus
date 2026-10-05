import 'package:cirrus/app/app.dart';
import 'package:cirrus/app/router.dart';
import 'package:cirrus/core/api/cf_client.dart';
import 'package:cirrus/core/auth/credential.dart';
import 'package:cirrus/core/cache/query_cache.dart';
import 'package:cirrus/core/auth/credential_store.dart';
import 'package:cirrus/core/session/session.dart';
import 'package:cirrus/core/settings/app_settings.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_api.dart';

class MemoryCredentialStore extends CredentialStore {
  MemoryCredentialStore(this.profiles);

  List<Profile> profiles;

  @override
  Future<List<Profile>> load() async => profiles;

  @override
  Future<void> save(List<Profile> p) async => profiles = p;
}

const _zone = {
  'id': 'zone0001',
  'name': 'example.com',
  'status': 'active',
  'paused': false,
  'plan': {'name': 'Pro Plan'},
  'name_servers': ['ada.ns.cloudflare.com', 'bob.ns.cloudflare.com'],
};

(int, Object?, Map<String, List<String>>)? _routes(String method, Uri uri, Object? body) {
  final p = uri.path.replaceFirst('/client/v4', '');
  if (method == 'GET' && p == '/accounts') return (200, FakeApi.ok([{'id': 'acc1', 'name': 'Acme Corp'}]), const {});
  if (method == 'GET' && p == '/zones') return (200, FakeApi.ok([_zone]), const {});
  if (method == 'GET' && p == '/zones/zone0001/dns_records') {
    return (
      200,
      FakeApi.ok([
        {'id': 'r1', 'type': 'A', 'name': 'example.com', 'content': '203.0.113.10', 'proxied': true, 'ttl': 1},
        {'id': 'r2', 'type': 'MX', 'name': 'example.com', 'content': 'mx.example.net', 'priority': 10, 'proxied': false, 'ttl': 3600},
      ]),
      const {},
    );
  }
  return null;
}

Future<ProviderContainer> _pumpApp(WidgetTester tester, {required List<Profile> profiles, FakeApi? api}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = api ?? FakeApi(_routes);
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore(profiles)),
      clientProvider.overrideWith((ref) {
        final p = ref.watch(activeProfileProvider);
        return p == null ? null : CfClient(p, dio: Dio()..httpClientAdapter = fake);
      }),
    ],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const CirrusApp()));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return container;
}

const _profile = Profile(id: 'p1', name: 'Demo', kind: AuthKind.apiToken, token: 'tok_1234567890abcdef');

void main() {
  DiskCache.enabled = false;

  testWidgets('first run shows onboarding', (tester) async {
    await _pumpApp(tester, profiles: []);
    expect(find.text('Cirrus'), findsWidgets);
    expect(find.text('Verify & save'), findsOneWidget);
    expect(find.text('API Token'), findsWidgets);
  });

  testWidgets('home lists account and zones', (tester) async {
    await _pumpApp(tester, profiles: [_profile]);
    expect(find.text('Acme Corp'), findsWidgets);
    expect(find.text('example.com'), findsWidgets);
    expect(find.text('Quick access'), findsOneWidget);
  });

  testWidgets('DNS page renders records from the API', (tester) async {
    final container = await _pumpApp(tester, profiles: [_profile]);
    container.read(routerProvider).go('/zone/dns');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('203.0.113.10', findRichText: true), findsOneWidget);
    expect(find.text('MX'), findsWidgets);
    expect(find.text('2 of 2 records'), findsOneWidget);
  });
}

import 'package:cirrus/app/app.dart';
import 'package:cirrus/app/router.dart';
import 'package:cirrus/app/theme.dart';
import 'package:cirrus/core/api/cf_client.dart';
import 'package:cirrus/core/auth/credential.dart';
import 'package:cirrus/core/auth/oauth.dart';
import 'package:cirrus/core/billing/billing.dart';
import 'package:cirrus/core/cache/query_cache.dart';
import 'package:cirrus/core/auth/credential_store.dart';
import 'package:cirrus/core/licensing/license_controller.dart';
import 'package:cirrus/core/session/session.dart';
import 'package:cirrus/core/settings/app_settings.dart';
import 'package:cirrus/ui/widgets/common.dart';
import 'package:cirrus/ui/widgets/glass.dart';
import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_api.dart';
import '../support/fake_license.dart';
import '../support/fake_store.dart';

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
  if (method == 'GET' && p == '/accounts') {
    return (
      200,
      FakeApi.ok([
        {'id': 'acc1', 'name': 'Acme Corp'},
      ]),
      const {},
    );
  }
  if (method == 'GET' && p == '/zones') return (200, FakeApi.ok([_zone]), const {});
  if (method == 'GET' && p == '/zones/zone0001/dns_records') {
    return (
      200,
      FakeApi.ok([
        {'id': 'r1', 'type': 'A', 'name': 'example.com', 'content': '203.0.113.10', 'proxied': true, 'ttl': 1},
        {
          'id': 'r2',
          'type': 'MX',
          'name': 'example.com',
          'content': 'mx.example.net',
          'priority': 10,
          'proxied': false,
          'ttl': 3600,
        },
      ]),
      const {},
    );
  }
  return null;
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required List<Profile> profiles,
  FakeApi? api,
  OAuthConfig? oauth,
  FakeStore? store,
  FakeLicenseServer? license,
}) async {
  SharedPreferences.setMockInitialValues({});
  if (license != null) mockAppVersion();
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = api ?? FakeApi(_routes);
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore(profiles)),
      oauthConfigProvider.overrideWithValue(oauth),
      if (store != null) ...[
        storeChannelProvider.overrideWithValue(StoreChannel.appStore),
        storeGatewayProvider.overrideWithValue(store),
      ],
      if (license != null) ...licenseOverrides(license, store: MemoryLicenseStore()),
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
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

  testWidgets('first run offers Cloudflare sign-in when a client is built in', (tester) async {
    await _pumpApp(
      tester,
      profiles: [],
      oauth: const OAuthConfig(clientId: 'c1', scopes: ['account.read']),
    );
    final button = find.widgetWithText(FilledButton, 'Sign in with Cloudflare');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(find.text('or use an API token / Global API Key'), findsOneWidget);
  });

  testWidgets('without a built-in client, sign-in waits for a custom client ID', (tester) async {
    await _pumpApp(tester, profiles: []);
    final button = find.widgetWithText(FilledButton, 'Sign in with Cloudflare');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(find.textContaining('no built-in OAuth client'), findsOneWidget);
    await tester.tap(find.text('Use your own OAuth client'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Client ID'), 'my-private-client');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('store builds show the paywall for Pro sections until unlocked', (tester) async {
    final store = FakeStore();
    final container = await _pumpApp(tester, profiles: [_profile], store: store);
    // Zone management is free.
    container.read(routerProvider).go('/zone/dns');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Cirrus Pro'), findsNothing);
    expect(find.text('PRO'), findsWidgets);
    // Workers needs Pro.
    container.read(routerProvider).go('/workers');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Cirrus Pro'), findsOneWidget);
    expect(find.text('Unlock for ¥198.00'), findsOneWidget);
    // Buying unlocks it in place.
    await tester.tap(find.text('Unlock for ¥198.00'));
    await tester.pump();
    expect(store.buys, 1);
    store.controller.add([store.purchase(PurchaseStatus.purchased)]);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Cirrus Pro'), findsNothing);
    expect(find.text('PRO'), findsNothing);
  });

  testWidgets('licence builds unlock Pro with a key bought on the website', (tester) async {
    final server = FakeLicenseServer()..licences[linuxKey] = FakeLicence(platform: 'linux');
    final container = await _pumpApp(tester, profiles: [_profile], license: server);
    container.read(routerProvider).go('/workers');
    await _settle(tester);
    expect(find.text('Cirrus Pro'), findsOneWidget);
    expect(find.text('Buy a licence'), findsOneWidget);
    expect(find.text('Restore purchase'), findsNothing);
    // Pasted as it might come from an email.
    await tester.enterText(find.widgetWithText(TextField, 'Licence key'), ' cirrus-7k3qd-m2xrt-9vb4n-hj6wp ');
    await tester.tap(find.text('Activate'));
    await _settle(tester);
    expect(server.licences[linuxKey]!.devices, hasLength(1));
    expect(container.read(licenseProvider).isActive, isTrue);
    // The Pro page itself is shown now.
    expect(find.text('Cirrus Pro'), findsNothing);
    expect(find.text('PRO'), findsNothing);
    // Settings shows the activation and releases it.
    container.read(routerProvider).go('/settings');
    await _settle(tester);
    expect(find.text('Activated on this device. Thank you!'), findsOneWidget);
    expect(find.text('CIRRUS-XXXXX-…-HJ6WP'), findsOneWidget);
    expect(find.text('q***@example.com'), findsOneWidget);
    await tester.tap(find.text('Deactivate on this device'));
    await _settle(tester);
    await tester.tap(find.text('Deactivate'));
    await _settle(tester);
    expect(server.licences[linuxKey]!.devices, isEmpty);
    expect(find.text('Not activated'), findsOneWidget);
    expect(find.text('PRO'), findsWidgets);
  });

  testWidgets('the licence paywall lists the devices using up the licence', (tester) async {
    final server = FakeLicenseServer()
      ..licences[linuxKey] = (FakeLicence(platform: 'linux')..devices['elsewhere'] = "Felix's ThinkPad");
    final container = await _pumpApp(tester, profiles: [_profile], license: server);
    container.read(routerProvider).go('/workers');
    await _settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Licence key'), linuxKey);
    await tester.tap(find.text('Activate'));
    await _settle(tester);
    expect(find.textContaining('already active on as many devices'), findsOneWidget);
    expect(find.text("Felix's ThinkPad"), findsOneWidget);
    expect(find.text('Lost or reinstalled a device? Reset it on the website'), findsOneWidget);
    expect(container.read(proProvider).hasPro, isFalse);
  });

  testWidgets('home lists account and zones', (tester) async {
    await _pumpApp(tester, profiles: [_profile]);
    expect(find.text('Acme Corp'), findsWidgets);
    expect(find.text('example.com'), findsWidgets);
    expect(find.text('Quick access'), findsOneWidget);
  });

  testWidgets('the sidebar signs out of the current credential', (tester) async {
    const other = Profile(id: 'p2', name: 'Second', kind: AuthKind.apiToken, token: 'tok_abcdef1234567890');
    final container = await _pumpApp(tester, profiles: [_profile, other]);
    await tester.tap(find.byTooltip('Sign out'));
    await _settle(tester);
    expect(find.text('Sign out of "Demo"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await _settle(tester);
    expect(container.read(profilesProvider).value!.map((p) => p.id), ['p2']);
    expect(container.read(activeProfileProvider)?.id, 'p2');

    // Signing out of the last one returns to the welcome page.
    await tester.tap(find.byTooltip('Sign out'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await _settle(tester);
    expect(container.read(profilesProvider).value, isEmpty);
    expect(find.text('Verify & save'), findsOneWidget);
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

  testWidgets('a zone page switches zones from under its title', (tester) async {
    final other = {..._zone, 'id': 'zone0002', 'name': 'example.net'};
    final api = FakeApi((method, uri, body) {
      if (method == 'GET' && uri.path.endsWith('/zones')) {
        return (200, FakeApi.ok([_zone, other]), const <String, List<String>>{});
      }
      return _routes(method, uri, body);
    });
    final container = await _pumpApp(tester, profiles: [_profile], api: api);
    container.read(routerProvider).go('/zone/dns');
    await _settle(tester);
    await tester.tap(find.byTooltip('Switch zone'));
    await _settle(tester);
    await tester.tap(find.text('example.net').last);
    await _settle(tester);
    expect(container.read(currentZoneIdProvider), 'zone0002');
    // Pages outside a zone keep their own subtitle.
    container.read(routerProvider).go('/');
    await _settle(tester);
    expect(find.byTooltip('Switch zone'), findsNothing);
  });

  testWidgets('on a phone the zone picker opens without bringing up the keyboard', (tester) async {
    // Tests run as Android: the search field waits for a tap.
    final container = await _pumpApp(tester, profiles: [_profile]);
    container.read(routerProvider).go('/zone/dns');
    await _settle(tester);
    await tester.tap(find.byTooltip('Switch zone'));
    await _settle(tester);
    final search = find.descendant(of: find.byType(Dialog), matching: find.byType(EditableText));
    expect(search, findsOneWidget);
    expect(tester.widget<EditableText>(search).focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    // Tapping the field is what brings up the keyboard.
    await tester.tap(search);
    await _settle(tester);
    expect(tester.widget<EditableText>(search).focusNode.hasFocus, isTrue);
  });

  testWidgets('only phones and tablets count as having an on-screen keyboard', (tester) async {
    final seen = <TargetPlatform, bool>{};
    for (final platform in TargetPlatform.values) {
      // A plain Theme: MaterialApp would animate between the two themes.
      await tester.pumpWidget(
        Theme(
          data: ThemeData(platform: platform),
          child: Builder(
            builder: (context) {
              seen[platform] = onScreenKeyboard(context);
              return const SizedBox();
            },
          ),
        ),
      );
    }
    expect(seen, {
      TargetPlatform.android: true,
      TargetPlatform.fuchsia: true,
      TargetPlatform.iOS: true,
      TargetPlatform.linux: false,
      TargetPlatform.macOS: false,
      TargetPlatform.windows: false,
    });
  });

  testWidgets('settings turn liquid glass on: glass app bar and sidebar, content scrolls behind', (tester) async {
    final container = await _pumpApp(tester, profiles: [_profile]);
    container.read(routerProvider).go('/settings');
    await _settle(tester);
    // Off by default outside iOS/macOS.
    expect(find.byType(BackdropFilter), findsNothing);
    // No platform colours in tests: the switch is shown, disabled, with a hint.
    final dynamicTile = find.widgetWithText(SwitchListTile, 'Dynamic colour');
    expect(tester.widget<SwitchListTile>(dynamicTile).onChanged, isNull);
    expect(find.textContaining('Cirrus uses its own colours'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Liquid glass'));
    await _settle(tester);
    expect(container.read(settingsProvider).liquidGlass, isTrue);
    // One blur for the app bar, one for the sidebar panel.
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(find.byType(AmbientBackground), findsWidgets);
    final page = find.ancestor(of: find.byType(ContentList), matching: find.byType(Scaffold)).first;
    expect(tester.widget<Scaffold>(page).extendBodyBehindAppBar, isTrue);
    // The list starts below the bar, though it can scroll behind it.
    final bar = find.descendant(of: page, matching: find.byType(AppBar));
    expect(tester.getTopLeft(find.text('Credentials')).dy, greaterThan(tester.getBottomLeft(bar).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dynamic colour follows the system accent colour where there is one', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      (call) async => call.method == 'getAccentColor' ? 0xFF1565C0 : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, null));
    final container = await _pumpApp(tester, profiles: [_profile]);
    Color primary() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!.colorScheme.primary;
    final brand = brandScheme(Brightness.light).primary;
    expect(primary(), isNot(brand));
    container.read(routerProvider).go('/settings');
    await _settle(tester);
    final dynamicTile = find.widgetWithText(SwitchListTile, 'Dynamic colour');
    expect(tester.widget<SwitchListTile>(dynamicTile).value, isTrue);
    await tester.tap(dynamicTile);
    await _settle(tester);
    expect(container.read(settingsProvider).dynamicColor, isFalse);
    expect(primary(), brand);
  });
}

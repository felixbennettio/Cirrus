import 'package:cirrus/core/billing/billing.dart';
import 'package:cirrus/core/settings/app_settings.dart';
import 'package:cirrus/features/pro/pro_features.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_store.dart';

Future<ProviderContainer> makeContainer(
  FakeStore store, {
  StoreChannel channel = StoreChannel.appStore,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(sp),
      storeChannelProvider.overrideWithValue(channel),
      storeGatewayProvider.overrideWithValue(store),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// Lets queued microtasks and stream events run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('builds outside a store are fully unlocked and never touch the store', () async {
    final store = FakeStore();
    final c = await makeContainer(store, channel: StoreChannel.none);
    final s = c.read(proProvider);
    expect(s.enforced, isFalse);
    expect(s.hasPro, isTrue);
    await settle();
    expect(store.restores, 0);
  });

  test('store builds start locked, load the product and restore silently', () async {
    final store = FakeStore();
    final c = await makeContainer(store);
    expect(c.read(proProvider).hasPro, isFalse);
    await settle();
    await settle();
    final s = c.read(proProvider);
    expect(s.storeAvailable, isTrue);
    expect(s.product?.price, '¥198.00');
    expect(store.restores, 1);
    expect(s.hasPro, isFalse);
  });

  test('a restored purchase unlocks Pro and is remembered', () async {
    final store = FakeStore(owned: true);
    final c = await makeContainer(store);
    c.read(proProvider);
    await settle();
    await settle();
    expect(c.read(proProvider).unlocked, isTrue);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(ProController.cacheKey), isTrue);
  });

  test('a remembered purchase unlocks immediately, even offline', () async {
    final store = FakeStore(available: false);
    final c = await makeContainer(store, prefs: {ProController.cacheKey: true});
    expect(c.read(proProvider).hasPro, isTrue);
    await settle();
    expect(c.read(proProvider).storeAvailable, isFalse);
    expect(c.read(proProvider).hasPro, isTrue);
  });

  test('buying unlocks Pro and completes (acknowledges) the transaction', () async {
    final store = FakeStore();
    final c = await makeContainer(store);
    c.read(proProvider);
    await settle();
    await settle();
    await c.read(proProvider.notifier).buy();
    expect(store.buys, 1);
    expect(c.read(proProvider).busy, isTrue);
    final p = store.purchase(PurchaseStatus.purchased);
    store.controller.add([p]);
    await settle();
    expect(c.read(proProvider).unlocked, isTrue);
    expect(c.read(proProvider).busy, isFalse);
    expect(store.completed, [p]);
  });

  test('cancelled and failed purchases leave Pro locked', () async {
    final store = FakeStore();
    final c = await makeContainer(store);
    c.read(proProvider);
    await settle();
    await settle();
    store.controller.add([store.purchase(PurchaseStatus.canceled, pending: false)]);
    await settle();
    expect(c.read(proProvider).unlocked, isFalse);
    final failed = store.purchase(PurchaseStatus.error)
      ..error = IAPError(source: 'fake', code: 'x', message: 'Card declined');
    store.controller.add([failed]);
    await settle();
    final s = c.read(proProvider);
    expect(s.unlocked, isFalse);
    expect(s.error, 'Card declined');
    expect(store.completed, [failed]);
  });

  test('other products are completed but do not unlock Pro', () async {
    final store = FakeStore();
    final c = await makeContainer(store);
    c.read(proProvider);
    await settle();
    final other = store.purchase(PurchaseStatus.purchased, id: 'something_else');
    store.controller.add([other]);
    await settle();
    expect(c.read(proProvider).unlocked, isFalse);
    expect(store.completed, [other]);
  });

  test('store channel names', () {
    expect(storeChannelFrom('appstore'), StoreChannel.appStore);
    expect(storeChannelFrom(' Play '), StoreChannel.googlePlay);
    expect(storeChannelFrom(''), StoreChannel.none);
  });

  group('Pro features by location', () {
    test('zone management stays free', () {
      for (final path in [
        '/',
        '/domains',
        '/zone',
        '/zone/dns',
        '/zone/ssl',
        '/zone/analytics',
        '/settings',
        '/console',
      ]) {
        expect(proFeatureFor(path), isNull, reason: path);
      }
    });

    test('account-level sections need Pro', () {
      expect(proFeatureFor('/workers'), ProFeature.compute);
      expect(proFeatureFor('/workers/api-gateway'), ProFeature.compute);
      expect(proFeatureFor('/r2/assets'), ProFeature.storage);
      expect(proFeatureFor('/kv/kv1?title=X'), ProFeature.storage);
      expect(proFeatureFor('/zt/tunnels'), ProFeature.zeroTrust);
      expect(proFeatureFor('/account/members'), ProFeature.account);
      expect(proFeatureFor('/graphql'), ProFeature.graphql);
      expect(proFeatureFor('/workersx'), isNull);
    });
  });
}

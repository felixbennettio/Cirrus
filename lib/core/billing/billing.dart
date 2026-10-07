import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../licensing/license_controller.dart';
import '../settings/app_settings.dart';

/// The channel this binary is sold through, from
/// `--dart-define=CIRRUS_STORE=appstore|play|license`. Cirrus Pro is only
/// sold (and only enforced) in those builds; every other build is fully
/// unlocked. `license` builds (Windows, Linux and Android sold outside the
/// stores) unlock Pro with a licence key from the website
/// (`lib/core/licensing`).
enum StoreChannel { none, appStore, googlePlay, license }

StoreChannel storeChannelFrom(String value) => switch (value.trim().toLowerCase()) {
  'appstore' || 'app_store' || 'apple' => StoreChannel.appStore,
  'play' || 'googleplay' || 'google_play' => StoreChannel.googlePlay,
  'license' || 'licence' || 'direct' => StoreChannel.license,
  _ => StoreChannel.none,
};

final storeChannelProvider = Provider<StoreChannel>((ref) {
  if (kIsWeb) return StoreChannel.none;
  final channel = storeChannelFrom(const String.fromEnvironment('CIRRUS_STORE'));
  // Each channel only exists on the platforms it is implemented for.
  final supported = switch (channel) {
    StoreChannel.none => true,
    StoreChannel.appStore => Platform.isIOS || Platform.isMacOS,
    StoreChannel.googlePlay => Platform.isAndroid,
    StoreChannel.license => Platform.isWindows || Platform.isLinux || Platform.isAndroid || Platform.isMacOS,
  };
  return supported ? channel : StoreChannel.none;
});

/// Cirrus Pro, lifetime: a non-consumable on the App Store and a one-time
/// product on Google Play, both with this ID.
const proProductId = 'cirrus_pro_lifetime';

/// The parts of the platform store Cirrus uses (an interface so tests can
/// stand in for StoreKit / Play Billing).
abstract interface class StoreGateway {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchase);
}

/// [StoreGateway] backed by `in_app_purchase` (StoreKit 2 on iOS/macOS,
/// Play Billing on Android).
class InAppPurchaseGateway implements StoreGateway {
  InAppPurchaseGateway([InAppPurchase? iap]) : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) => _iap.queryProductDetails(identifiers);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _iap.buyNonConsumable(purchaseParam: purchaseParam);

  /// Silent on both stores: StoreKit 2 reads the current entitlements and
  /// Play Billing queries owned purchases.
  @override
  Future<void> restorePurchases() => _iap.restorePurchases();

  @override
  Future<void> completePurchase(PurchaseDetails purchase) => _iap.completePurchase(purchase);
}

final storeGatewayProvider = Provider<StoreGateway>((ref) => InAppPurchaseGateway());

@immutable
class ProState {
  const ProState({
    required this.enforced,
    required this.unlocked,
    this.product,
    this.storeAvailable = false,
    this.busy = false,
    this.error,
  });

  /// Whether this build sells Pro. When false every feature is available.
  final bool enforced;

  /// Whether the user owns Cirrus Pro.
  final bool unlocked;

  /// The Pro product as configured in the store (localized price), once loaded.
  final ProductDetails? product;
  final bool storeAvailable;

  /// A purchase or restore is in progress.
  final bool busy;
  final String? error;

  /// Pro features are usable.
  bool get hasPro => !enforced || unlocked;

  ProState copyWith({
    bool? unlocked,
    ProductDetails? product,
    bool? storeAvailable,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => ProState(
    enforced: enforced,
    unlocked: unlocked ?? this.unlocked,
    product: product ?? this.product,
    storeAvailable: storeAvailable ?? this.storeAvailable,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Owns the Pro entitlement: loads the product, restores past purchases on
/// start, runs purchases and remembers the result on this device. In
/// licence builds it follows [licenseProvider] instead.
class ProController extends Notifier<ProState> {
  static const cacheKey = 'cirrus.pro.v1';

  StoreGateway get _store => ref.read(storeGatewayProvider);

  @override
  ProState build() {
    final channel = ref.watch(storeChannelProvider);
    if (channel == StoreChannel.none) {
      return const ProState(enforced: false, unlocked: true);
    }
    if (channel == StoreChannel.license) {
      // Unlocked only by a verified activation of this device.
      return ProState(enforced: true, unlocked: ref.watch(licenseProvider.select((s) => s.isActive)));
    }
    final cached = ref.read(sharedPrefsProvider).getBool(cacheKey) ?? false;
    final sub = _store.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => state = state.copyWith(busy: false, error: '$e'),
    );
    ref.onDispose(sub.cancel);
    Future<void>.microtask(_load);
    return ProState(enforced: true, unlocked: cached);
  }

  Future<void> _load() async {
    try {
      final available = await _store.isAvailable();
      if (!ref.mounted) return;
      if (!available) {
        state = state.copyWith(storeAvailable: false);
        return;
      }
      final res = await _store.queryProductDetails({proProductId});
      if (!ref.mounted) return;
      state = state.copyWith(
        storeAvailable: true,
        product: res.productDetails.firstWhereOrNull((p) => p.id == proProductId),
        error: res.error?.message,
      );
      // Picks up purchases made earlier or on another device.
      await _store.restorePurchases();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: '$e');
    }
  }

  /// Starts the store's purchase sheet. The outcome arrives on the purchase
  /// stream.
  Future<void> buy() async {
    final product = state.product;
    if (product == null) {
      state = state.copyWith(error: 'The store is not available right now.');
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final started = await _store.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (!started && ref.mounted) state = state.copyWith(busy: false);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: '$e');
    }
  }

  Future<void> restore() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _store.restorePurchases();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: '$e');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.productID == proProductId) {
        switch (p.status) {
          case PurchaseStatus.pending:
            state = state.copyWith(busy: true);
          case PurchaseStatus.purchased || PurchaseStatus.restored:
            await ref.read(sharedPrefsProvider).setBool(cacheKey, true);
            state = state.copyWith(unlocked: true, busy: false, clearError: true);
          case PurchaseStatus.error:
            state = state.copyWith(busy: false, error: p.error?.message ?? 'The purchase failed.');
          case PurchaseStatus.canceled:
            state = state.copyWith(busy: false);
        }
      }
      // Finishes the transaction (and acknowledges it on Google Play, which
      // otherwise refunds it after three days).
      if (p.pendingCompletePurchase) await _store.completePurchase(p);
    }
  }
}

final proProvider = NotifierProvider<ProController, ProState>(ProController.new);

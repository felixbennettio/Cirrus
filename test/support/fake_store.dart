import 'dart:async';

import 'package:cirrus/core/billing/billing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// In-memory stand-in for StoreKit / Play Billing.
class FakeStore implements StoreGateway {
  FakeStore({this.available = true, this.owned = false});

  bool available;

  /// Whether a restore reports an existing Pro purchase.
  bool owned;

  final controller = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <PurchaseDetails>[];
  int buys = 0;
  int restores = 0;

  static final product = ProductDetails(
    id: proProductId,
    title: 'Cirrus Pro',
    description: 'Lifetime',
    price: '¥198.00',
    rawPrice: 198,
    currencyCode: 'CNY',
  );

  PurchaseDetails purchase(PurchaseStatus status, {bool pending = true, String id = proProductId}) => PurchaseDetails(
    productID: id,
    verificationData: PurchaseVerificationData(localVerificationData: '', serverVerificationData: '', source: 'fake'),
    transactionDate: '0',
    status: status,
  )..pendingCompletePurchase = pending;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: [product], notFoundIDs: const []);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    buys++;
    return true;
  }

  @override
  Future<void> restorePurchases() async {
    restores++;
    if (owned) controller.add([purchase(PurchaseStatus.restored, pending: false)]);
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async => completed.add(purchase);
}

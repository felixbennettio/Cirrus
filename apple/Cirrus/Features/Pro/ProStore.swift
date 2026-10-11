import CirrusKit
import StoreKit
import SwiftUI

/// Cirrus Pro through StoreKit 2: a non-consumable bought once. Builds
/// whose `CirrusStore` Info.plist value is not `appstore` are fully unlocked.
@MainActor @Observable
final class ProStore {
    static let cacheKey = "cirrus.pro.v1"

    let channel: StoreChannel
    private(set) var unlocked: Bool
    private(set) var product: Product?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var storeChecked = false
    /// TEMPORARY, remove before App Review: TestFlight (sandbox) builds
    /// unlock Pro while the App Store has no Pro product to sell (the paid
    /// apps agreement is still pending), so Pro features can be tested.
    private(set) var testFlightUnlock = false
    private let defaults: UserDefaults
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        channel = StoreChannel(setting: Bundle.main.object(forInfoDictionaryKey: "CirrusStore") as? String)
        unlocked = defaults.bool(forKey: Self.cacheKey)
    }

    /// Pro is sold (and required) in this build.
    var enforced: Bool { channel == .appStore }

    /// Pro features are usable.
    var hasPro: Bool { !enforced || unlocked || testFlightUnlock }

    func start() {
        guard enforced, updates == nil else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            await loadProduct()
            await refreshEntitlement()
        }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [proProductID]).first
        } catch {
            self.error = describe(error)
        }
        storeChecked = true
        if product == nil, await isSandbox() { testFlightUnlock = true }
    }

    private func isSandbox() async -> Bool {
        guard let result = try? await AppTransaction.shared else { return false }
        switch result {
        case .verified(let t): return t.environment == .sandbox
        case .unverified(let t, _): return t.environment == .sandbox
        }
    }

    /// Reads the current entitlements (purchases on any device of the account).
    func refreshEntitlement() async {
        var owned = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == proProductID, t.revocationDate == nil { owned = true }
        }
        setUnlocked(owned)
    }

    func buy() async {
        guard let product else {
            error = L("The App Store is not available right now.", "App Store 暂时不可用。")
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(result)
            case .pending: error = L("The purchase is waiting for approval.", "购买正在等待批准。")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            self.error = describe(error)
        }
    }

    func restore() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch {
            self.error = describe(error)
        }
        await refreshEntitlement()
        if !unlocked { error = L("No purchase of Cirrus Pro was found.", "没有找到 Cirrus Pro 的购买记录。") }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let t) = result else { return }
        if t.productID == proProductID { setUnlocked(t.revocationDate == nil) }
        await t.finish()
    }

    private func setUnlocked(_ v: Bool) {
        unlocked = v
        defaults.set(v, forKey: Self.cacheKey)
    }
}

extension ProFeature {
    var title: String { label.text }
}

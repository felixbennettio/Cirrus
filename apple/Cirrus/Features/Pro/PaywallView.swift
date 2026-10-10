import CirrusKit
import SwiftUI

/// Explains Cirrus Pro and sells it. [feature] is what the user just tried
/// to use, if any.
struct PaywallView: View {
    var feature: ProFeature?
    @Environment(AppModel.self) private var model

    var body: some View {
        let pro = model.pro
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 92, height: 92)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .circle)
                VStack(spacing: 6) {
                    Text("Cirrus Pro").font(.title.bold())
                    Text(
                        feature.map { f in L("\(f.label.en) is part of Cirrus Pro.", "「\(f.label.zh)」属于 Cirrus Pro 功能。") }
                            ?? L("One purchase, yours for good.", "一次购买，永久使用。")
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ProFeature.allCases) { f in
                        HStack(spacing: 12) {
                            Image(systemName: f.symbol)
                                .frame(width: 24)
                                .foregroundStyle(f == feature ? Color.accentColor : .secondary)
                            Text(f.title).fontWeight(f == feature ? .semibold : .regular)
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))

                if pro.unlocked {
                    Label(L("Cirrus Pro is unlocked", "已解锁 Cirrus Pro"), systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await pro.buy() }
                    } label: {
                        HStack {
                            if pro.busy { ProgressView().controlSize(.small) }
                            Text(buyLabel(pro)).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(pro.busy || pro.product == nil)

                    Button(L("Restore purchase", "恢复购买")) { Task { await pro.restore() } }
                        .disabled(pro.busy)
                }
                if let e = pro.error {
                    Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text(
                    L(
                        "A one-time purchase, not a subscription. Paid through the App Store; restore it on any device signed in to the same Apple Account.",
                        "一次性购买，不是订阅。通过 App Store 付款，在登录同一 Apple 账户的设备上都可以恢复购买。")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .task { if pro.product == nil { await pro.loadProduct() } }
    }

    private func buyLabel(_ pro: ProStore) -> String {
        if let p = pro.product { return L("Unlock for \(p.displayPrice)", "以 \(p.displayPrice) 解锁") }
        return pro.storeChecked ? L("Store unavailable", "商店暂不可用") : L("Loading…", "正在加载…")
    }
}

/// The paywall as a sheet with a close button.
struct PaywallSheet: View {
    var feature: ProFeature?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaywallView(feature: feature)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Close", "关闭"), systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 420, minHeight: 560)
    }
}

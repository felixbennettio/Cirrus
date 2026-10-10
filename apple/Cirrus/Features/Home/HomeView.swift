import CirrusKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openScreen) private var openScreen

    private let quick: [Screen] = [.dns, .cache, .ssl, .analytics, .zoneSettings, .domains]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stats
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Quick access", "快捷入口")).font(.headline)
                    GlassEffectContainer(spacing: 10) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                            ForEach(quick) { s in
                                Button {
                                    openScreen(s)
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: s.symbol).font(.title2).foregroundStyle(.tint)
                                        Text(s == .cache ? L("Purge cache", "清除缓存") : s.title)
                                            .font(.footnote.weight(.medium))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 72)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                                .disabled(s.scope == .zone && model.currentZone == nil)
                            }
                        }
                    }
                }
                zoneList
            }
            .padding()
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .navigationTitle(model.currentAccount?["name"].string ?? "Cirrus")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Refresh", "刷新"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        }
    }

    @ViewBuilder private var stats: some View {
        let zones = model.zones
        if zones.isEmpty && model.zonesLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        } else if let e = model.zonesError, zones.isEmpty {
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else {
            StatGrid(minWidth: 150) {
                StatTile(label: L("Domains", "域名"), value: "\(zones.count)", symbol: "globe")
                StatTile(
                    label: L("Active", "已激活"), value: "\(zones.filter { $0["status"].string == "active" }.count)",
                    symbol: "checkmark.circle")
                StatTile(
                    label: L("Pending", "待激活"), value: "\(zones.filter { $0["status"].string == "pending" }.count)",
                    symbol: "hourglass")
                StatTile(
                    label: L("Paused", "已暂停"), value: "\(zones.filter { $0["paused"].isTrue }.count)",
                    symbol: "pause.circle")
            }
        }
    }

    private var zoneList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Domains", "域名")).font(.headline)
                Spacer()
                Button(L("Manage", "管理")) { openScreen(.domains) }
                    .buttonStyle(.glass)
                    .disabled(model.accountId == nil)
            }
            VStack(spacing: 0) {
                let shown = Array(model.zones.prefix(12))
                ForEach(Array(shown.enumerated()), id: \.offset) { i, z in
                    Button {
                        if let id = z["id"].string { model.setActiveZone(id) }
                        openScreen(.zoneOverview)
                    } label: {
                        HStack {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(z["name"].string ?? "").fontWeight(.medium)
                                Text(z["plan"]["name"].string ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ZoneStatusBadge(zone: z)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if i < shown.count - 1 { Divider().padding(.leading, 44) }
                }
                if model.zones.isEmpty && !model.zonesLoading {
                    Text(L("No domains in this account yet.", "该账户还没有域名。"))
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}

/// A soft colour wash behind glass content, so the glass has something to refract.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(white: scheme == .dark ? 0.06 : 0.97)
            RadialGradient(
                colors: [Color.orange.opacity(scheme == .dark ? 0.28 : 0.22), .clear], center: .topLeading,
                startRadius: 20, endRadius: 520)
            RadialGradient(
                colors: [Color.blue.opacity(scheme == .dark ? 0.26 : 0.18), .clear], center: .bottomTrailing,
                startRadius: 20, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

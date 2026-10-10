import CirrusKit
import SwiftUI

/// Every page reachable from the sidebar (or the tabs on iPhone).
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case home, domains
    case zoneOverview, dns, ssl, cache, zoneSettings, analytics
    case settings

    var id: String { rawValue }

    enum Scope { case global, account, zone }

    var scope: Scope {
        switch self {
        case .home, .settings: return .global
        case .domains: return .account
        default: return .zone
        }
    }

    var title: String {
        switch self {
        case .home: return L("Home", "首页")
        case .domains: return L("Domains", "域名")
        case .zoneOverview: return L("Zone overview", "域名概览")
        case .dns: return L("DNS", "DNS 记录")
        case .ssl: return "SSL/TLS"
        case .cache: return L("Caching", "缓存")
        case .zoneSettings: return L("Zone settings", "域名设置")
        case .analytics: return L("Analytics", "分析")
        case .settings: return L("Settings", "设置")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .domains: return "globe"
        case .zoneOverview: return "gauge.with.dots.needle.33percent"
        case .dns: return "server.rack"
        case .ssl: return "lock.shield"
        case .cache: return "arrow.triangle.2.circlepath"
        case .zoneSettings: return "slider.horizontal.3"
        case .analytics: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }

    static let zoneScreens: [Screen] = [.zoneOverview, .dns, .ssl, .cache, .zoneSettings, .analytics]
}

/// The page for a screen.
struct ScreenView: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .home: HomeView()
        case .domains: DomainsView()
        case .zoneOverview: ZoneRequired { ZoneOverviewView(zone: $0) }
        case .dns: ZoneRequired { DNSView(zone: $0) }
        case .ssl: ZoneRequired { SSLView(zone: $0) }
        case .cache: ZoneRequired { CacheView(zone: $0) }
        case .zoneSettings: ZoneRequired { ZoneSettingsView(zone: $0) }
        case .analytics: ZoneRequired { AnalyticsView(zone: $0) }
        case .settings: SettingsView()
        }
    }
}

/// Opens a screen: selects it in the sidebar, or pushes it on iPhone.
struct OpenScreenAction {
    var action: (Screen) -> Void
    func callAsFunction(_ screen: Screen) { action(screen) }
}

extension EnvironmentValues {
    @Entry var openScreen = OpenScreenAction { _ in }
}

/// The current zone's id and name, for zone pages.
struct ZoneRef: Hashable {
    var id: String
    var name: String
}

/// Shows [content] for the current zone, or why there is none. The content
/// is rebuilt when the zone changes.
struct ZoneRequired<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: (ZoneRef) -> Content

    var body: some View {
        if let id = model.zoneId {
            content(ZoneRef(id: id, name: model.zoneName)).id(id)
        } else if model.zonesLoading || model.accountsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = model.zonesError ?? model.accountsError {
            ContentUnavailableView {
                Label(L("Couldn't load zones", "无法加载域名"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(e)
            } actions: {
                Button(L("Try again", "重试")) { Task { await model.refresh() } }.buttonStyle(.glass)
            }
        } else {
            ContentUnavailableView(
                L("No zones", "没有域名"), systemImage: "globe",
                description: Text(L("Add a domain to this account first.", "请先在该账户中添加域名。")))
        }
    }
}

/// The zone switcher in a zone page's toolbar.
struct ZoneToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) { ZoneSwitchButton() }
    }
}

struct ZoneSwitchButton: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Label(model.zoneName.isEmpty ? L("Zone", "域名") : model.zoneName, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .frame(maxWidth: 200)
        }
        .help(L("Switch zone", "切换域名"))
        .sheet(isPresented: $picking) { ZonePicker() }
    }
}

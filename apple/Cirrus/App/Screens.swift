import CirrusKit
import SwiftUI

/// Every page reachable from the sidebar (or the tabs on iPhone).
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case home, domains
    case zoneOverview, dns, ssl, security, rules, cache, zoneSettings, analytics, workersRoutes, email, zoneMore
    case workers, pages, ai, computeMore
    case kv, r2, d1, storageMore
    case tunnels, access, gateway, devices, networks, ztMore
    case members, tokens, audit, registrar, lists, notifications, accountMore
    case console, graphql, requests, settings

    var id: String { rawValue }

    enum Scope { case global, account, zone }

    var scope: Scope {
        switch self {
        case .home, .settings, .tokens, .console, .graphql, .requests: return .global
        case .zoneOverview, .dns, .ssl, .security, .rules, .cache, .zoneSettings, .analytics, .workersRoutes, .email, .zoneMore:
            return .zone
        default: return .account
        }
    }

    var title: String {
        switch self {
        case .home: return L("Home", "首页")
        case .domains: return L("Domains", "域名")
        case .zoneOverview: return L("Zone overview", "域名概览")
        case .dns: return L("DNS", "DNS 记录")
        case .ssl: return "SSL/TLS"
        case .security: return L("Security & WAF", "安全与 WAF")
        case .rules: return L("Rules", "规则")
        case .cache: return L("Caching", "缓存")
        case .zoneSettings: return L("Zone settings", "域名设置")
        case .analytics: return L("Analytics", "分析")
        case .workersRoutes: return L("Workers routes", "Workers 路由")
        case .email: return L("Email Routing", "邮件路由")
        case .zoneMore: return L("More zone features", "更多域名功能")
        case .workers: return "Workers"
        case .pages: return "Pages"
        case .ai: return "Workers AI"
        case .computeMore: return L("More compute", "更多计算服务")
        case .kv: return "Workers KV"
        case .r2: return L("R2", "R2 对象存储")
        case .d1: return L("D1", "D1 数据库")
        case .storageMore: return L("More storage", "更多存储服务")
        case .tunnels: return L("Tunnels", "隧道")
        case .access: return L("Access", "Access 访问控制")
        case .gateway: return L("Gateway", "Gateway 网关")
        case .devices: return L("Devices (WARP)", "设备（WARP）")
        case .networks: return L("Networks", "网络")
        case .ztMore: return L("More Zero Trust", "更多 Zero Trust")
        case .members: return L("Members", "成员")
        case .tokens: return L("API tokens", "API Token")
        case .audit: return L("Audit log", "审计日志")
        case .registrar: return L("Registrar", "域名注册")
        case .lists: return L("Lists", "列表")
        case .notifications: return L("Notifications", "通知")
        case .accountMore: return L("More account features", "更多账户功能")
        case .console: return L("API console", "API 控制台")
        case .graphql: return L("GraphQL explorer", "GraphQL 查询")
        case .requests: return L("Request log", "请求日志")
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
        case .security: return "shield.lefthalf.filled"
        case .rules: return "arrow.triangle.branch"
        case .cache: return "arrow.triangle.2.circlepath"
        case .zoneSettings: return "slider.horizontal.3"
        case .analytics: return "chart.bar.xaxis"
        case .workersRoutes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .email: return "at"
        case .zoneMore, .computeMore, .storageMore, .ztMore, .accountMore: return "square.grid.3x2"
        case .workers: return "bolt"
        case .pages: return "macwindow"
        case .ai: return "sparkles"
        case .kv: return "key"
        case .r2: return "shippingbox"
        case .d1: return "tablecells"
        case .tunnels: return "point.3.connected.trianglepath.dotted"
        case .access: return "person.badge.shield.checkmark"
        case .gateway: return "line.3.horizontal.decrease.circle"
        case .devices: return "laptopcomputer.and.iphone"
        case .networks: return "network"
        case .members: return "person.2"
        case .tokens: return "key.horizontal"
        case .audit: return "clock.arrow.circlepath"
        case .registrar: return "storefront"
        case .lists: return "list.bullet.rectangle"
        case .notifications: return "bell"
        case .console: return "terminal"
        case .graphql: return "chart.xyaxis.line"
        case .requests: return "list.bullet.rectangle.portrait"
        case .settings: return "gearshape"
        }
    }

    /// Words that find the screen in search.
    var keywords: [String] {
        switch self {
        case .dns: return ["records", "cname", "mx", "txt", "dnssec", "解析"]
        case .ssl: return ["certificate", "https", "hsts", "origin ca", "证书"]
        case .security: return ["firewall", "waf", "rate limit", "bot", "ip access", "防火墙", "限速"]
        case .rules: return ["redirect", "rewrite", "transform", "origin rules", "page rules", "重定向", "重写"]
        case .cache: return ["purge", "cache rules", "清除缓存"]
        case .zoneSettings: return ["speed", "network", "brotli", "http3", "ipv6", "速度", "网络"]
        case .analytics: return ["traffic", "requests", "bandwidth", "流量"]
        case .email: return ["email", "forward", "转发"]
        case .workers: return ["scripts", "serverless", "deploy", "tail", "logs", "部署", "日志"]
        case .tunnels: return ["cloudflared", "public hostname", "ingress", "内网穿透"]
        case .access: return ["applications", "policies", "service tokens", "idp", "sso"]
        case .tokens: return ["token", "permissions", "权限"]
        case .console: return ["api", "endpoint", "explorer", "调试"]
        case .settings: return ["profiles", "theme", "language", "lock", "主题", "语言"]
        default: return []
        }
    }

    static let zoneScreens: [Screen] = [
        .zoneOverview, .dns, .ssl, .security, .rules, .cache, .zoneSettings, .analytics, .workersRoutes, .email, .zoneMore,
    ]
    static let computeScreens: [Screen] = [.workers, .pages, .ai, .computeMore]
    static let storageScreens: [Screen] = [.kv, .r2, .d1, .storageMore]
    static let zeroTrustScreens: [Screen] = [.tunnels, .access, .gateway, .devices, .networks, .ztMore]
    static let accountScreens: [Screen] = [.members, .tokens, .audit, .registrar, .lists, .notifications, .accountMore]
    static let toolScreens: [Screen] = [.console, .graphql, .requests, .settings]

    /// The Cirrus Pro feature the screen belongs to (nil when free).
    var proFeature: ProFeature? {
        switch self {
        case .workers, .pages, .ai, .computeMore: return .compute
        case .kv, .r2, .d1, .storageMore: return .storage
        case .tunnels, .access, .gateway, .devices, .networks, .ztMore: return .zeroTrust
        case .members, .tokens, .audit, .registrar, .lists, .notifications, .accountMore: return .account
        case .graphql: return .graphql
        default: return nil
        }
    }
}

/// The page for a screen.
struct ScreenView: View {
    let screen: Screen
    @Environment(AppModel.self) private var model

    var body: some View {
        switch screen {
        case .home: HomeView()
        case .domains: DomainsView()
        case .zoneOverview: ZoneRequired { ZoneOverviewView(zone: $0) }
        case .dns: ZoneRequired { DNSView(zone: $0) }
        case .ssl: ZoneRequired { SSLView(zone: $0) }
        case .security: ZoneRequired { SecurityView(zone: $0) }
        case .rules: ZoneRequired { RulesView(zone: $0) }
        case .cache: ZoneRequired { CacheView(zone: $0) }
        case .zoneSettings: ZoneRequired { ZoneSettingsView(zone: $0) }
        case .analytics: ZoneRequired { AnalyticsView(zone: $0) }
        case .email: ZoneRequired { EmailRoutingView(zone: $0) }
        case .workersRoutes: specPage("zone_worker_routes")
        case .zoneMore:
            ResourceHubView(
                title: screen.title, specs: model.resources.specs(in: "zone").filter { $0.id != "zone_worker_routes" },
                documents: model.resources.documents(scope: .zone))
        case .workers: account(.compute) { WorkersView(accountId: $0) }
        case .pages: account(.compute) { PagesView(accountId: $0) }
        case .ai: account(.compute) { AIView(accountId: $0) }
        case .computeMore: ProGate(feature: .compute) { ResourceHubView(title: screen.title, specs: model.resources.specs(in: "compute")) }
        case .kv: account(.storage) { KVView(accountId: $0) }
        case .r2: account(.storage) { R2View(accountId: $0) }
        case .d1: account(.storage) { D1View(accountId: $0) }
        case .storageMore: ProGate(feature: .storage) { ResourceHubView(title: screen.title, specs: model.resources.specs(in: "storage")) }
        case .tunnels: account(.zeroTrust) { TunnelsView(accountId: $0) }
        case .access: tabs(.zeroTrust, "access", documents: ["access_organization"])
        case .gateway: tabs(.zeroTrust, "gateway", documents: ["gateway_configuration", "gateway_logging"])
        case .devices:
            tabs(
                .zeroTrust, "devices",
                documents: ["device_default_profile", "split_tunnel_exclude", "split_tunnel_include", "fallback_domains", "device_settings"])
        case .networks: tabs(.zeroTrust, "networks", documents: [])
        case .ztMore:
            ProGate(feature: .zeroTrust) {
                ResourceHubView(
                    title: screen.title, specs: model.resources.specs(in: "zeroTrustMore"),
                    documents: model.resources.document("access_organization").map { [$0] } ?? [])
            }
        case .members: account(.account) { MembersView(accountId: $0) }
        case .tokens: ProGate(feature: .account) { TokensView() }
        case .audit: account(.account) { AuditLogView(accountId: $0) }
        case .registrar: ProGate(feature: .account) { specPage("registrar_domains") }
        case .lists: account(.account) { ListsView(accountId: $0) }
        case .notifications:
            ProGate(feature: .account) {
                TabbedResourcesView(
                    title: screen.title,
                    tabs: ["alert_policies", "alert_webhooks", "alert_history"].compactMap { model.resources.spec($0).map(ResourceTab.spec) }
                        + (model.resources.document("available_alerts").map { [ResourceTab.document($0)] } ?? []))
            }
        case .accountMore:
            ProGate(feature: .account) {
                ResourceHubView(
                    title: screen.title,
                    specs: model.resources.specs(in: "account").filter {
                        !["registrar_domains", "alert_policies", "alert_webhooks", "alert_history"].contains($0.id)
                    },
                    documents: model.resources.documents(group: "Account"))
            }
        case .console: ConsoleView()
        case .graphql: ProGate(feature: .graphql) { GraphQLView() }
        case .requests: RequestLogView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private func specPage(_ id: String) -> some View {
        if let spec = model.resources.spec(id) {
            ResourceListView(spec: spec).navigationTitle(spec.title.text)
        } else {
            EmptyState(title: id, symbol: "questionmark.circle")
        }
    }

    private func tabs(_ feature: ProFeature, _ list: String, documents: [String]) -> some View {
        let specTabs = model.resources.specs(in: list).map(ResourceTab.spec)
        let docTabs = documents.compactMap { model.resources.document($0).map(ResourceTab.document) }
        return ProGate(feature: feature) { TabbedResourcesView(title: screen.title, tabs: specTabs + docTabs) }
    }
}

extension ScreenView {
    /// An account page that needs Cirrus Pro.
    private func account<C: View>(_ feature: ProFeature, @ViewBuilder _ content: @escaping (String) -> C) -> some View {
        ProGate(feature: feature) { AccountRequired(content: content) }
            .navigationTitle(screen.title)
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

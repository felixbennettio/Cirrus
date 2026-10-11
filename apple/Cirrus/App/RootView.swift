import CirrusKit
import SwiftUI

/// Onboarding until a credential exists, then the app.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.started {
                ProgressView()
            } else if model.profiles.isEmpty {
                NavigationStack { AddProfileView(firstRun: true) }
            } else {
                MainView()
            }
        }
        .modifier(ToastOverlay(feedback: model.feedback))
        .modifier(AppLockModifier())
        .preferredColorScheme(model.colorScheme)
        .environment(\.locale, model.settings.language.locale)
        // Strings are looked up when views are built: rebuild on a language change.
        .id(model.settings.language)
        .task { await model.start() }
    }
}

/// A sidebar on Mac and iPad, tabs on iPhone.
struct MainView: View {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
            if sizeClass == .compact {
                PhoneTabs()
            } else {
                SplitMain()
            }
        #else
            SplitMain()
        #endif
    }
}

struct SplitMain: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Screen? = .home

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                ScreenView(screen: selection ?? .home)
                    .navigationDestination(for: Screen.self) { ScreenView(screen: $0) }
            }
            .id(selection)
        }
        .environment(\.openScreen, OpenScreenAction { selection = $0 })
    }
}

struct Sidebar: View {
    @Binding var selection: Screen?
    @Environment(AppModel.self) private var model
    @State private var searching = false

    var body: some View {
        List(selection: $selection) {
            Section {
                AccountSwitcherRow()
                ZoneSwitcherRow()
            }
            Section(L("Overview", "概览")) {
                row(.home)
                if model.accountId != nil { row(.domains) }
            }
            if model.currentZone != nil {
                Section(model.zoneName) {
                    ForEach(Screen.zoneScreens) { row($0) }
                }
            }
            if model.accountId != nil {
                section(L("Compute & AI", "计算与 AI"), Screen.computeScreens)
                section(L("Storage & Databases", "存储与数据库"), Screen.storageScreens)
                section("Zero Trust", Screen.zeroTrustScreens)
                section(L("Account", "账户"), Screen.accountScreens)
            } else {
                section(L("Account", "账户"), [.tokens])
            }
            section(L("Tools", "工具"), Screen.toolScreens)
        }
        .listStyle(.sidebar)
        .navigationTitle("Cirrus")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Search", "搜索"), systemImage: "magnifyingglass") { searching = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        .sheet(isPresented: $searching) {
            NavigationStack { SearchView() }
                .frame(minWidth: 560, minHeight: 600)
        }
    }

    private func section(_ title: String, _ screens: [Screen]) -> some View {
        Section(title) {
            ForEach(screens) { row($0) }
        }
    }

    private func row(_ s: Screen) -> some View {
        NavigationLink(value: s) {
            HStack {
                Label(s.title, systemImage: s.symbol)
                if s.proFeature != nil && !model.pro.hasPro {
                    Spacer()
                    ProBadge()
                }
            }
        }
    }
}

#if os(iOS)
    /// iPhone: Home, the current zone, account services, settings and search as tabs.
    struct PhoneTabs: View {
        enum TabID: Hashable { case home, zone, services, settings, search }

        @State private var tab: TabID = .home
        @State private var homePath = NavigationPath()
        @State private var zonePath = NavigationPath()
        @State private var servicesPath = NavigationPath()
        @State private var settingsPath = NavigationPath()
        @State private var searchPath = NavigationPath()

        var body: some View {
            TabView(selection: $tab) {
                Tab(L("Home", "首页"), systemImage: "square.grid.2x2", value: TabID.home) {
                    NavigationStack(path: $homePath) { HomeView().destinations() }
                }
                Tab(L("Zone", "域名"), systemImage: "globe", value: TabID.zone) {
                    NavigationStack(path: $zonePath) { ZoneHubView().destinations() }
                }
                Tab(L("Services", "服务"), systemImage: "square.stack.3d.up", value: TabID.services) {
                    NavigationStack(path: $servicesPath) { ServicesHubView().destinations() }
                }
                Tab(L("Settings", "设置"), systemImage: "gearshape", value: TabID.settings) {
                    NavigationStack(path: $settingsPath) { SettingsView().destinations() }
                }
                Tab(L("Search", "搜索"), systemImage: "magnifyingglass", value: TabID.search, role: .search) {
                    NavigationStack(path: $searchPath) { SearchView().destinations() }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .environment(\.openScreen, OpenScreenAction(action: open))
        }

        private func open(_ s: Screen) {
            switch s {
            case .home: tab = .home
            case .settings: tab = .settings
            case .domains:
                tab = .home
                homePath = NavigationPath([s])
            default:
                if s.scope == .zone {
                    if tab == .zone {
                        zonePath.append(s)
                    } else {
                        tab = .zone
                        zonePath = NavigationPath([s])
                    }
                } else if tab == .services {
                    servicesPath.append(s)
                } else {
                    tab = .services
                    servicesPath = NavigationPath([s])
                }
            }
        }
    }
#endif

extension View {
    func destinations() -> some View {
        navigationDestination(for: Screen.self) { ScreenView(screen: $0) }
    }
}

/// The current zone with links to its pages (the Zone tab on iPhone).
struct ZoneHubView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        List {
            Section {
                Button {
                    picking = true
                } label: {
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.tint).font(.title2)
                        VStack(alignment: .leading) {
                            Text(model.currentZone == nil ? L("No zone", "没有域名") : model.zoneName)
                                .font(.headline)
                            if let z = model.currentZone {
                                Text(z["plan"]["name"].string ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let z = model.currentZone { ZoneStatusBadge(zone: z) }
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if model.currentZone != nil {
                Section {
                    ForEach(Screen.zoneScreens) { s in
                        NavigationLink(value: s) { Label(s.title, systemImage: s.symbol) }
                    }
                }
            }
            Section {
                NavigationLink(value: Screen.domains) { Label(L("All domains", "全部域名"), systemImage: "list.bullet") }
            }
        }
        .navigationTitle(L("Zone", "域名"))
        .refreshable { await model.loadZones(force: true) }
        .sheet(isPresented: $picking) { ZonePicker() }
    }
}

/// Account services and tools (the Services tab on iPhone).
struct ServicesHubView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section(L("Domains", "域名")) { link(.domains) }
            Section(L("Compute & AI", "计算与 AI")) { ForEach(Screen.computeScreens) { link($0) } }
            Section(L("Storage & Databases", "存储与数据库")) { ForEach(Screen.storageScreens) { link($0) } }
            Section("Zero Trust") { ForEach(Screen.zeroTrustScreens) { link($0) } }
            Section(L("Account", "账户")) { ForEach(Screen.accountScreens) { link($0) } }
            Section(L("Tools", "工具")) { ForEach(Screen.toolScreens.filter { $0 != .settings }) { link($0) } }
        }
        .navigationTitle(L("Services", "服务"))
    }

    private func link(_ s: Screen) -> some View {
        NavigationLink(value: s) {
            HStack {
                Label(s.title, systemImage: s.symbol)
                if s.proFeature != nil && !model.pro.hasPro {
                    Spacer()
                    ProBadge()
                }
            }
        }
    }
}

/// A small "PRO" tag on Pro-only entries.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.tint)
            .background(Color.accentColor.opacity(0.15), in: .capsule)
    }
}

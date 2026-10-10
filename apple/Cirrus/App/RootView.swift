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
            Section(L("Tools", "工具")) {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Cirrus")
        .refreshable { await model.refresh() }
    }

    private func row(_ s: Screen) -> some View {
        NavigationLink(value: s) {
            Label(s.title, systemImage: s.symbol)
        }
    }
}

#if os(iOS)
    /// iPhone: Home, the current zone, domains and settings as tabs.
    struct PhoneTabs: View {
        enum TabID: Hashable { case home, zone, domains, settings }

        @State private var tab: TabID = .home
        @State private var homePath = NavigationPath()
        @State private var zonePath = NavigationPath()
        @State private var domainsPath = NavigationPath()
        @State private var settingsPath = NavigationPath()

        var body: some View {
            TabView(selection: $tab) {
                Tab(L("Home", "首页"), systemImage: "square.grid.2x2", value: TabID.home) {
                    NavigationStack(path: $homePath) { HomeView().destinations() }
                }
                Tab(L("Zone", "域名"), systemImage: "globe", value: TabID.zone) {
                    NavigationStack(path: $zonePath) { ZoneHubView().destinations() }
                }
                Tab(L("Domains", "全部域名"), systemImage: "list.bullet", value: TabID.domains) {
                    NavigationStack(path: $domainsPath) { DomainsView().destinations() }
                }
                Tab(L("Settings", "设置"), systemImage: "gearshape", value: TabID.settings) {
                    NavigationStack(path: $settingsPath) { SettingsView().destinations() }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .environment(\.openScreen, OpenScreenAction(action: open))
        }

        private func open(_ s: Screen) {
            switch s {
            case .home: tab = .home
            case .domains: tab = .domains
            case .settings: tab = .settings
            default:
                if tab == .zone {
                    zonePath.append(s)
                } else {
                    tab = .zone
                    zonePath = NavigationPath([s])
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
        }
        .navigationTitle(L("Zone", "域名"))
        .refreshable { await model.loadZones(force: true) }
        .sheet(isPresented: $picking) { ZonePicker() }
    }
}

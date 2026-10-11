import CirrusKit
import SwiftUI

/// The app's state: credentials, settings, the active account and zone,
/// and the API client for them.
@MainActor @Observable
final class AppModel {
    static let settingsKey = "cirrus.settings.v1"

    let keychain: KeychainStore
    let defaults = UserDefaults.standard
    let sessions: OAuthSessions
    let disk = DiskCache.standard
    let requestLog = RequestLog()

    let feedback = Feedback()
    let pro: ProStore
    /// The generic resource pages' specs (`Resources/resources.json`).
    let resources: ResourceCatalog = AppModel.loadResources()
    let catalog = CatalogStore()
    /// The most recent API requests (Request log), newest first.
    private(set) var requests: [RequestRecord] = []
    /// Requests sent from the API console in this session.
    var consoleHistory: [ConsoleHistoryEntry] = []

    private(set) var settings: AppSettings
    private(set) var profiles: [Profile] = []
    private(set) var started = false
    private(set) var client: CFClient?

    private(set) var accounts: [JSON] = []
    private(set) var accountsLoading = false
    private(set) var accountsError: String?
    private(set) var zones: [JSON] = []
    private(set) var zonesLoading = false
    private(set) var zonesError: String?
    /// The account the zone list belongs to.
    @ObservationIgnored private var zonesAccount: String??

    init() {
        let keychain = KeychainStore()
        let defaults = UserDefaults.standard
        FlutterImport.runIfNeeded(keychain: keychain, defaults: defaults)
        self.keychain = keychain
        sessions = OAuthSessions(store: keychain)
        settings = AppSettings.decode(defaults.string(forKey: Self.settingsKey))
        pro = ProStore(defaults: defaults)
        AppLanguage.current = settings.language
        CFClient.userAgent = "Cirrus/" + AppInfo.version
        requestLog.onChange = { [weak self] records in
            Task { @MainActor in self?.requests = records }
        }
    }

    private static func loadResources() -> ResourceCatalog {
        guard let url = Bundle.main.url(forResource: "resources", withExtension: "json"), let data = try? Data(contentsOf: url),
            let json = try? JSON.parse(data)
        else { return ResourceCatalog(json: [:]) }
        return ResourceCatalog(json: json)
    }

    /// Values for `{account_id}` and `{zone_id}` in path templates.
    var scopeIds: [String: String?] { ["account_id": accountId, "zone_id": zoneId] }

    func toggleFavorite(_ opId: String) {
        update { s in
            if let i = s.favoriteOps.firstIndex(of: opId) { s.favoriteOps.remove(at: i) } else { s.favoriteOps.append(opId) }
        }
    }

    // MARK: Start

    func start() async {
        guard !started else { return }
        profiles = keychain.loadProfiles()
        started = true
        pro.start()
        await activateProfile()
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        defaults.set(s.encoded(), forKey: Self.settingsKey)
        AppLanguage.current = s.language
    }

    var colorScheme: ColorScheme? {
        switch settings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: Profiles

    var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileId } ?? profiles.first
    }

    func setActiveProfile(_ id: String?) {
        update { $0.activeProfileId = id }
        Task { await activateProfile() }
    }

    /// Saves [profile] (new or edited) and makes it the active one.
    func upsert(_ profile: Profile, activate: Bool = true) throws {
        var list = profiles
        if let i = list.firstIndex(where: { $0.id == profile.id }) {
            list[i] = profile
        } else {
            list.append(profile)
        }
        try keychain.saveProfiles(list)
        profiles = list
        if activate || profile.id == activeProfile?.id {
            update { $0.activeProfileId = profile.id }
            Task { await activateProfile() }
        }
    }

    /// Removes [profile]; OAuth grants are revoked.
    func remove(_ profile: Profile) async {
        if profile.kind == .oauth { await sessions.remove(profile) }
        let list = profiles.filter { $0.id != profile.id }
        try? keychain.saveProfiles(list)
        profiles = list
        clearCaches()
        if settings.activeProfileId == profile.id || !list.contains(where: { $0.id == settings.activeProfileId }) {
            setActiveProfile(list.first?.id)
        }
    }

    /// Builds the client for the active profile and loads its accounts.
    func activateProfile() async {
        guard let p = activeProfile else {
            client = nil
            accounts = []
            zones = []
            return
        }
        var tokens: AccessTokenSource?
        if p.kind == .oauth { tokens = await sessions.session(for: p) }
        client = CFClient(profile: p, tokens: tokens, log: requestLog)
        accounts = []
        zones = []
        zonesAccount = nil
        accountsError = nil
        zonesError = nil
        await loadAccounts()
    }

    // MARK: Accounts

    var currentAccount: JSON? {
        guard let p = activeProfile, !accounts.isEmpty else { return nil }
        let id = settings.activeAccount[p.id]
        return accounts.first { $0["id"].string == id }
            ?? accounts.first { $0["id"].string == p.accountId }
            ?? accounts.first
    }

    var accountId: String? { currentAccount?["id"].string }

    func setActiveAccount(_ id: String) {
        guard let p = activeProfile else { return }
        update { $0.activeAccount[p.id] = id }
        Task { await loadZones() }
    }

    /// Loads the accounts (the cached list first, then a fresh one).
    func loadAccounts(force: Bool = false) async {
        guard let client else { return }
        let key = "accounts:" + client.profile.id
        if !force, accounts.isEmpty, let cached = disk.read(key)?.array, !cached.isEmpty {
            accounts = cached
            Task { await loadZones() }
        }
        accountsLoading = true
        defer { if client === self.client { accountsLoading = false } }
        do {
            var list = try await client.list("/accounts", perPage: 50, maxItems: 1000)
            list.sort { ($0["name"].string ?? "").lowercased() < ($1["name"].string ?? "").lowercased() }
            guard client === self.client else { return }
            let before = accountId
            accounts = list
            accountsError = nil
            disk.write(key, .array(list))
            if force || accountId != before || zonesAccount != .some(accountId) { await loadZones(force: force) }
        } catch {
            guard client === self.client else { return }
            accountsError = describe(error)
            if accounts.isEmpty { await loadZones() }
        }
    }

    // MARK: Zones

    var currentZone: JSON? {
        guard !zones.isEmpty else { return nil }
        let id = settings.activeZone[accountId ?? "-"]
        return zones.first { $0["id"].string == id } ?? zones.first
    }

    var zoneId: String? { currentZone?["id"].string }
    var zoneName: String { currentZone?["name"].string ?? "" }

    func setActiveZone(_ id: String) {
        update { $0.activeZone[accountId ?? "-"] = id }
    }

    /// Loads the zones of the current account (cached first).
    func loadZones(force: Bool = false) async {
        guard let client else { return }
        let account = accountId
        let key = "zones:\(client.profile.id):\(account ?? "-")"
        if zonesAccount != .some(account) {
            zones = disk.read(key)?.array ?? []
            zonesAccount = .some(account)
            zonesError = nil
        }
        zonesLoading = true
        defer { if client === self.client { zonesLoading = false } }
        do {
            let list = try await client.list(
                "/zones", query: ["account.id": account, "order": "name", "direction": "asc"], perPage: 50,
                maxItems: 5000)
            guard client === self.client, account == accountId else { return }
            zones = list
            zonesError = nil
            disk.write(key, .array(list))
        } catch {
            guard client === self.client, account == accountId else { return }
            zonesError = describe(error)
        }
    }

    func refresh() async {
        await loadAccounts(force: true)
    }

    func clearCaches() {
        QueryCache.shared.clear()
        disk.clear()
    }

    // MARK: Actions

    /// Runs an API action: errors become a toast, [success] is shown when
    /// it worked. Returns nil on failure.
    @discardableResult
    func run<T>(_ success: String? = nil, _ action: () async throws -> T) async -> T? {
        do {
            let r = try await action()
            if let success { feedback.show(success) }
            return r
        } catch {
            feedback.error(error)
            return nil
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}

/// Moves the Flutter app's data (same App Store app) over on first launch.
@MainActor
enum FlutterImport {
    static let doneKey = "cirrus.native.imported.v1"

    static func runIfNeeded(keychain: KeychainStore, defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if keychain.loadProfiles().isEmpty, let raw = FlutterKeychain.read(FlutterAppData.profilesKey) {
            let profiles = FlutterAppData.parseProfiles(raw)
            if !profiles.isEmpty, (try? keychain.saveProfiles(profiles)) != nil {
                for p in profiles where p.kind == .oauth {
                    let key = FlutterAppData.tokensKey(p.id)
                    if let tokens = FlutterKeychain.read(key), FlutterAppData.parseTokens(tokens) != nil {
                        try? keychain.write(key, tokens)
                    }
                }
            }
        }
        if defaults.string(forKey: AppModel.settingsKey) == nil,
            let raw = defaults.string(forKey: FlutterAppData.settingsKey)
        {
            defaults.set(AppSettings.decode(raw).encoded(), forKey: AppModel.settingsKey)
        }
        if defaults.bool(forKey: FlutterAppData.proKey) { defaults.set(true, forKey: ProStore.cacheKey) }
    }
}

/// A request sent from the API console.
struct ConsoleHistoryEntry: Identifiable {
    let id = UUID()
    var opId: String
    var method: String
    var path: String
    var status: Int
    var at: Date
}

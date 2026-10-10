import Foundation

/// Light, dark or following the system.
public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

/// The app's preferences. The JSON form is the Flutter app's (so its
/// settings can be imported); keys it doesn't know are ignored.
public struct AppSettings: Codable, Hashable, Sendable {
    public var themeMode: ThemeMode = .system
    /// `nil` follows the system language.
    public var localeCode: String?
    public var appLock = false
    public var activeProfileId: String?
    /// Last selected account per profile id.
    public var activeAccount: [String: String] = [:]
    /// Last selected zone per account id.
    public var activeZone: [String: String] = [:]
    public var favoriteOps: [String] = []
    /// Ask before sending POST/PUT/PATCH/DELETE from the API console.
    public var confirmMutations = true

    public init() {}

    public var language: AppLanguage { AppLanguage.resolve(localeCode) }

    enum CodingKeys: String, CodingKey {
        case themeMode, localeCode, appLock, activeProfileId, activeAccount, activeZone, favoriteOps, confirmMutations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themeMode = (try? c.decodeIfPresent(ThemeMode.self, forKey: .themeMode)) ?? .system
        localeCode = try? c.decodeIfPresent(String.self, forKey: .localeCode)
        appLock = (try? c.decodeIfPresent(Bool.self, forKey: .appLock)) ?? false
        activeProfileId = try? c.decodeIfPresent(String.self, forKey: .activeProfileId)
        activeAccount = (try? c.decodeIfPresent([String: String].self, forKey: .activeAccount)) ?? [:]
        activeZone = (try? c.decodeIfPresent([String: String].self, forKey: .activeZone)) ?? [:]
        favoriteOps = (try? c.decodeIfPresent([String].self, forKey: .favoriteOps)) ?? []
        confirmMutations = (try? c.decodeIfPresent(Bool.self, forKey: .confirmMutations)) ?? true
    }

    /// Reads settings JSON, falling back to the defaults.
    public static func decode(_ raw: String?) -> AppSettings {
        guard let raw, let data = raw.data(using: .utf8),
            let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    public func encoded() -> String {
        let data = (try? JSONEncoder.compact.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where the Flutter app (the same App Store record) kept its data, for the
/// one-time import on the native app's first launch.
public enum FlutterAppData {
    /// flutter_secure_storage's default Keychain service.
    public static let keychainService = "flutter_secure_storage_service"
    public static let profilesKey = "cirrus.profiles.v1"
    public static func tokensKey(_ profileId: String) -> String { "cirrus.oauth.\(profileId)" }
    /// shared_preferences keys carry this prefix in UserDefaults.
    public static let settingsKey = "flutter.cirrus.settings.v1"
    public static let proKey = "flutter.cirrus.pro.v1"
    public static let remoteOAuthKey = "flutter.cirrus.oauth.remoteConfig.v1"

    /// The profiles in the Flutter app's JSON (an array of objects).
    public static func parseProfiles(_ raw: String?) -> [Profile] {
        guard let raw, let data = raw.data(using: .utf8),
            let json = try? JSON.parse(data), case .array(let items) = json
        else { return [] }
        return items.compactMap { item in
            guard item.object != nil else { return nil }
            return try? JSONDecoder().decode(Profile.self, from: item.encoded())
        }
    }

    public static func parseTokens(_ raw: String?) -> OAuthTokens? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
}

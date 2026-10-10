import Foundation

/// How a profile authenticates against the Cloudflare API.
public enum AuthKind: String, Codable, Sendable, CaseIterable {
    /// `Authorization: Bearer <token>`: a user- or account-owned API token.
    case apiToken
    /// `X-Auth-Email` + `X-Auth-Key`: the legacy Global API Key.
    case globalKey
    /// `Authorization: Bearer <access token>` from Cloudflare OAuth. The
    /// tokens live in an `OAuthSession`, not in the profile.
    case oauth
}

/// A saved set of credentials, kept in the Keychain. The JSON form matches
/// the Flutter app's, so profiles can be imported from it.
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AuthKind
    /// API token ([AuthKind.apiToken]).
    public var token: String?
    /// Account e-mail ([AuthKind.globalKey]; the signed-in user's for OAuth).
    public var email: String?
    /// Global API key ([AuthKind.globalKey]).
    public var apiKey: String?
    /// Optional Origin CA key, used only for `/certificates` endpoints.
    public var originCaKey: String?
    /// Set for account-owned API tokens, which are verified against
    /// `/accounts/{id}/tokens/verify`.
    public var accountId: String?
    /// The OAuth client the session was issued to ([AuthKind.oauth]).
    public var oauthClientId: String?
    /// Scopes requested at sign-in ([AuthKind.oauth]).
    public var oauthScopes: [String]
    public var createdAt: Date?

    public init(
        id: String = Profile.newID(), name: String, kind: AuthKind, token: String? = nil, email: String? = nil,
        apiKey: String? = nil, originCaKey: String? = nil, accountId: String? = nil, oauthClientId: String? = nil,
        oauthScopes: [String] = [], createdAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.token = token
        self.email = email
        self.apiKey = apiKey
        self.originCaKey = originCaKey
        self.accountId = accountId
        self.oauthClientId = oauthClientId
        self.oauthScopes = oauthScopes
        self.createdAt = createdAt
    }

    /// 16 random hex digits, like the Flutter app's ids.
    public static func newID() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(Int.random(in: 0..<16, using: &g), radix: 16) }.joined()
    }

    /// Human-readable credential type.
    public var kindLabel: String {
        switch kind {
        case .apiToken: return "API Token"
        case .globalKey: return "Global API Key"
        case .oauth: return "OAuth"
        }
    }

    /// Headers that authenticate a request. OAuth profiles get their bearer
    /// token from the client's `AccessTokenSource` instead.
    public func authHeaders(originCA: Bool = false) -> [String: String] {
        if originCA, let key = originCaKey, !key.isEmpty {
            return ["X-Auth-User-Service-Key": key]
        }
        switch kind {
        case .apiToken: return ["Authorization": "Bearer \(token ?? "")"]
        case .globalKey: return ["X-Auth-Email": email ?? "", "X-Auth-Key": apiKey ?? ""]
        case .oauth: return [:]
        }
    }

    /// A short, non-secret hint such as `abcd…wxyz` for display.
    public var secretHint: String {
        if kind == .oauth { return email ?? "Cloudflare" }
        let s = kind == .apiToken ? token : apiKey
        guard let s, s.count >= 10 else { return "••••" }
        return "\(s.prefix(4))…\(s.suffix(4))"
    }

    // MARK: Coding (the Flutter app's JSON)

    enum CodingKeys: String, CodingKey {
        case id, name, kind, token, email, apiKey, originCaKey, accountId, oauthClientId, oauthScopes, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cloudflare"
        kind = (try? c.decodeIfPresent(AuthKind.self, forKey: .kind)) ?? .apiToken
        token = try c.decodeIfPresent(String.self, forKey: .token)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        originCaKey = try c.decodeIfPresent(String.self, forKey: .originCaKey)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        oauthClientId = try c.decodeIfPresent(String.self, forKey: .oauthClientId)
        oauthScopes = (try? c.decodeIfPresent([String].self, forKey: .oauthScopes)) ?? []
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(ISODate.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(token, forKey: .token)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(originCaKey, forKey: .originCaKey)
        try c.encodeIfPresent(accountId, forKey: .accountId)
        try c.encodeIfPresent(oauthClientId, forKey: .oauthClientId)
        if !oauthScopes.isEmpty { try c.encode(oauthScopes, forKey: .oauthScopes) }
        try c.encodeIfPresent(createdAt.map(ISODate.format), forKey: .createdAt)
    }
}

/// ISO 8601 dates as Dart writes and reads them: with or without fractional
/// seconds (up to microseconds) and with or without a time zone (no zone
/// means local time).
public enum ISODate {
    public static func parse(_ s: String) -> Date? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        if raw.count == 10 { return dateOnly.date(from: raw) }
        // Dart writes up to six fraction digits; the formatters read three.
        var t = raw
        if let dot = t.firstIndex(of: ".") {
            let rest = t[t.index(after: dot)...]
            let fraction = rest.prefix { $0.isNumber }
            let zone = rest.dropFirst(fraction.count)
            t = String(t[..<dot]) + "." + String((fraction + "000").prefix(3)) + zone
        }
        for f in [withFraction, plain] {
            if let d = f.date(from: t) { return d }
        }
        // No time zone: local time, as Dart's DateTime.toIso8601String()
        // writes local dates.
        for f in [localWithFraction, localPlain] {
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// UTC with milliseconds, e.g. `2026-10-10T12:00:00.000Z`.
    public static func format(_ d: Date) -> String { withFraction.string(from: d) }

    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func localFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    nonisolated(unsafe) private static let localWithFraction = localFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")
    nonisolated(unsafe) private static let localPlain = localFormatter("yyyy-MM-dd'T'HH:mm:ss")

    nonisolated(unsafe) private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

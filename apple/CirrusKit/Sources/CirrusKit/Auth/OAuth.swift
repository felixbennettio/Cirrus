import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Cloudflare OAuth 2.0 for public (native) clients: Authorization Code with
/// PKCE (`S256`) and no client secret.
/// See https://developers.cloudflare.com/fundamentals/oauth/.
public struct OAuthConfig: Hashable, Sendable {
    public var clientId: String
    /// Scope ids as listed by `GET /oauth/scopes`, e.g. `zone.read`.
    public var scopes: [String]

    public init(clientId: String, scopes: [String]) {
        self.clientId = clientId
        self.scopes = scopes
    }

    /// Cirrus's OAuth client on Cloudflare.
    public static let defaultClientId = "9c147a5155baf903357222bd4d31ad50"

    /// The scopes configured on [defaultClientId]: zone management is
    /// required, the rest is optional on the consent screen.
    public static let defaultScopes =
        "zone.read zone.write zone-settings.read zone-settings.write dns.read dns.write "
        + "ssl-and-certificates.read ssl-and-certificates.write cache.purge analytics.read account-analytics.read "
        + "firewall-services.read firewall-services.write account-settings.read account-settings.write "
        + "user-details.read user-details.write memberships.read memberships.write "
        + "account-api-gateway.read account-api-gateway.write "
        + "workers-scripts.edit workers-scripts.metadata_read workers-routes.read workers-routes.write workers-tail.read "
        + "workers-kv-storage.read workers-kv-storage.write workers-r2.read workers-r2.write "
        + "page.read page.write queues.read queues.write ai.read ai.write ai-model.read ai-model.write "
        + "query-cache.read query-cache.write "
        + "access.read access.write access-app.read access-app.write access-acct.read access-acct.write "
        + "access-service-token.read access-service-token.write zone-access.read zone-access.write "
        + "teams.read teams.write teams-networks.read teams-networks.write argotunnel.read argotunnel.write"

    /// The client built into the app.
    public static let builtIn = OAuthConfig(clientId: defaultClientId, scopes: parseScopes(defaultScopes))

    public static let authorizeEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    public static let tokenEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    public static let revokeEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/revoke")!

    /// Hydra only issues refresh tokens when this scope is requested.
    public static let offlineScope = "offline_access"

    /// Scopes sent on the authorization request (always with [offlineScope]).
    public var requestScopes: [String] {
        var out = scopes
        if !out.contains(Self.offlineScope) { out.append(Self.offlineScope) }
        return out
    }

    /// Splits a space- or comma-separated scope list (duplicates removed).
    public static func parseScopes(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Where the authorization response goes. Cloudflare only accepts http(s)
/// redirect URLs, so it lands on this page of the Cirrus website, which
/// passes it on to the app through [appScheme]. PKCE keeps the code useless
/// to anyone without the app's verifier.
public enum OAuthRedirect {
    public static let web = URL(string: "https://cirrus.routeforge.zone/oauth/callback")!
    /// The custom scheme the website's callback page opens (RFC 8252 §7.1).
    public static let appScheme = "io.felixbennett.cirrus"
    public static let appCallbackPath = "/oauth/callback"
}

/// A PKCE verifier and its `S256` challenge (RFC 7636).
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = PKCE.challenge(for: verifier)
    }

    public static func generate() -> PKCE { PKCE(verifier: randomURLSafe(64)) }

    public static func challenge(for verifier: String) -> String {
        SHA256.hash(Data(verifier.utf8)).base64URLEncoded
    }
}

/// A random string from the RFC 7636 unreserved characters.
public func randomURLSafe(_ length: Int) -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var g = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &g)] })
}

/// Tokens from the token endpoint. The JSON form matches the Flutter app's.
public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// Reads a token endpoint response. Hydra rotates refresh tokens; the old
    /// one is kept only when no new one came back.
    public init(tokenResponse json: JSON, now: Date = Date(), previousRefreshToken: String? = nil) throws {
        guard let access = json["access_token"].string, !access.isEmpty else {
            throw OAuthError("invalid_response", "The token response did not contain an access token.")
        }
        accessToken = access
        refreshToken = json["refresh_token"].string ?? previousRefreshToken
        expiresAt = now.addingTimeInterval(TimeInterval(json["expires_in"].int ?? 3600))
        scopes = OAuthConfig.parseScopes(json["scope"].string ?? "")
    }

    /// True when the access token expires within [margin] seconds.
    public func expiresSoon(margin: TimeInterval = 60, now: Date = Date()) -> Bool {
        !(now.addingTimeInterval(margin) < expiresAt)
    }

    enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresAt, scopes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = (try? c.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap(ISODate.parse)
            ?? Date(timeIntervalSince1970: 0)
        scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encode(ISODate.format(expiresAt), forKey: .expiresAt)
        try c.encode(scopes, forKey: .scopes)
    }
}

/// An OAuth error (RFC 6749 §5.2 / §4.1.2.1).
public struct OAuthError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var code: String
    public var details: String?

    public init(_ code: String, _ details: String? = nil) {
        self.code = code
        self.details = details
    }

    /// The grant is gone (revoked, expired or already used): sign in again.
    public var needsReauth: Bool { ["invalid_grant", "unauthorized_client", "invalid_client"].contains(code) }

    public var description: String { (details ?? "").isEmpty ? code : "\(code): \(details!)" }
    public var errorDescription: String? { description }
}

/// Talks to Cloudflare's OAuth endpoints.
public struct OAuthAPI: Sendable {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    public func authorizeURL(_ config: OAuthConfig, redirect: URL, state: String, pkce: PKCE) -> URL {
        var c = URLComponents(url: OAuthConfig.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        let params: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", config.clientId),
            ("redirect_uri", redirect.absoluteString),
            ("scope", config.requestScopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
        ]
        c.percentEncodedQuery = params.map { "\(URLEncoding.queryEncode($0.0))=\(URLEncoding.queryEncode($0.1))" }
            .joined(separator: "&")
        return c.url!
    }

    public func exchangeCode(_ config: OAuthConfig, code: String, redirect: URL, pkce: PKCE) async throws
        -> OAuthTokens
    {
        let json = try await post(
            OAuthConfig.tokenEndpoint,
            [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirect.absoluteString),
                ("client_id", config.clientId),
                ("code_verifier", pkce.verifier),
            ])
        return try OAuthTokens(tokenResponse: json)
    }

    public func refresh(clientId: String, refreshToken: String) async throws -> OAuthTokens {
        let json = try await post(
            OAuthConfig.tokenEndpoint,
            [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientId)])
        return try OAuthTokens(tokenResponse: json, previousRefreshToken: refreshToken)
    }

    /// Revokes a token (RFC 7009). Best effort: errors are ignored and the
    /// call gives up after five seconds (e.g. offline).
    public func revoke(clientId: String, token: String, hint: String = "refresh_token") async {
        _ = try? await withTimeout(seconds: 5) {
            try await post(
                OAuthConfig.revokeEndpoint, [("token", token), ("token_type_hint", hint), ("client_id", clientId)])
        }
    }

    func post(_ url: URL, _ form: [(String, String)]) async throws -> JSON {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = RequestBody.form(form).data
        let data: Data
        let res: HTTPURLResponse
        do {
            (data, res) = try await session.cirrusData(for: req)
        } catch {
            throw OAuthError("network_error", error.localizedDescription)
        }
        let body = String(decoding: data, as: UTF8.self)
        let json = (try? JSON.parse(data)).flatMap { $0.object != nil ? $0 : nil } ?? [:]
        if res.statusCode >= 400 || !json["error"].isNull {
            // Cloudflare's server (Ory Hydra) puts the reason in `error_hint`,
            // e.g. that a refresh token expired or was already used.
            let description = [json["error_description"].string, json["error_hint"].string].compactMap { $0 }
                .joined(separator: " ")
            throw OAuthError(
                json["error"].string ?? "http_\(res.statusCode)",
                !description.isEmpty ? description : (json.object?.isEmpty ?? true ? body : nil))
        }
        return json
    }
}

/// Runs [body], throwing `OAuthError("timeout")` after [seconds].
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw OAuthError("timeout")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// Reads the authorization response the browser was redirected to: checks
/// [state] and returns the code. Accepts the app-scheme callback and the
/// website's https callback.
public func authorizationCode(from callback: URL, state: String) throws -> String {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    if let error = value("error") { throw OAuthError(error, value("error_description")) }
    guard value("state") == state else {
        throw OAuthError("state_mismatch", "The authorization response did not match this request.")
    }
    guard let code = value("code"), !code.isEmpty else {
        throw OAuthError("invalid_response", "No authorization code.")
    }
    return code
}

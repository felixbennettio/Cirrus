import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The scopes configured on Cirrus's OAuth client, as the Cirrus website
/// reads them from Cloudflare: `GET https://cirrus.routeforge.zone/api/v1/oauth/config`.
///
/// [scopes] is everything the client is configured for; [optionalScopes] are
/// those the consent screen lets the user untick. An empty [clientId] means
/// the list applies to the built-in client.
public struct RemoteOAuthConfig: Codable, Hashable, Sendable {
    public var clientId: String
    public var scopes: [String]
    public var optionalScopes: [String]
    /// Where the server got the list: `cloudflare` or `env`.
    public var source: String?

    public init(clientId: String, scopes: [String], optionalScopes: [String] = [], source: String? = nil) {
        self.clientId = clientId
        self.scopes = scopes
        self.optionalScopes = optionalScopes
        self.source = source
    }

    public init(json: JSON) {
        clientId = (json["client_id"].string ?? "").trimmingCharacters(in: .whitespaces)
        scopes = Self.scopeList(json["scopes"])
        optionalScopes = Self.scopeList(json["optional_scopes"])
        source = json["source"].string
    }

    public var json: JSON {
        var o: [String: JSON] = [
            "client_id": .string(clientId), "scopes": .array(scopes.map(JSON.string)),
            "optional_scopes": .array(optionalScopes.map(JSON.string)),
        ]
        if let source { o["source"] = .string(source) }
        return .object(o)
    }

    /// Accepts a JSON array or a space-separated string.
    static func scopeList(_ raw: JSON) -> [String] {
        switch raw {
        case .array(let a): return OAuthConfig.parseScopes(a.compactMap(\.text).joined(separator: " "))
        case .string(let s): return OAuthConfig.parseScopes(s)
        default: return []
        }
    }
}

/// A small persistent key-value store (UserDefaults in the app).
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// Chooses the scopes to request with the built-in OAuth client: the
/// server's list when it describes that client, else the last good list
/// (offline), else `OAuthConfig.defaultScopes`.
public struct OAuthScopeResolver: Sendable {
    public static let cacheKey = "cirrus.oauth.remoteConfig.v1"
    public static let configURL = URL(string: "https://cirrus.routeforge.zone/api/v1/oauth/config")!

    public var fetch: @Sendable () async throws -> RemoteOAuthConfig
    public var store: KeyValueStore
    public var timeout: Double

    public init(store: KeyValueStore, timeout: Double = 8, fetch: (@Sendable () async throws -> RemoteOAuthConfig)? = nil) {
        self.store = store
        self.timeout = timeout
        self.fetch = fetch ?? OAuthScopeResolver.fetchFromServer
    }

    public static let fetchFromServer: @Sendable () async throws -> RemoteOAuthConfig = {
        var req = URLRequest(url: configURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        let (data, res) = try await URLSession.shared.cirrusData(for: req)
        guard res.statusCode == 200, let json = try? JSON.parse(data), json.object != nil else {
            throw OAuthError("config_unavailable", "HTTP \(res.statusCode)")
        }
        return RemoteOAuthConfig(json: json)
    }

    /// The last config fetched successfully, if any.
    public var cached: RemoteOAuthConfig? {
        guard let raw = store.string(forKey: Self.cacheKey), let json = try? JSON.parse(raw) else { return nil }
        return RemoteOAuthConfig(json: json)
    }

    private func fits(_ c: RemoteOAuthConfig?, _ builtIn: OAuthConfig) -> Bool {
        guard let c else { return false }
        return (c.clientId.isEmpty || c.clientId == builtIn.clientId) && !c.scopes.isEmpty
    }

    /// [builtIn] with the scopes to request.
    public func resolve(_ builtIn: OAuthConfig) async -> OAuthConfig {
        let remote: RemoteOAuthConfig
        do {
            let fetch = self.fetch
            remote = try await withTimeout(seconds: timeout) { try await fetch() }
        } catch {
            let last = cached
            return fits(last, builtIn) ? OAuthConfig(clientId: builtIn.clientId, scopes: last!.scopes) : builtIn
        }
        guard fits(remote, builtIn) else { return builtIn }
        store.set(remote.json.compactString, forKey: Self.cacheKey)
        return OAuthConfig(clientId: builtIn.clientId, scopes: remote.scopes)
    }
}

/// The result of checking a credential against the API.
public struct VerifyResult: Sendable {
    public var ok: Bool
    public var status: String?
    public var tokenId: String?
    public var expiresOn: String?
    public var email: String?
    public var accounts: [JSON] = []
    public var error: String?
}

/// Verifies a profile. API tokens use the token verify endpoints (user
/// tokens first, then account-owned tokens); Global API keys use `/user`;
/// OAuth profiles need a [client] that carries their session.
public func verifyProfile(_ profile: Profile, client: CFClient? = nil) async -> VerifyResult {
    let c = client ?? CFClient(profile: profile)
    do {
        var status: String?
        var tokenId: String?
        var expires: String?
        var email: String?
        switch profile.kind {
        case .apiToken:
            var r: JSON
            if let accountId = profile.accountId, !accountId.isEmpty {
                r = try await c.get("/accounts/\(accountId.pathEncoded)/tokens/verify")
            } else {
                do {
                    r = try await c.get("/user/tokens/verify")
                } catch let e as CFAPIError {
                    // Account-owned tokens are rejected by /user/tokens/verify:
                    // find an account the token can see and verify there.
                    let accounts = try await c.list("/accounts", perPage: 50, maxItems: 50)
                    guard let id = accounts.first?["id"].string else { throw e }
                    r = try await c.get("/accounts/\(id.pathEncoded)/tokens/verify")
                }
            }
            status = r["status"].string
            tokenId = r["id"].string
            expires = r["expires_on"].string
            if let s = status, s != "active" {
                return VerifyResult(ok: false, status: s, tokenId: tokenId, error: "Token status: \(s)")
            }
        case .oauth:
            // OAuth grants may not include user details; only an auth failure is fatal.
            do {
                email = try await c.get("/user")["email"].string
            } catch let e as CFAPIError where !e.isAuthError {}
            status = "active"
        case .globalKey:
            email = try await c.get("/user")["email"].string
            status = "active"
        }
        let accounts = (try? await c.list("/accounts", perPage: 50, maxItems: 200)) ?? []
        return VerifyResult(
            ok: true, status: status, tokenId: tokenId, expiresOn: expires, email: email, accounts: accounts)
    } catch let e as CFAPIError {
        return VerifyResult(ok: false, error: e.summary)
    } catch {
        return VerifyResult(ok: false, error: error.localizedDescription)
    }
}

import Foundation

/// Persists OAuth tokens per profile, apart from the profile list, so a
/// refresh never rewrites (or races with) profile edits.
public protocol OAuthTokenStore: Sendable {
    func readTokens(profileId: String) async -> OAuthTokens?
    func writeTokens(profileId: String, _ tokens: OAuthTokens) async throws
    func deleteTokens(profileId: String) async
}

/// Hands out access tokens for one OAuth profile and refreshes them shortly
/// before they expire. Cloudflare's authorization server rotates refresh
/// tokens and treats a reused one as stolen, revoking the whole grant (the
/// user then has to sign in again). So every refresh token is used at most
/// once: concurrent callers share one load and one in-flight refresh, and a
/// caller holding tokens that were already replaced gets the new ones.
public actor OAuthSession: AccessTokenSource {
    public let profileId: String
    public let clientId: String
    public let store: OAuthTokenStore
    public let api: OAuthAPI
    private var tokens: OAuthTokens?
    private var loading: Task<OAuthTokens?, Never>?
    private var refreshing: Task<OAuthTokens, Error>?

    public init(profileId: String, clientId: String, store: OAuthTokenStore, api: OAuthAPI = OAuthAPI(),
                initial: OAuthTokens? = nil) {
        self.profileId = profileId
        self.clientId = clientId
        self.store = store
        self.api = api
        tokens = initial
    }

    public func currentToken() async -> String? { tokens?.accessToken }

    public var currentTokens: OAuthTokens? { tokens }

    /// The stored tokens, loading them if needed (nil when signed out).
    public func loadTokens() async -> OAuthTokens? {
        if let tokens { return tokens }
        let task: Task<OAuthTokens?, Never>
        if let loading {
            task = loading
        } else {
            let store = store
            let id = profileId
            task = Task { await store.readTokens(profileId: id) }
            loading = task
        }
        let loaded = await task.value
        // A refresh may have finished while the store was read: keep its tokens.
        if tokens == nil { tokens = loaded }
        return tokens
    }

    public func accessToken(rejected: String?) async throws -> String {
        guard var t = await loadTokens() else {
            throw OAuthError("not_signed_in", "This credential has no OAuth session. Sign in again.")
        }
        // A request was rejected with this token: refresh unless another
        // caller already replaced it.
        let stale = rejected != nil && rejected == t.accessToken
        if stale || t.expiresSoon() { t = try await refresh(t) }
        return t.accessToken
    }

    private func refresh(_ current: OAuthTokens) async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        // Already replaced by an earlier refresh: never send its refresh token again.
        if let latest = tokens, latest.accessToken != current.accessToken, !latest.expiresSoon() {
            return latest
        }
        let task = Task { try await self.doRefresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func doRefresh(_ current: OAuthTokens) async throws -> OAuthTokens {
        guard let rt = current.refreshToken, !rt.isEmpty else {
            throw OAuthError("invalid_grant", "The session cannot be renewed. Sign in again.")
        }
        var next: OAuthTokens
        do {
            next = try await api.refresh(clientId: clientId, refreshToken: rt)
        } catch let e as OAuthError {
            // Another copy of the app may have rotated the token and stored
            // the new one: use that rather than giving up.
            let stored = e.needsReauth ? await store.readTokens(profileId: profileId) : nil
            guard let stored, let storedRt = stored.refreshToken, storedRt != rt else { throw e }
            if !stored.expiresSoon() {
                tokens = stored
                return stored
            }
            next = try await api.refresh(clientId: clientId, refreshToken: storedRt)
        }
        // A refresh response may leave out `scope`: the grant is unchanged then.
        if next.scopes.isEmpty && !current.scopes.isEmpty { next.scopes = current.scopes }
        tokens = next
        try await store.writeTokens(profileId: profileId, next)
        return next
    }

    /// Revokes the refresh token (best effort) and forgets the session.
    public func signOut() async {
        let t: OAuthTokens?
        if let tokens {
            t = tokens
        } else {
            t = await store.readTokens(profileId: profileId)
        }
        if let rt = t?.refreshToken { await api.revoke(clientId: clientId, token: rt) }
        tokens = nil
        loading = nil
        await store.deleteTokens(profileId: profileId)
    }
}

/// One `OAuthSession` per profile, shared by every client built for it.
public actor OAuthSessions {
    public let store: OAuthTokenStore
    public let api: OAuthAPI
    private var byProfile: [String: OAuthSession] = [:]

    public init(store: OAuthTokenStore, api: OAuthAPI = OAuthAPI()) {
        self.store = store
        self.api = api
    }

    public func session(for profile: Profile) -> OAuthSession {
        if let s = byProfile[profile.id] { return s }
        let s = OAuthSession(profileId: profile.id, clientId: profile.oauthClientId ?? "", store: store, api: api)
        byProfile[profile.id] = s
        return s
    }

    /// Stores freshly issued tokens for [profile] and returns its session.
    public func adopt(_ profile: Profile, tokens: OAuthTokens) async throws -> OAuthSession {
        try await store.writeTokens(profileId: profile.id, tokens)
        let s = OAuthSession(
            profileId: profile.id, clientId: profile.oauthClientId ?? "", store: store, api: api, initial: tokens)
        byProfile[profile.id] = s
        return s
    }

    /// Signs [profile] out and drops its session.
    public func remove(_ profile: Profile) async {
        await session(for: profile).signOut()
        byProfile[profile.id] = nil
    }
}

/// Keeps tokens in memory (tests, previews).
public actor MemoryTokenStore: OAuthTokenStore {
    public var tokens: [String: OAuthTokens] = [:]
    public init(_ initial: [String: OAuthTokens] = [:]) { tokens = initial }
    public func readTokens(profileId: String) async -> OAuthTokens? { tokens[profileId] }
    public func writeTokens(profileId: String, _ t: OAuthTokens) async throws { tokens[profileId] = t }
    public func deleteTokens(profileId: String) async { tokens[profileId] = nil }
}

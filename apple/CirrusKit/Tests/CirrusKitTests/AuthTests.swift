import Foundation
import Testing
@testable import CirrusKit

@Suite struct HashTests {
    @Test func sha256Vectors() {
        #expect(SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256.hex(String(repeating: "a", count: 1000)).count == 64)
    }

    /// RFC 7636, appendix B.
    @Test func pkceChallenge() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierUsesUnreservedCharacters() {
        let v = PKCE.generate().verifier
        #expect(v.count == 64)
        #expect(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }
}

@Suite struct OAuthModelTests {
    @Test func scopesParseAndAddOfflineAccess() {
        let c = OAuthConfig(clientId: "c", scopes: OAuthConfig.parseScopes("zone.read, dns.read \r\n zone.read"))
        #expect(c.scopes == ["zone.read", "dns.read"])
        #expect(c.requestScopes == ["zone.read", "dns.read", "offline_access"])
        #expect(OAuthConfig.builtIn.scopes.contains("dns.write"))
    }

    @Test func authorizeURL() {
        let url = OAuthAPI().authorizeURL(
            OAuthConfig(clientId: "cid", scopes: ["zone.read"]), redirect: OAuthRedirect.web, state: "s1",
            pkce: PKCE(verifier: "v"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "dash.cloudflare.com")
        #expect(v("scope") == "zone.read offline_access")
        #expect(v("redirect_uri") == "https://cirrus.routeforge.zone/oauth/callback")
        #expect(v("code_challenge_method") == "S256")
        #expect(v("state") == "s1")
    }

    @Test func tokenResponse() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let t = try OAuthTokens(
            tokenResponse: ["access_token": "a", "expires_in": 3600, "scope": "zone.read offline_access"], now: now,
            previousRefreshToken: "old")
        #expect(t.refreshToken == "old")
        #expect(t.expiresAt == now.addingTimeInterval(3600))
        #expect(t.scopes == ["zone.read", "offline_access"])
        #expect(throws: OAuthError.self) { try OAuthTokens(tokenResponse: ["token_type": "bearer"]) }
    }

    @Test func callbackParsing() throws {
        let ok = URL(string: "io.felixbennett.cirrus:/oauth/callback?code=c1&state=s1")!
        #expect(try authorizationCode(from: ok, state: "s1") == "c1")
        #expect(throws: OAuthError.self) { try authorizationCode(from: ok, state: "other") }
        let denied = URL(string: "io.felixbennett.cirrus:/oauth/callback?error=access_denied&state=s1")!
        #expect {
            try authorizationCode(from: denied, state: "s1")
        } throws: { ($0 as! OAuthError).code == "access_denied" }
    }

    /// The Flutter app's stored tokens (Dart writes microseconds).
    @Test func flutterTokenJSON() throws {
        let raw = #"{"accessToken":"a","refreshToken":"r","expiresAt":"2026-10-10T12:00:00.123456Z","scopes":["zone.read"]}"#
        let t = try #require(FlutterAppData.parseTokens(raw))
        #expect(t.refreshToken == "r")
        #expect(abs(t.expiresAt.timeIntervalSince1970 - 1_791_633_600.123) < 0.01)
        let back = try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}

@Suite(.serialized) struct OAuthSessionTests {
    /// A token endpoint that rotates refresh tokens and rejects reuse, like
    /// Cloudflare's (Ory Hydra).
    final class TokenEndpoint: @unchecked Sendable {
        var issued = 0
        var used = Set<String>()
        var valid: Set<String> = ["r0"]
        let lock = NSLock()

        func respond(_ r: MockServer.Request) -> MockServer.Response {
            lock.lock()
            defer { lock.unlock() }
            let form = Dictionary(
                uniqueKeysWithValues: String(decoding: r.body, as: UTF8.self).split(separator: "&").map {
                    let kv = $0.split(separator: "=", maxSplits: 1).map(String.init)
                    return (kv[0], kv.count > 1 ? kv[1].removingPercentEncoding ?? kv[1] : "")
                })
            guard form["grant_type"] == "refresh_token", let rt = form["refresh_token"] else {
                return .json(["error": "unsupported_grant_type"], status: 400)
            }
            if used.contains(rt) || !valid.contains(rt) {
                return .json(["error": "invalid_grant", "error_hint": "It was used before."], status: 400)
            }
            used.insert(rt)
            issued += 1
            valid.insert("r\(issued)")
            return .json(["access_token": .string("a\(issued)"), "refresh_token": .string("r\(issued)"), "expires_in": 3600])
        }
    }

    func session(_ endpoint: TokenEndpoint, store: MemoryTokenStore, initial: OAuthTokens?) -> (OAuthSession, MockServer) {
        let server = MockServer(host: "dash.cloudflare.com") { endpoint.respond($0) }
        let api = OAuthAPI(session: server.session)
        return (OAuthSession(profileId: "p", clientId: "cid", store: store, api: api, initial: initial), server)
    }

    @Test func freshTokenIsUsedAsIs() async throws {
        let store = MemoryTokenStore()
        let t = OAuthTokens(accessToken: "a0", refreshToken: "r0", expiresAt: Date().addingTimeInterval(3600))
        let (s, server) = session(TokenEndpoint(), store: store, initial: t)
        #expect(try await s.accessToken(rejected: nil) == "a0")
        #expect(server.requests.isEmpty)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let store = MemoryTokenStore()
        let expired = OAuthTokens(accessToken: "a0", refreshToken: "r0", expiresAt: Date().addingTimeInterval(-5))
        let endpoint = TokenEndpoint()
        let (s, server) = session(endpoint, store: store, initial: expired)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await s.accessToken(rejected: nil) } }
            var out: [String] = []
            for try await r in group { out.append(r) }
            return out
        }
        #expect(Set(results) == ["a1"])
        #expect(server.requests.count == 1)
        #expect(await store.tokens["p"]?.refreshToken == "r1")
    }

    @Test func rejectedTokenForcesRefreshButNotTwice() async throws {
        let store = MemoryTokenStore()
        let t = OAuthTokens(accessToken: "a0", refreshToken: "r0", expiresAt: Date().addingTimeInterval(3600))
        let (s, server) = session(TokenEndpoint(), store: store, initial: t)
        #expect(try await s.accessToken(rejected: "a0") == "a1")
        // A second caller rejected with the old token gets the new one, no new refresh.
        #expect(try await s.accessToken(rejected: "a0") == "a1")
        #expect(server.requests.count == 1)
    }

    @Test func usesTokensAnotherCopyStored() async throws {
        let endpoint = TokenEndpoint()
        // Another app instance already used r0 and stored r1.
        endpoint.used.insert("r0")
        endpoint.valid.insert("r1")
        endpoint.issued = 1
        let stored = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600))
        let store = MemoryTokenStore(["p": stored])
        let stale = OAuthTokens(accessToken: "a0", refreshToken: "r0", expiresAt: Date().addingTimeInterval(-5))
        let (s, _) = session(endpoint, store: store, initial: stale)
        #expect(try await s.accessToken(rejected: nil) == "a1")
    }

    @Test func revokedGrantNeedsSignIn() async throws {
        let endpoint = TokenEndpoint()
        endpoint.valid = []
        let store = MemoryTokenStore()
        let stale = OAuthTokens(accessToken: "a0", refreshToken: "r0", expiresAt: Date().addingTimeInterval(-5))
        let (s, _) = session(endpoint, store: store, initial: stale)
        await #expect {
            try await s.accessToken(rejected: nil)
        } throws: { error in
            let e = error as! OAuthError
            return e.needsReauth && e.description.contains("It was used before.")
        }
    }
}

@Suite struct RemoteConfigTests {
    final class Defaults: KeyValueStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String?, forKey key: String) { values[key] = value }
    }

    @Test func parsesArraysAndStrings() {
        let a = RemoteOAuthConfig(json: ["client_id": " cid ", "scopes": ["zone.read", "dns.read"], "optional_scopes": "dns.read"])
        #expect(a.clientId == "cid")
        #expect(a.scopes == ["zone.read", "dns.read"])
        #expect(a.optionalScopes == ["dns.read"])
    }

    @Test func usesServerListAndCachesIt() async {
        let d = Defaults()
        let r = OAuthScopeResolver(store: d) { RemoteOAuthConfig(clientId: "", scopes: ["zone.read"]) }
        let c = await r.resolve(.builtIn)
        #expect(c.scopes == ["zone.read"])
        #expect(r.cached?.scopes == ["zone.read"])
    }

    @Test func fallsBackToCacheThenBuiltIn() async {
        let d = Defaults()
        let failing = OAuthScopeResolver(store: d) { throw OAuthError("offline") }
        #expect(await failing.resolve(.builtIn) == .builtIn)
        d.set(RemoteOAuthConfig(clientId: "", scopes: ["a.read"]).json.compactString, forKey: OAuthScopeResolver.cacheKey)
        #expect(await failing.resolve(.builtIn).scopes == ["a.read"])
    }

    @Test func ignoresOtherClients() async {
        let r = OAuthScopeResolver(store: Defaults()) { RemoteOAuthConfig(clientId: "someone-else", scopes: ["x.read"]) }
        #expect(await r.resolve(.builtIn) == .builtIn)
    }
}

@Suite struct ProfileTests {
    /// Profiles as the Flutter app stored them.
    @Test func flutterProfilesImport() throws {
        let raw = """
            [{"id":"a1b2","name":"Personal","kind":"apiToken","token":"t-123456789","createdAt":"2026-10-08T21:03:11.123456"},
             {"id":"c3","name":"Work","kind":"globalKey","email":"me@example.com","apiKey":"k","originCaKey":"v1.0-x"},
             {"id":"o1","name":"Cloudflare","kind":"oauth","oauthClientId":"cid","oauthScopes":["zone.read"],"email":"o@x.y"},
             {"name":"broken"}]
            """
        let ps = FlutterAppData.parseProfiles(raw)
        #expect(ps.map(\.id) == ["a1b2", "c3", "o1"])
        #expect(ps[0].createdAt != nil)
        #expect(ps[1].authHeaders() == ["X-Auth-Email": "me@example.com", "X-Auth-Key": "k"])
        #expect(ps[1].authHeaders(originCA: true) == ["X-Auth-User-Service-Key": "v1.0-x"])
        #expect(ps[2].kind == .oauth && ps[2].authHeaders().isEmpty)
        #expect(ps[0].secretHint == "t-12…6789")
        #expect(ps[2].secretHint == "o@x.y")
    }

    @Test func roundTrip() throws {
        let p = Profile(name: "N", kind: .apiToken, token: "t", accountId: "acc")
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.id == p.id && back.accountId == "acc")
        #expect(abs((back.createdAt ?? .distantPast).timeIntervalSince(p.createdAt!)) < 0.01)
    }

    @Test func flutterSettingsImport() {
        let raw = #"{"themeMode":"dark","localeCode":"zh","appLock":true,"activeProfileId":"a1","activeAccount":{"a1":"acc"},"activeZone":{"acc":"z"},"favoriteOps":[],"compactSidebar":true,"confirmMutations":false,"dynamicColor":true,"liquidGlass":null}"#
        let s = AppSettings.decode(raw)
        #expect(s.themeMode == .dark)
        #expect(s.language == .zh)
        #expect(s.appLock)
        #expect(s.activeAccount["a1"] == "acc")
        #expect(!s.confirmMutations)
        #expect(AppSettings.decode("not json") == AppSettings())
        #expect(AppSettings.decode(s.encoded()) == s)
    }
}

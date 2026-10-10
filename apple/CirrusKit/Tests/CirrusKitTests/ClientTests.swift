import Foundation
import Testing
@testable import CirrusKit

private func tokenProfile(_ token: String = "tok-1234567890") -> Profile {
    Profile(id: "p1", name: "Test", kind: .apiToken, token: token)
}

@Suite struct EnvelopeTests {
    @Test func successReturnsResultAndInfo() throws {
        let body: JSON = ["success": true, "errors": [], "messages": [], "result": ["id": "z1"],
                          "result_info": ["page": 1, "total_pages": 3]]
        let r = try CFClient.parseEnvelope(method: "GET", path: "/zones", statusCode: 200, body: body.encoded())
        #expect(r.result["id"].string == "z1")
        #expect(r.resultInfo?["total_pages"].int == 3)
    }

    @Test func failureCarriesCloudflareErrors() {
        let body: JSON = ["success": false, "errors": [["code": 10000, "message": "Authentication error"]],
                          "messages": [], "result": nil]
        #expect {
            try CFClient.parseEnvelope(method: "GET", path: "/user", statusCode: 403, body: body.encoded())
        } throws: { error in
            let e = error as! CFAPIError
            return e.errors.first?.code == 10000 && e.isAuthError && e.summary == "Authentication error (10000)"
        }
    }

    @Test func errorChainIsKept() {
        let m = CFMessage(json: ["code": 1004, "message": "DNS Validation Error",
                                 "error_chain": [["code": 9005, "message": "Content for A record is invalid."]]])
        #expect(m.description == "DNS Validation Error (1004): Content for A record is invalid. (9005)")
    }

    @Test func nonEnvelopeBodiesPassThrough() throws {
        let r = try CFClient.parseEnvelope(method: "GET", path: "/x", statusCode: 200, body: Data("plain text".utf8))
        #expect(r.result.string == "plain text")
        let j = try CFClient.parseEnvelope(method: "GET", path: "/x", statusCode: 200, body: Data(#"{"a":1}"#.utf8))
        #expect(j.result["a"].int == 1)
    }

    @Test func httpErrorWithoutEnvelope() {
        #expect {
            try CFClient.parseEnvelope(method: "GET", path: "/x", statusCode: 502, body: Data("Bad gateway".utf8))
        } throws: { ($0 as! CFAPIError).summary == "Bad gateway" }
    }

    @Test func errorsArrayWithoutSuccess() {
        let body: JSON = ["errors": [["code": 7003, "message": "No route"]]]
        #expect(throws: CFAPIError.self) {
            try CFClient.parseEnvelope(method: "GET", path: "/x", statusCode: 404, body: body.encoded())
        }
    }
}

@Suite struct ClientTests {
    @Test func authHeadersForEachKind() async throws {
        let server = MockServer { _ in .ok([:]) }
        let token = CFClient(profile: tokenProfile("abc"), baseURL: server.baseURL, session: server.session)
        try await token.get("/user")
        #expect(server.requests.last?.header("Authorization") == "Bearer abc")

        let key = Profile(name: "K", kind: .globalKey, email: "a@b.c", apiKey: "k1")
        try await CFClient(profile: key, baseURL: server.baseURL, session: server.session).get("/user")
        #expect(server.requests.last?.header("X-Auth-Email") == "a@b.c")
        #expect(server.requests.last?.header("X-Auth-Key") == "k1")
        #expect(server.requests.last?.header("Authorization") == nil)
    }

    @Test func originCAKeyOnlyForCertificates() async throws {
        let server = MockServer { _ in .ok([]) }
        var p = tokenProfile("abc")
        p.originCaKey = "v1.0-origin"
        let c = CFClient(profile: p, baseURL: server.baseURL, session: server.session)
        try await c.get("/certificates", query: ["zone_id": "z"])
        #expect(server.requests.last?.header("X-Auth-User-Service-Key") == "v1.0-origin")
        #expect(server.requests.last?.header("Authorization") == nil)
        try await c.get("/zones")
        #expect(server.requests.last?.header("Authorization") == "Bearer abc")
    }

    @Test func queryIsEncodedStrictly() async throws {
        let server = MockServer { _ in .ok([]) }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        try await c.get("/zones", query: ["name": "a+b c", "skip": nil])
        let url = server.requests.last!.url.absoluteString
        #expect(url.hasSuffix("/zones?name=a%2Bb%20c"))
    }

    @Test func jsonBodyAndContentType() async throws {
        let server = MockServer { _ in .ok(["id": "r1"]) }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        let r = try await c.post("/zones/z/dns_records", ["type": "A", "proxied": true, "ttl": 1])
        #expect(r["id"].string == "r1")
        let req = server.requests.last!
        #expect(req.method == "POST")
        #expect(req.header("Content-Type") == "application/json")
        #expect(req.json["proxied"].bool == true)
        #expect(req.json["ttl"] == .int(1))
    }

    @Test func listFollowsPages() async throws {
        let server = MockServer { r in
            let page = Int(r.query["page"] ?? "1") ?? 1
            return .ok([["id": .string("z\(page)")]], info: ["page": .int(page), "per_page": 1, "total_pages": 3])
        }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        let all = try await c.list("/zones", perPage: 1)
        #expect(all.map { $0["id"].string } == ["z1", "z2", "z3"])
        #expect(server.requests.map { $0.query["page"] } == ["1", "2", "3"])
    }

    @Test func listFollowsCursors() async throws {
        let server = MockServer { r in
            switch r.query["cursor"] {
            case nil: return .ok([["id": "a"]], info: ["cursor": "c2"])
            case "c2": return .ok([["id": "b"]], info: ["cursor": ""])
            default: return .ok([])
            }
        }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        let all = try await c.list("/accounts/a/storage/kv/namespaces/n/keys", cursorPagination: true)
        #expect(all.map { $0["id"].string } == ["a", "b"])
    }

    @Test func listStopsWhenServerIgnoresPages() async throws {
        let server = MockServer { _ in .ok([["id": "x"]], info: ["page": 1, "total_pages": 5]) }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        let all = try await c.list("/zones", perPage: 1)
        #expect(all.count == 2)  // page 1 twice, then it stops
        #expect(server.requests.count == 2)
    }

    @Test func retriesRateLimits() async throws {
        let server = MockServer { _ in .ok([]) }
        var calls = 0
        server.handler = { _ in
            calls += 1
            return calls == 1 ? .json(["success": false, "errors": [], "result": nil], status: 429,
                                      headers: ["Retry-After": "1"]) : .ok(["ok": true])
        }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        let r = try await c.get("/zones")
        #expect(r["ok"].bool == true)
        #expect(server.requests.count == 2)
    }

    @Test func doesNotRetryWritesOnServerErrors() async throws {
        let server = MockServer { _ in .error(500, code: 1000, message: "boom") }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        await #expect(throws: CFAPIError.self) { try await c.post("/zones", ["name": "x"]) }
        #expect(server.requests.count == 1)
    }

    @Test func graphqlErrorsThrow() async throws {
        let server = MockServer { _ in .json(["data": nil, "errors": [["message": "zone not found"]]]) }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        await #expect {
            try await c.graphql("query { viewer { zones { x } } }")
        } throws: { ($0 as! CFAPIError).summary == "zone not found" }
    }

    @Test func requestLogHasNoQueries() async throws {
        let server = MockServer { _ in .ok([]) }
        let c = CFClient(profile: tokenProfile(), baseURL: server.baseURL, session: server.session)
        try await c.get("/zones", query: ["name": "secret.example"])
        #expect(c.log.records.first?.url == server.baseURL.absoluteString + "/zones")
        #expect(c.log.records.first?.statusCode == 200)
    }

    @Test func curlMasksSecrets() {
        let c = CFClient(profile: tokenProfile("real-secret-token"))
        let s = c.curl("POST", "/zones", body: ["name": "it's"])
        #expect(!s.contains("real-secret-token"))
        #expect(s.contains("Bearer $CLOUDFLARE_API_TOKEN"))
        #expect(s.contains(#"it'\''s"#))
    }

    @Test func refreshesRejectedOAuthTokenOnce() async throws {
        let server = MockServer { r in
            r.header("Authorization") == "Bearer fresh" ? .ok(["id": "u"]) : .error(401, code: 10000, message: "no")
        }
        let tokens = FakeTokens(["stale", "fresh"])
        let p = Profile(name: "O", kind: .oauth, oauthClientId: "cid")
        let c = CFClient(profile: p, tokens: tokens, baseURL: server.baseURL, session: server.session)
        let r = try await c.get("/user")
        #expect(r["id"].string == "u")
        #expect(await tokens.rejected == ["stale"])
    }
}

/// Hands out tokens in order; records the rejected ones.
actor FakeTokens: AccessTokenSource {
    var queue: [String]
    var rejected: [String] = []
    var current: String?

    init(_ tokens: [String]) { queue = tokens }

    func currentToken() async -> String? { current }

    func accessToken(rejected r: String?) async throws -> String {
        if let r { rejected.append(r) }
        if current == nil || r != nil { current = queue.isEmpty ? current : queue.removeFirst() }
        return current ?? ""
    }
}

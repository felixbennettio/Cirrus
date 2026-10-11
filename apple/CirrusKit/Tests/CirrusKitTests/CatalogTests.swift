import Foundation
import Testing
@testable import CirrusKit

@Suite struct APICatalogTests {
    static let sample: JSON = [
        "v": 1, "generated": "2026-10-05T02:35:52.060682Z", "apiVersion": "4.0.0",
        "ops": [
            [
                "id": "dns-records-for-a-zone-list-dns-records", "m": "GET", "p": "/zones/{zone_id}/dns_records",
                "s": "List DNS Records", "g": "dns.records",
                "params": [["n": "zone_id", "in": "path", "r": true], ["n": "type", "in": "query", "s": ["enum": ["A", "AAAA"]]]],
            ],
            [
                "id": "dns-records-for-a-zone-create-dns-record", "m": "POST", "p": "/zones/{zone_id}/dns_records",
                "s": "Create DNS Record", "g": "dns.records",
                "body": ["ct": "application/json", "s": ["$ref": "dns_record"]],
            ],
            [
                "id": "dns-records-export", "m": "GET", "p": "/zones/{zone_id}/dns_records/export", "s": "Export DNS Records",
                "g": "dns.records",
            ],
            [
                "id": "dns-records-get", "m": "GET", "p": "/zones/{zone_id}/dns_records/{dns_record_id}",
                "s": "DNS Record Details", "g": "dns.records", "dep": true,
            ],
            ["id": "tunnel-list", "m": "GET", "p": "/accounts/{account_id}/cfd_tunnel", "s": "List Cloudflare Tunnels", "g": "zero_trust.tunnels"],
        ],
        "schemas": [
            "dns_record": [
                "allOf": [["$ref": "dns_base"], ["properties": ["content": ["type": "string", "example": "198.51.100.4"]], "required": ["content"]]]
            ],
            "dns_base": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "readOnly": true], "name": ["type": "string", "example": "example.com"],
                    "type": ["type": "string", "enum": ["A", "AAAA"]], "proxied": ["type": "boolean"], "ttl": ["type": "number", "minimum": 30],
                ],
                "required": ["name", "type"],
            ],
        ],
    ]

    @Test func operationsAndSearch() {
        let c = APICatalog(json: Self.sample)
        #expect(c.operations.count == 5)
        #expect(c.byProduct.map(\.product) == ["dns", "zero_trust"])
        #expect(c.operation("tunnel-list")?.product == "zero_trust")
        #expect(c.search("dns create").first?.id == "dns-records-for-a-zone-create-dns-record")
        #expect(c.search("tunnel").map(\.id) == ["tunnel-list"])
        #expect(c.search("nothing matches this").isEmpty)
        // The deprecated detail endpoint ranks below the list for "dns record".
        #expect(c.search("dns records").last?.id == "dns-records-get")
    }

    @Test func findsByConcretePath() {
        let c = APICatalog(json: Self.sample)
        #expect(c.find("GET", "/zones/abc/dns_records/export")?.id == "dns-records-export")
        #expect(c.find("GET", "/zones/abc/dns_records/r1?x=1")?.id == "dns-records-get")
        #expect(c.find("POST", "/zones/abc/dns_records")?.body?.isJSON == true)
        #expect(c.find("DELETE", "/zones/abc/dns_records") == nil)
    }

    @Test func resolvesAllOfAndSkeleton() {
        let c = APICatalog(json: Self.sample)
        let body = c.operation("dns-records-for-a-zone-create-dns-record")!.body!.schema
        let r = c.resolve(body)
        #expect(Set(r["properties"].object!.keys) == ["id", "name", "type", "proxied", "ttl", "content"])
        #expect(Set(r["required"].strings) == ["name", "type", "content"])
        #expect(APICatalog.type(of: r) == "object")
        let sk = c.skeleton(body)
        #expect(sk["name"].string == "example.com")
        #expect(sk["type"].string == "A")
        #expect(sk["content"].string == "198.51.100.4")
        #expect(sk["id"].isNull)
        #expect(sk["ttl"].int == 30)
        let filtered = c.filter(["id": "x", "name": "a", "content": "b", "zone_name": "z"], for: body)
        #expect(filtered == ["name": "a", "content": "b"])
    }

    @Test func buildsFromOpenAPI() {
        let doc: JSON = [
            "info": ["title": "Cloudflare API", "version": "4.0.0"],
            "servers": [["url": "https://api.cloudflare.com/client/v4"]],
            "security": [["api_token": []]],
            "components": [
                "schemas": [
                    "thing": ["type": "object", "x-extra": true, "properties": ["n": ["$ref": "#/components/schemas/name"]]],
                    "name": ["type": "string", "description": "A name.", "example": "x"], "unused": ["type": "string"],
                ],
                "parameters": ["zone": ["name": "zone_id", "in": "path", "schema": ["type": "string"]]],
            ],
            "paths": [
                "/zones/{zone_id}/things": [
                    "parameters": [["$ref": "#/components/parameters/zone"]],
                    "post": [
                        "operationId": "things-create", "summary": " Create a thing ", "tags": ["Things"],
                        "x-api-token-group": ["Things Write"],
                        "parameters": [["name": "X-Auth-Key", "in": "header"], ["name": "dry_run", "in": "query", "schema": ["type": "boolean"]]],
                        "requestBody": ["required": true, "content": ["application/json": ["schema": ["$ref": "#/components/schemas/thing"]]]],
                    ],
                    "get": ["operationId": "things-list", "summary": "List things", "deprecated": true],
                ]
            ],
        ]
        let out = CatalogBuilder.build(doc)
        let c = APICatalog(json: out)
        #expect(c.operations.map(\.id).sorted() == ["things-create", "things-list"])
        let create = c.operation("things-create")!
        #expect(create.summary == "Create a thing")
        #expect(create.group == "things")
        #expect(create.permissions == ["Things Write"])
        #expect(create.params.map(\.name) == ["dry_run", "zone_id"])
        #expect(create.pathParams.first?.required == true)
        #expect(create.body?.required == true)
        #expect(Set(c.schemas.keys) == ["thing", "name"])
        #expect(c.schemas["thing"]?["x-extra"].isNull == true)
        #expect(c.resolve(c.resolve(create.body!.schema)["properties"]["n"])["example"].string == "x")
        #expect(c.operation("things-list")?.deprecated == true)
    }

    /// Set CATALOG_JSON to the decompressed bundled catalog to check it parses quickly.
    @Test func parsesTheRealCatalog() throws {
        guard let path = ProcessInfo.processInfo.environment["CATALOG_JSON"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let start = Date()
        let c = try APICatalog(data: data)
        let elapsed = Date().timeIntervalSince(start)
        print("catalog: \(c.operations.count) operations, \(c.schemas.count) schemas in \(String(format: "%.2f", elapsed)) s")
        #expect(c.operations.count > 3000)
        #expect(c.find("GET", "/zones/z/dns_records") != nil)
        #expect(!c.search("tunnel").isEmpty)
    }
}

@Suite struct ResourceSpecTests {
    static func catalog() throws -> ResourceCatalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Cirrus/Resources/resources.json")
        return ResourceCatalog(json: try JSON.parse(try Data(contentsOf: url)))
    }

    @Test func bundledSpecsLoad() throws {
        let c = try Self.catalog()
        #expect(c.specs.count >= 76)
        #expect(c.documents.count >= 20)
        #expect(c.specs(in: "access").count == 11)
        #expect(c.specs(in: "security").map(\.id) == ["ip_access_rules", "ua_rules", "zone_lockdowns"])
        #expect(c.spec("zone_worker_routes")?.scope == .zone)
        #expect(c.document("bot_management") != nil)
        // Every spec id in the lists exists.
        for (name, ids) in c.lists {
            for id in ids { #expect(c.spec(id) != nil, "\(name): \(id)") }
        }
        let queue = c.specs.first { $0.actions.contains { $0.body != nil } }
        #expect(queue != nil)
    }

    @Test func itemDisplay() throws {
        let c = try Self.catalog()
        let routes = try #require(c.spec("zone_worker_routes"))
        let item: JSON = ["id": "r1", "pattern": "example.com/*", "script": "api"]
        #expect(routes.title(of: item) == "example.com/*")
        #expect(routes.subtitle(of: item) == "api")
        #expect(routes.itemId(item) == "r1")
        #expect(ResourceSpec.fill(routes.resolvedItemPath, ids: ["zone_id": "z 1"], id: "r/1") == "/zones/z%201/workers/routes/r%2F1")
        let rules = try #require(c.spec("ip_access_rules"))
        #expect(rules.title(of: ["configuration": ["value": "203.0.113.1"]]) == "203.0.113.1")
        #expect(rules.status(of: ["mode": "block"])?.text == "block")
        let lockdown = try #require(c.spec("zone_lockdowns"))
        #expect(lockdown.status(of: ["paused": true])?.tone == .warn)
        #expect(lockdown.subtitle(of: ["urls": ["a.com/*", "b.com/*"]]) == "a.com/*, b.com/*")
        #expect(ResourceSpec.display(["a": 1]) == "{…}")
        #expect(ResourceSpec.display(.bool(true)) == "✓")
    }

    @Test func actionBodies() throws {
        let c = try Self.catalog()
        let devices = c.specs.flatMap { [$0] + $0.children }.flatMap(\.actions).first { $0.label.en == "Revoke" }
        let body = devices?.body(for: "dev-1")
        #expect(body == ["dev-1"])
        #expect(secretsIn(["secret": "0123456789abcdef0123", "client_id": "cid"]).map(\.key) == ["secret", "client_id"])
        #expect(secretsIn(["secret": "short"]).isEmpty)
    }
}

@Suite struct HelperTests {
    @Test func rules() {
        #expect(Rules.securityPhases.count == 4)
        #expect(Rules.transformPhases.count == 10)
        #expect(Rules.transformPhases.first { $0.phase == "http_request_cache_settings" }?.templates["set_cache_settings"]?["cache"].isTrue == true)
        let body = Rules.ruleBody(["id": "r", "version": "1", "action": "block", "expression": "true", "enabled": false, "ref": "x"])
        #expect(body == ["action": "block", "expression": "true", "enabled": false, "ref": "x"])
        #expect(Rules.actionTone("managed_challenge") == .warn)
        #expect(Rules.entrypoint("/zones/z", "http_ratelimit") == "/zones/z/rulesets/phases/http_ratelimit/entrypoint")
    }

    @Test func emailRouting() {
        let body = EmailRouting.ruleBody(local: "hi", zone: "example.com", type: "forward", values: ["me@x.y"], name: "n", enabled: true)
        #expect(body["matchers"][0]["value"].string == "hi@example.com")
        #expect(EmailRouting.describe(actions: body["actions"]) == "→ me@x.y")
        #expect(EmailRouting.describe(matchers: body["matchers"]) == "hi@example.com")
        let all = EmailRouting.ruleBody(local: nil, zone: "example.com", type: "drop", values: [], name: "", enabled: false)
        #expect(EmailRouting.isCatchAll(all))
        #expect(all["actions"][0]["value"].isNull)
        #expect(EmailRouting.describe(actions: all["actions"]) == "✗ drop")
    }

    @Test func tunnels() {
        let rules: [JSON] = [["service": "http_status:404"], ["hostname": "a.example.com", "service": "http://localhost:80"]]
        let ingress = Tunnels.ingress(rules)
        #expect(ingress.count == 2)
        #expect(ingress.last == ["service": "http_status:404"])
        #expect(Tunnels.ingress([["hostname": "a", "service": "x"]]).last == ["service": "http_status:404"])
        let https = Tunnels.split(service: "https://10.0.0.2:8443")
        #expect(https.scheme == "https" && https.target == "10.0.0.2:8443")
        let status = Tunnels.split(service: "http_status:404")
        #expect(status.scheme == "http_status" && status.target == "404")
        #expect(Tunnels.service(scheme: "ssh", target: "localhost:22") == "ssh://localhost:22")
        let zones: [JSON] = [["name": "example.com", "id": "1"], ["name": "sub.example.com", "id": "2"]]
        #expect(Tunnels.zone(for: "a.sub.example.com", in: zones)?["id"].string == "2")
        #expect(Tunnels.zone(for: "other.net", in: zones) == nil)
        #expect(Tunnels.installCommands(token: "T").count == 3)
    }

    @Test func lists() {
        #expect(RuleLists.parse("203.0.113.7 home office", kind: "ip") == ["ip": "203.0.113.7", "comment": "home office"])
        #expect(RuleLists.parse("AS13335", kind: "asn") == ["asn": 13335])
        #expect(RuleLists.parse("https://a/x https://b/y 302 moved", kind: "redirect")?["redirect"]["status_code"].int == 302)
        #expect(RuleLists.parse("https://a/x", kind: "redirect") == nil)
        #expect(RuleLists.label(["hostname": ["url_hostname": "h.example"]], kind: "hostname") == "h.example")
        #expect(RuleLists.title(of: "asn") == "ASNs" || RuleLists.title(of: "asn") == "ASN")
    }

    @Test func tokenPolicies() {
        let groups: [JSON] = [
            ["id": "g1", "scopes": ["com.cloudflare.api.account"]], ["id": "g2", "scopes": ["com.cloudflare.api.account.zone"]],
            ["id": "g3", "scopes": ["com.cloudflare.api.user"]],
        ]
        let p = APITokens.policies(groups: groups, accountId: "acc", zoneId: "z1", currentZoneOnly: true, userId: "u1")
        #expect(p.count == 3)
        #expect(p[0]["resources"]["com.cloudflare.api.account.acc"].string == "*")
        #expect(p[1]["resources"]["com.cloudflare.api.account.zone.z1"].string == "*")
        #expect(p[2]["permission_groups"][0]["id"].string == "g3")
        let all = APITokens.policies(groups: [groups[1]], accountId: "acc", zoneId: nil, currentZoneOnly: false, userId: nil)
        #expect(all[0]["resources"]["com.cloudflare.api.account.acc"]["com.cloudflare.api.account.zone.*"].string == "*")
        #expect(APITokens.expiry(days: 1, now: Date(timeIntervalSince1970: 0)) == "1970-01-02T00:00:00Z")
    }

    @Test func graphqlTemplates() {
        let t = GraphQLTemplate.all[0]
        let v = t.filledVariables(zoneId: "z", accountId: "a", now: ISODate.parse("2026-10-10T12:00:00Z")!)
        #expect(v["zoneTag"].string == "z")
        #expect(v["since"].string == "2026-10-03")
        #expect(v["until"].string == "2026-10-10")
        #expect(GraphQLTemplate.all.count == 8)
    }
}

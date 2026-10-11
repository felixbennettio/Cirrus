import Foundation

/// A parameter of an `APIOperation`.
public struct APIParam: Sendable, Hashable {
    public var name: String
    /// `path`, `query`, `header` or `cookie`.
    public var location: String
    public var required: Bool
    public var schema: JSON
    public var description: String?

    init(_ j: JSON) {
        name = j["n"].string ?? ""
        location = j["in"].string ?? "query"
        required = j["r"].isTrue
        schema = j["s"]
        description = j["d"].string
    }
}

/// The request body of an `APIOperation`.
public struct APIBody: Sendable, Hashable {
    public var contentType: String
    public var alternatives: [String]
    public var required: Bool
    public var schema: JSON

    init(_ j: JSON) {
        contentType = j["ct"].string ?? "application/json"
        alternatives = j["alt"].strings
        required = j["r"].isTrue
        schema = j["s"]
    }

    public var isJSON: Bool { contentType.contains("json") }
    public var isMultipart: Bool { contentType.hasPrefix("multipart/") }
}

/// One endpoint of the Cloudflare API.
public struct APIOperation: Sendable, Hashable, Identifiable {
    public var id: String
    public var method: String
    public var path: String
    public var summary: String
    public var description: String?
    /// SDK group such as `dns.records` or `zero_trust.access.applications`.
    public var group: String
    public var methodName: String?
    public var tag: String?
    /// API token permission groups, e.g. `DNS Write`.
    public var permissions: [String]
    public var plans: [String]
    public var deprecated: Bool
    public var availability: String?
    public var params: [APIParam]
    public var body: APIBody?
    let segments: [String]
    let haystack: String

    init(_ j: JSON) {
        id = j["id"].string ?? ""
        method = j["m"].string ?? "GET"
        path = j["p"].string ?? "/"
        summary = j["s"].string ?? ""
        description = j["d"].string
        group = j["g"].string ?? "misc"
        methodName = j["n"].string
        tag = j["t"].string
        permissions = j["perm"].strings
        plans = j["plan"].strings
        deprecated = j["dep"].isTrue
        availability = j["av"].string
        params = j["params"].items.map(APIParam.init)
        body = j["body"].isNull ? nil : APIBody(j["body"])
        segments = path.split(separator: "/").map(String.init)
        haystack = "\(method.lowercased()) \(path) \(summary) \(group) \(tag ?? "") \(methodName ?? "") \(id)".lowercased()
    }

    public var product: String { String(group.split(separator: ".").first ?? "misc") }
    public var isMutation: Bool { method != "GET" }
    public var pathParams: [APIParam] { params.filter { $0.location == "path" } }
    public var queryParams: [APIParam] { params.filter { $0.location == "query" } }
    public var headerParams: [APIParam] { params.filter { $0.location == "header" } }

    /// Whether [concretePath] (without a query) fits this path template.
    public func matches(_ method: String, _ concretePath: String) -> Bool {
        guard method.uppercased() == self.method else { return false }
        let parts = (concretePath.split(separator: "?").first ?? "").split(separator: "/")
        guard parts.count == segments.count else { return false }
        for (p, s) in zip(parts, segments) where !s.hasPrefix("{") && p != s {
            return false
        }
        return true
    }

    var literalCount: Int { segments.filter { !$0.hasPrefix("{") }.count }

    /// How well this operation matches all [terms] (0 = no match).
    func score(_ terms: [String]) -> Int {
        var total = 0
        let s = summary.lowercased()
        let g = group.lowercased()
        for t in terms {
            if !haystack.contains(t) { return 0 }
            if s.contains(t) { total += 3 }
            if g.contains(t) { total += 2 }
            total += 1
        }
        return deprecated ? total - 1 : total
    }

    public static func == (a: APIOperation, b: APIOperation) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// The index of every Cloudflare API endpoint (bundled, or rebuilt from the
/// OpenAPI schema).
public final class APICatalog: @unchecked Sendable {
    public let operations: [APIOperation]
    public let schemas: [String: JSON]
    public let generated: Date?
    public let apiVersion: String?
    public let byProduct: [(product: String, operations: [APIOperation])]
    private let byId: [String: APIOperation]

    public init(json: JSON) {
        operations = json["ops"].items.map(APIOperation.init)
        schemas = json["schemas"].object ?? [:]
        generated = json["generated"].string.flatMap(ISODate.parse)
        apiVersion = json["apiVersion"].string
        var m: [String: [APIOperation]] = [:]
        var ids: [String: APIOperation] = [:]
        for o in operations {
            m[o.product, default: []].append(o)
            ids[o.id] = o
        }
        byProduct = m.keys.sorted().map { ($0, m[$0]!) }
        byId = ids
    }

    public convenience init(data: Data) throws {
        self.init(json: try JSON.parse(data))
    }

    public func operation(_ id: String) -> APIOperation? { byId[id] }

    /// The operation behind a concrete request, preferring the template with
    /// the most literal segments.
    public func find(_ method: String, _ concretePath: String) -> APIOperation? {
        var best: APIOperation?
        for o in operations where o.matches(method, concretePath) {
            if best == nil || o.literalCount > best!.literalCount { best = o }
        }
        return best
    }

    public func search(_ query: String, limit: Int = 200) -> [APIOperation] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return Array(operations.prefix(limit)) }
        return operations.compactMap { o -> (Int, APIOperation)? in
            let s = o.score(terms)
            return s > 0 ? (s, o) : nil
        }
        .sorted { $0.0 > $1.0 }
        .prefix(limit)
        .map { $0.1 }
    }

    /// Follows `$ref`s and merges `allOf`, so callers get a concrete schema.
    public func resolve(_ schema: JSON, depth: Int = 0) -> JSON {
        guard var s = schema.object else { return [:] }
        var guardCount = 0
        while let ref = s["$ref"]?.string, guardCount < 16 {
            guardCount += 1
            guard let target = schemas[ref]?.object else { return [:] }
            s = target
        }
        guard let allOf = s["allOf"]?.array, depth < 12 else { return .object(s) }
        var merged = s
        merged["allOf"] = nil
        var props = s["properties"]?.object ?? [:]
        var required = s["required"]?.strings ?? []
        for part in allOf {
            let r = resolve(part, depth: depth + 1)
            for (k, v) in r["properties"].object ?? [:] { props[k] = v }
            for k in r["required"].strings where !required.contains(k) { required.append(k) }
            for k in ["type", "description", "enum", "items", "oneOf", "anyOf", "format"] where merged[k] == nil {
                if !r[k].isNull { merged[k] = r[k] }
            }
        }
        if !props.isEmpty {
            merged["properties"] = .object(props)
            if merged["type"] == nil { merged["type"] = "object" }
        }
        if !required.isEmpty { merged["required"] = .array(required.map(JSON.string)) }
        return .object(merged)
    }

    /// The type of a resolved schema (`object`, `array`, `string`, …).
    public static func type(of s: JSON) -> String {
        if let t = s["type"].string { return t }
        if let list = s["type"].array, let first = list.first(where: { $0.string != "null" }) ?? list.first {
            return first.text ?? "unknown"
        }
        if !s["properties"].isNull { return "object" }
        if !s["items"].isNull { return "array" }
        if !s["enum"].isNull { return "string" }
        return "unknown"
    }

    /// An example value for [schema], to pre-fill request bodies.
    public func skeleton(_ schema: JSON, depth: Int = 0, requiredOnly: Bool = false, now: Date = Date()) -> JSON {
        if schema.isNull || depth > 6 { return .null }
        let s = resolve(schema)
        if !s["example"].isNull { return s["example"] }
        if !s["default"].isNull { return s["default"] }
        if let first = s["enum"].array?.first { return first }
        if let variant = (s["oneOf"].array ?? s["anyOf"].array)?.first {
            return skeleton(variant, depth: depth + 1, requiredOnly: requiredOnly, now: now)
        }
        let type = s["type"].string ?? (s["properties"].isNull ? nil : "object")
        switch type {
        case "object":
            let req = Set(s["required"].strings)
            var out: [String: JSON] = [:]
            for (k, v) in s["properties"].object ?? [:] {
                if resolve(v)["readOnly"].isTrue { continue }
                if (requiredOnly || depth > 0) && !req.contains(k) && !req.isEmpty { continue }
                out[k] = skeleton(v, depth: depth + 1, requiredOnly: requiredOnly, now: now)
            }
            return .object(out)
        case "array":
            let item = skeleton(s["items"], depth: depth + 1, requiredOnly: requiredOnly, now: now)
            return item.isNull ? [] : [item]
        case "integer", "number":
            return s["minimum"].isNull ? 0 : s["minimum"]
        case "boolean":
            return false
        case "string":
            switch s["format"].string {
            case "date-time": return .string(ISODate.format(now))
            case "email": return "user@example.com"
            case "uri", "url": return "https://example.com"
            default: return ""
            }
        default:
            return .null
        }
    }

    /// Keeps only the fields an update body accepts (for editing an item).
    public func filter(_ item: JSON, for schema: JSON) -> JSON {
        var allowed = Set<String>()
        func collect(_ sch: JSON, _ depth: Int) {
            let r = resolve(sch)
            for (k, v) in r["properties"].object ?? [:] where !resolve(v)["readOnly"].isTrue {
                allowed.insert(k)
            }
            if depth > 3 { return }
            for k in ["oneOf", "anyOf"] {
                for x in r[k].items { collect(x, depth + 1) }
            }
        }
        collect(schema, 0)
        guard let o = item.object else { return item }
        if allowed.isEmpty { return item }
        return .object(o.filter { allowed.contains($0.key) })
    }
}

/// Reduces the official OpenAPI document to the compact catalog format.
public enum CatalogBuilder {
    public static let openAPIURL = URL(string: "https://raw.githubusercontent.com/cloudflare/api-schemas/main/openapi.json")!

    static let methods = ["get", "post", "put", "patch", "delete"]
    static let keepKeys: Set<String> = [
        "type", "format", "enum", "items", "properties", "required", "oneOf", "anyOf", "allOf", "description", "default",
        "example", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "nullable", "readOnly",
        "writeOnly", "title", "additionalProperties", "const", "deprecated",
    ]
    static let authHeaders: Set<String> = ["x-auth-email", "x-auth-key", "authorization", "x-auth-user-service-key"]

    public static func build(_ doc: JSON, now: Date = Date()) -> JSON {
        let components = doc["components"]
        let schemas = components["schemas"].object ?? [:]
        let parameters = components["parameters"].object ?? [:]
        let requestBodies = components["requestBodies"].object ?? [:]
        var referenced = Set<String>()
        var ops: [JSON] = []

        func resolveRef(_ node: JSON, _ pool: [String: JSON]) -> JSON {
            var current = node
            var n = 0
            while let ref = current["$ref"].string, n < 8 {
                n += 1
                guard let next = pool[String(ref.split(separator: "/").last ?? "")], next.object != nil else { break }
                current = next
            }
            return current
        }

        for (path, item) in doc["paths"].object ?? [:] {
            let shared = item["parameters"].items
            for method in methods {
                let op = item[method]
                guard op.object != nil else { continue }
                var params: [JSON] = []
                var seen = Set<String>()
                for p in op["parameters"].items + shared {
                    let param = resolveRef(p, parameters)
                    guard let name = param["name"].string, let location = param["in"].string else { continue }
                    guard seen.insert("\(location):\(name)").inserted else { continue }
                    if location == "header" && authHeaders.contains(name.lowercased()) { continue }
                    var out: [String: JSON] = ["n": .string(name), "in": .string(location)]
                    if param["required"].isTrue || location == "path" { out["r"] = true }
                    if param["schema"].object != nil { out["s"] = minSchema(param["schema"], &referenced) }
                    if let d = text(param["description"], 240) { out["d"] = .string(d) }
                    params.append(.object(out))
                }
                var body: JSON?
                let rb = op["requestBody"]
                if rb.object != nil {
                    let resolved = resolveRef(rb, requestBodies)
                    let content = resolved["content"].object ?? [:]
                    if !content.isEmpty {
                        let ct = content["application/json"] != nil ? "application/json" : content.keys.sorted().first!
                        var b: [String: JSON] = ["ct": .string(ct)]
                        if content.count > 1 { b["alt"] = .array(content.keys.sorted().map(JSON.string)) }
                        if resolved["required"].isTrue { b["r"] = true }
                        if content[ct]?["schema"].object != nil { b["s"] = minSchema(content[ct]!["schema"], &referenced) }
                        body = .object(b)
                    }
                }
                var security = Set<String>()
                for s in (op["security"].array ?? doc["security"].items) {
                    if let keys = s.object?.keys { security.formUnion(keys) }
                }
                var o: [String: JSON] = [
                    "id": .string(op["operationId"].string ?? "\(method) \(path)"), "m": .string(method.uppercased()),
                    "p": .string(path), "s": .string((op["summary"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                    "g": .string(op["x-fern-sdk-group-name"].string ?? groupFromPath(path)),
                ]
                if let d = text(op["description"], 900) { o["d"] = .string(d) }
                if let n = op["x-fern-sdk-method-name"].string { o["n"] = .string(n) }
                if let t = op["tags"].strings.first { o["t"] = .string(t) }
                let perms = op["x-api-token-group"].strings
                if !perms.isEmpty { o["perm"] = .array(perms.map(JSON.string)) }
                if let plan = op["x-cfPlanAvailability"].object {
                    o["plan"] = .array(plan.filter { $0.value.isTrue }.keys.sorted().map(JSON.string))
                }
                if op["deprecated"].isTrue || !op["x-stainless-deprecation-message"].isNull || !op["x-cfDeprecation"].isNull {
                    o["dep"] = true
                }
                if let av = op["x-fern-availability"].string, av != "generally-available" { o["av"] = .string(av) }
                if !security.isEmpty { o["auth"] = .array(security.sorted().map(JSON.string)) }
                if !params.isEmpty { o["params"] = .array(params) }
                if let body { o["body"] = body }
                ops.append(.object(o))
            }
        }

        var out: [String: JSON] = [:]
        var queue = Array(referenced)
        while let name = queue.popLast() {
            if out[name] != nil { continue }
            guard let schema = schemas[name], schema.object != nil else { continue }
            var nested = Set<String>()
            out[name] = minSchema(schema, &nested)
            queue.append(contentsOf: nested.filter { out[$0] == nil })
        }

        ops.sort {
            let a = ($0["g"].string ?? "", $0["p"].string ?? "", $0["m"].string ?? "")
            let b = ($1["g"].string ?? "", $1["p"].string ?? "", $1["m"].string ?? "")
            return a < b
        }
        return [
            "v": 1, "generated": .string(ISODate.format(now)), "title": doc["info"]["title"],
            "apiVersion": doc["info"]["version"],
            "server": .string(doc["servers"][0]["url"].string ?? cfAPIBase.absoluteString), "ops": .array(ops),
            "schemas": .object(out),
        ]
    }

    static func groupFromPath(_ path: String) -> String {
        let s = path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("{") }
        if s.count >= 2 && (s[0] == "accounts" || s[0] == "zones") { return s[1] }
        return s.first ?? "misc"
    }

    static func text(_ value: JSON, _ max: Int) -> String? {
        guard let t = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.count <= max { return t }
        let cut = String(t.prefix(max))
        if let r = cut.range(of: #"[.\n][^.\n]*$"#, options: .regularExpression),
            cut.distance(from: cut.startIndex, to: r.lowerBound) > Int(Double(max) * 0.6)
        {
            return String(cut[..<cut.index(after: r.lowerBound)]) + "…"
        }
        return cut + "…"
    }

    static func minSchema(_ node: JSON, _ refs: inout Set<String>) -> JSON {
        if let list = node.array { return .array(list.map { minSchema($0, &refs) }) }
        guard let o = node.object else { return node }
        if let ref = o["$ref"]?.string {
            let name = String(ref.split(separator: "/").last ?? "")
            refs.insert(name)
            return ["$ref": .string(name)]
        }
        var out: [String: JSON] = [:]
        for (k, v) in o where keepKeys.contains(k) {
            switch k {
            case "description":
                if let d = text(v, 240) { out[k] = .string(d) }
            case "example", "default":
                switch v {
                case .int, .double, .bool: out[k] = v
                case .string(let s) where s.count <= 120: out[k] = v
                case .array(let a) where a.count <= 8 && a.allSatisfy({ $0.string != nil || $0.double != nil }): out[k] = v
                default: break
                }
            case "properties":
                var props: [String: JSON] = [:]
                for (pk, pv) in v.object ?? [:] { props[pk] = minSchema(pv, &refs) }
                out[k] = .object(props)
            case "items", "additionalProperties", "oneOf", "anyOf", "allOf":
                out[k] = minSchema(v, &refs)
            default:
                out[k] = v
            }
        }
        return .object(out)
    }
}

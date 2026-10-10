import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The Cloudflare API's base URL.
public let cfAPIBase = URL(string: "https://api.cloudflare.com/client/v4")!

/// Supplies bearer tokens for OAuth profiles (see `OAuthSession`).
public protocol AccessTokenSource: Sendable {
    /// The last token handed out, if any.
    func currentToken() async -> String?
    /// A valid access token. Pass the token the API just rejected to force a
    /// refresh (unless another request already replaced it).
    func accessToken(rejected: String?) async throws -> String
}

/// The body of a request.
public enum RequestBody: Sendable {
    case json(JSON)
    case data(Data, contentType: String?)
    case multipart(MultipartForm)
    /// `application/x-www-form-urlencoded`.
    case form([(String, String)])

    var contentType: String? {
        switch self {
        case .json: return "application/json"
        case .data(_, let ct): return ct
        case .multipart(let m): return m.contentType
        case .form: return "application/x-www-form-urlencoded"
        }
    }

    var data: Data {
        switch self {
        case .json(let j): return j.encoded()
        case .data(let d, _): return d
        case .multipart(let m): return m.body
        case .form(let pairs):
            return Data(pairs.map { "\(URLEncoding.formEncode($0.0))=\(URLEncoding.formEncode($0.1))" }
                .joined(separator: "&").utf8)
        }
    }
}

/// A parsed Cloudflare v4 envelope (or a raw JSON body without one).
public struct CFResponse: Sendable {
    public var statusCode: Int
    public var result: JSON
    public var resultInfo: JSON?
    public var messages: [CFMessage]
    /// Lower-cased header names.
    public var headers: [String: String]
    public var raw: JSON
    public var duration: TimeInterval
}

/// A response read as bytes, without envelope parsing (downloads, scripts…).
public struct CFRawResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    /// Lower-cased header names.
    public var headers: [String: String]
    public var duration: TimeInterval

    public var ok: Bool { (200..<300).contains(statusCode) }
    public var text: String { String(decoding: data, as: UTF8.self) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// One page of a list endpoint.
public struct CFPage: Sendable {
    public var items: [JSON]
    public var page: Int?
    public var perPage: Int?
    public var totalPages: Int?
    public var totalCount: Int?
    public var cursor: String?

    public var hasMore: Bool {
        if let cursor, !cursor.isEmpty { return true }
        if let page, let totalPages { return page < totalPages }
        if let perPage { return items.count >= perPage }
        return false
    }
}

/// A line of the in-app request log (never contains credentials or queries).
public struct RequestRecord: Sendable, Identifiable {
    public let id = UUID()
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var duration: TimeInterval
    public var at: Date
    public var error: String?
}

/// The most recent requests of a client, newest first.
public final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [RequestRecord] = []
    /// Called (on any thread) after every request.
    public var onChange: (@Sendable ([RequestRecord]) -> Void)?

    public init() {}

    public var records: [RequestRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    func add(_ r: RequestRecord) {
        lock.lock()
        _records.insert(r, at: 0)
        if _records.count > 200 { _records.removeLast(_records.count - 200) }
        let snapshot = _records
        lock.unlock()
        onChange?(snapshot)
    }
}

/// Typed access to the Cloudflare REST and GraphQL API for one profile.
public final class CFClient: @unchecked Sendable {
    public let profile: Profile
    public let baseURL: URL
    /// Token source for OAuth profiles.
    public let tokens: AccessTokenSource?
    public let log: RequestLog
    let session: URLSession

    /// Sent as `User-Agent`, e.g. `Cirrus/2.0.0`.
    nonisolated(unsafe) public static var userAgent = "Cirrus"

    public init(
        profile: Profile, tokens: AccessTokenSource? = nil, baseURL: URL = cfAPIBase, session: URLSession? = nil,
        log: RequestLog = RequestLog()
    ) {
        self.profile = profile
        self.tokens = tokens
        self.baseURL = baseURL
        self.log = log
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: URLs and headers

    /// The URL for [path] (relative to the API base unless absolute) with
    /// [query]; nil values are left out, keys are sorted.
    public func url(_ path: String, query: [String: String?] = [:]) -> URL {
        let base = path.hasPrefix("http") ? path : baseURL.absoluteString + path
        guard var comps = URLComponents(string: base) else { return URL(string: base) ?? baseURL }
        let extra = query.compactMap { k, v in v.map { (k, $0) } }.sorted { $0.0 < $1.0 }
        if !extra.isEmpty {
            let existing = comps.percentEncodedQuery.map { [$0] } ?? []
            comps.percentEncodedQuery = (existing + extra.map {
                "\(URLEncoding.queryEncode($0.0))=\(URLEncoding.queryEncode($0.1))"
            }).joined(separator: "&")
        }
        return comps.url ?? URL(string: base) ?? baseURL
    }

    private func usesOriginCAKey(_ path: String, _ originCA: Bool) -> Bool {
        (originCA || path.hasPrefix("/certificates")) && !(profile.originCaKey ?? "").isEmpty
    }

    /// OAuth profiles send a bearer token, except where an Origin CA key applies.
    private func usesBearer(_ path: String, _ originCA: Bool) -> Bool {
        profile.kind == .oauth && !usesOriginCAKey(path, originCA)
    }

    private func authHeaders(_ path: String, originCA: Bool, bearer: String?) -> [String: String] {
        if usesBearer(path, originCA) { return ["Authorization": "Bearer \(bearer ?? "")"] }
        return profile.authHeaders(originCA: originCA || path.hasPrefix("/certificates"))
    }

    private func bearer(_ method: String, _ path: String, rejected: String?) async throws -> String {
        guard let tokens else {
            throw CFAPIError(
                method: method, path: path, statusCode: 401, cause: "No OAuth session for this credential.")
        }
        do {
            return try await tokens.accessToken(rejected: rejected)
        } catch let e as OAuthError {
            throw CFAPIError(
                method: method, path: path, statusCode: e.needsReauth ? 401 : nil,
                cause: e.needsReauth ? "The Cloudflare sign-in has expired. Sign in again. (\(e))" : e.description)
        }
    }

    // MARK: Sending

    /// Sends a request, retrying rate limits, server errors (idempotent
    /// requests only) and transient network errors, and refreshing a rejected
    /// OAuth token once.
    private func perform(
        _ method: String, _ path: String, query: [String: String?], body: RequestBody?,
        headers: [String: String], originCA: Bool
    ) async throws -> (Data, HTTPURLResponse, TimeInterval) {
        let target = url(path, query: query)
        let idempotent = method == "GET" || method == "HEAD"
        let useBearer = usesBearer(path, originCA)
        var bearer: String?
        var rejected: String?
        var reauthenticated = false
        var attempt = 0
        let started = Date()
        while true {
            attempt += 1
            if useBearer { bearer = try await self.bearer(method, path, rejected: rejected) }
            var req = URLRequest(url: target)
            req.httpMethod = method
            req.setValue(CFClient.userAgent, forHTTPHeaderField: "User-Agent")
            for (k, v) in authHeaders(path, originCA: originCA, bearer: bearer) { req.setValue(v, forHTTPHeaderField: k) }
            if let body {
                req.httpBody = body.data
                if let ct = body.contentType, headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                    req.setValue(ct, forHTTPHeaderField: "Content-Type")
                }
            }
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let sw = Date()
            do {
                let (data, res) = try await session.cirrusData(for: req)
                record(method, target, status: res.statusCode, since: sw, error: nil)
                let status = res.statusCode
                if status == 401 && useBearer && !reauthenticated {
                    reauthenticated = true
                    rejected = bearer
                    continue
                }
                let retryable = status == 429 || (idempotent && status >= 500)
                if retryable && attempt <= 3 {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay(res, attempt: attempt) * 1_000_000_000))
                    continue
                }
                return (data, res, Date().timeIntervalSince(started))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as CFAPIError {
                throw e
            } catch {
                record(method, target, status: nil, since: sw, error: error.localizedDescription)
                let transient = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                     .dnsLookupFailed, .cannotFindHost].contains($0.code)
                } ?? false
                if idempotent && transient && attempt <= 2 {
                    try await Task.sleep(nanoseconds: UInt64(400_000_000 * attempt))
                    continue
                }
                throw CFAPIError(method: method, path: path, cause: error.localizedDescription)
            }
        }
    }

    private func retryDelay(_ res: HTTPURLResponse, attempt: Int) -> Double {
        if let ra = res.value(forHTTPHeaderField: "Retry-After"), let secs = Int(ra.trimmingCharacters(in: .whitespaces)) {
            return Double(min(max(secs, 1), 30))
        }
        return 0.6 * Double(1 << (attempt - 1))
    }

    private func record(_ method: String, _ url: URL, status: Int?, since: Date, error: String?) {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        log.add(
            RequestRecord(
                method: method, url: comps?.url?.absoluteString ?? url.absoluteString, statusCode: status,
                duration: Date().timeIntervalSince(since), at: Date(), error: error))
    }

    /// Sends a request and parses the `{success, errors, result}` envelope.
    /// Throws `CFAPIError` when the call fails.
    @discardableResult
    public func send(
        _ method: String, _ path: String, query: [String: String?] = [:], body: RequestBody? = nil,
        headers: [String: String] = [:], originCA: Bool = false
    ) async throws -> CFResponse {
        let (data, res, duration) = try await perform(
            method, path, query: query, body: body, headers: headers, originCA: originCA)
        return try CFClient.parseEnvelope(
            method: method, path: path, statusCode: res.statusCode, body: data, headers: res.lowerCasedHeaders,
            duration: duration)
    }

    /// Reads a response body as an envelope (exposed for tests).
    public static func parseEnvelope(
        method: String, path: String, statusCode: Int, body: Data, headers: [String: String] = [:],
        duration: TimeInterval = 0
    ) throws -> CFResponse {
        let text = String(decoding: body, as: UTF8.self)
        let trimmed = text.drop { $0.isWhitespace }
        var data: JSON = .string(text)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let parsed = try? JSON.parse(body) {
            data = parsed
        } else if text.isEmpty {
            data = .null
        }
        let ok = (200..<300).contains(statusCode)
        if case .object(let o) = data, o["success"] != nil, o["result"] != nil || o["errors"] != nil {
            let errors = data["errors"].items.map(CFMessage.init(json:))
            let messages = data["messages"].items.map(CFMessage.init(json:))
            if data["success"].bool != true || !ok {
                throw CFAPIError(
                    method: method, path: path, statusCode: statusCode, errors: errors.isEmpty ? messages : errors,
                    body: errors.isEmpty && messages.isEmpty ? data.compactString : nil)
            }
            let info = data["result_info"]
            return CFResponse(
                statusCode: statusCode, result: data["result"], resultInfo: info.object != nil ? info : nil,
                messages: messages, headers: headers, raw: data, duration: duration)
        }
        if case .object(let o) = data, case .array(let errs)? = o["errors"], !errs.isEmpty, o["data"] == nil {
            throw CFAPIError(
                method: method, path: path, statusCode: statusCode, errors: errs.map(CFMessage.init(json:)))
        }
        if !ok {
            throw CFAPIError(
                method: method, path: path, statusCode: statusCode, body: data.string ?? data.compactString)
        }
        return CFResponse(
            statusCode: statusCode, result: data, resultInfo: nil, messages: [], headers: headers, raw: data,
            duration: duration)
    }

    @discardableResult
    public func get(_ path: String, query: [String: String?] = [:]) async throws -> JSON {
        try await send("GET", path, query: query).result
    }

    @discardableResult
    public func post(_ path: String, _ body: JSON? = nil, query: [String: String?] = [:]) async throws -> JSON {
        try await send("POST", path, query: query, body: body.map(RequestBody.json)).result
    }

    @discardableResult
    public func put(_ path: String, _ body: JSON? = nil, query: [String: String?] = [:]) async throws -> JSON {
        try await send("PUT", path, query: query, body: body.map(RequestBody.json)).result
    }

    @discardableResult
    public func patch(_ path: String, _ body: JSON? = nil, query: [String: String?] = [:]) async throws -> JSON {
        try await send("PATCH", path, query: query, body: body.map(RequestBody.json)).result
    }

    @discardableResult
    public func delete(_ path: String, _ body: JSON? = nil, query: [String: String?] = [:]) async throws -> JSON {
        try await send("DELETE", path, query: query, body: body.map(RequestBody.json)).result
    }

    // MARK: Pagination

    /// One page of a list endpoint (page/per_page or cursor pagination).
    public func page(
        _ path: String, query: [String: String?] = [:], page: Int? = nil, perPage: Int? = nil, cursor: String? = nil
    ) async throws -> CFPage {
        var q = query
        if let page { q["page"] = String(page) }
        if let perPage { q["per_page"] = String(perPage) }
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        let res = try await send("GET", path, query: q)
        let info = res.resultInfo ?? .null
        let result = res.result
        let items: [JSON]
        switch result {
        case .array(let a): items = a
        case .object(let o) where o["items"]?.array != nil: items = result["items"].items
        case .object(let o) where o["objects"]?.array != nil: items = result["objects"].items
        case .object(let o) where o["buckets"]?.array != nil: items = result["buckets"].items
        case .null: items = []
        default: items = [result]
        }
        return CFPage(
            items: items, page: info["page"].int, perPage: info["per_page"].int ?? perPage,
            totalPages: info["total_pages"].int, totalCount: info["total_count"].int,
            cursor: info["cursor"].string ?? result["cursor"].string ?? info["cursors"]["after"].string)
    }

    /// Every item of a list endpoint, page after page (up to [maxItems]).
    public func list(
        _ path: String, query: [String: String?] = [:], perPage: Int = 50, maxItems: Int = 5000,
        paginate: Bool = true, cursorPagination: Bool = false
    ) async throws -> [JSON] {
        var out: [JSON] = []
        var pageNo = 1
        var cursor: String?
        while true {
            let p = try await page(
                path, query: query, page: (paginate && !cursorPagination && cursor == nil) ? pageNo : nil,
                perPage: paginate ? perPage : nil, cursor: cursor)
            out.append(contentsOf: p.items.filter { $0.object != nil })
            if !paginate || out.count >= maxItems || p.items.isEmpty { break }
            if let next = p.cursor, !next.isEmpty {
                if next == cursor { break }
                cursor = next
                continue
            }
            // Stop when the server ignored the page parameter (it would loop forever).
            if let total = p.totalPages, let current = p.page, current == pageNo, current < total {
                pageNo += 1
                continue
            }
            break
        }
        return out
    }

    // MARK: Raw and GraphQL

    /// A request whose response is returned as bytes, without envelope parsing.
    public func raw(
        _ method: String, _ path: String, query: [String: String?] = [:], body: RequestBody? = nil,
        headers: [String: String] = [:]
    ) async throws -> CFRawResponse {
        let (data, res, duration) = try await perform(
            method, path, query: query, body: body, headers: headers, originCA: false)
        return CFRawResponse(statusCode: res.statusCode, data: data, headers: res.lowerCasedHeaders, duration: duration)
    }

    /// Like [raw], but throws `CFAPIError` for a non-2xx response.
    public func rawOK(
        _ method: String, _ path: String, query: [String: String?] = [:], body: RequestBody? = nil,
        headers: [String: String] = [:]
    ) async throws -> CFRawResponse {
        let r = try await raw(method, path, query: query, body: body, headers: headers)
        if !r.ok {
            _ = try CFClient.parseEnvelope(method: method, path: path, statusCode: r.statusCode, body: r.data)
        }
        return r
    }

    /// Runs a query against the GraphQL Analytics API and returns `data`.
    public func graphql(_ query: String, variables: JSON = [:]) async throws -> JSON {
        let body: JSON = ["query": .string(query), "variables": variables]
        let (data, res, _) = try await perform(
            "POST", "/graphql", query: [:], body: .json(body), headers: [:], originCA: false)
        guard let json = try? JSON.parse(data), json.object != nil else {
            throw CFAPIError(
                method: "POST", path: "/graphql", statusCode: res.statusCode,
                body: String(decoding: data, as: UTF8.self))
        }
        let errors = json["errors"].items
        if !errors.isEmpty {
            throw CFAPIError(
                method: "POST", path: "/graphql", statusCode: res.statusCode, errors: errors.map(CFMessage.init(json:)))
        }
        if res.statusCode >= 400 {
            throw CFAPIError(method: "POST", path: "/graphql", statusCode: res.statusCode, body: json.compactString)
        }
        return json["data"].object != nil ? json["data"] : [:]
    }

    /// A copy-pasteable cURL command. Secrets are replaced by environment
    /// variable names unless [includeSecrets].
    public func curl(
        _ method: String, _ path: String, query: [String: String?] = [:], body: JSON? = nil,
        includeSecrets: Bool = false
    ) -> String {
        var out = "curl -X \(method) '\(url(path, query: query).absoluteString)'"
        let headers = authHeaders(path, originCA: false, bearer: nil).sorted { $0.key < $1.key }
        for (k, v) in headers {
            let value: String
            if includeSecrets {
                value = v
            } else {
                switch k {
                case "Authorization": value = "Bearer $CLOUDFLARE_API_TOKEN"
                case "X-Auth-Key": value = "$CLOUDFLARE_API_KEY"
                case "X-Auth-Email": value = "$CLOUDFLARE_EMAIL"
                default: value = "$CLOUDFLARE_ORIGIN_CA_KEY"
                }
            }
            out += " \\\n  -H '\(k): \(value)'"
        }
        if let body {
            out += " \\\n  -H 'Content-Type: application/json'"
            let text = body.string ?? body.prettyString
            out += " \\\n  --data '\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return out
    }
}

// MARK: - Helpers

enum URLEncoding {
    /// RFC 3986 unreserved characters stay, everything else is escaped (so a
    /// `+` in a value is not read as a space).
    static let unreserved: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func queryEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func formEncode(_ s: String) -> String { queryEncode(s) }

    /// Encodes one path segment (ids, names with spaces or slashes).
    static func pathEncode(_ s: String) -> String { queryEncode(s) }
}

public extension String {
    /// This string escaped for use as one URL path segment.
    var pathEncoded: String { URLEncoding.pathEncode(self) }
}

extension HTTPURLResponse {
    var lowerCasedHeaders: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in allHeaderFields {
            out[String(describing: k).lowercased()] = String(describing: v)
        }
        return out
    }
}

extension URLSession {
    /// `data(for:)` that works the same on Apple platforms and Linux, and
    /// cancels the transfer when the task is cancelled.
    func cirrusData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = self.dataTask(with: request) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        cont.resume(returning: (data ?? Data(), http))
                    } else {
                        cont.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionDataTask?
    var task: URLSessionDataTask? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _task
        }
        set {
            lock.lock()
            _task = newValue
            lock.unlock()
        }
    }
}

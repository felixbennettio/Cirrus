import Foundation

/// One module (file) of a Worker script.
public struct WorkerModule: Sendable, Hashable, Identifiable {
    public var name: String
    public var contentType: String
    public var data: Data

    public var id: String { name }

    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }

    public var isText: Bool {
        let ct = contentType
        if ct.contains("javascript") || ct.contains("text") || ct.contains("json") { return true }
        return [".js", ".mjs", ".ts", ".map", ".json", ".txt", ".html"].contains { name.hasSuffix($0) }
    }

    public var text: String {
        get { String(decoding: data, as: UTF8.self) }
        set { data = Data(newValue.utf8) }
    }
}

/// A Worker's code: its modules and which one is the entry point.
public struct WorkerContent: Sendable, Hashable {
    public var mainModule: String
    public var modules: [WorkerModule]
    /// ES modules (`export default {}`) rather than the service-worker syntax.
    public var moduleSyntax: Bool

    public init(mainModule: String, modules: [WorkerModule], moduleSyntax: Bool) {
        self.mainModule = mainModule
        self.modules = modules
        self.moduleSyntax = moduleSyntax
    }

    public var main: WorkerModule? { modules.first { $0.name == mainModule } ?? modules.first }
}

/// A point of a Worker's hourly metrics.
public struct WorkerMetricsPoint: Sendable, Identifiable {
    public var id: Date { at }
    public var at: Date
    public var requests: Double
    public var errors: Double
    public var subrequests: Double
    public var cpuP50: Double
    public var cpuP99: Double
}

public enum Workers {
    public static func scriptPath(_ accountId: String, _ script: String) -> String {
        "/accounts/\(accountId.pathEncoded)/workers/scripts/\(script.pathEncoded)"
    }

    /// The content type a module is uploaded with.
    public static func contentType(for name: String, moduleSyntax: Bool) -> String {
        if name.hasSuffix(".wasm") { return "application/wasm" }
        if name.hasSuffix(".map") { return "application/source-map" }
        if name.hasSuffix(".json") { return "application/json" }
        if name.hasSuffix(".txt") { return "text/plain" }
        if name.hasSuffix(".py") { return "text/x-python" }
        return moduleSyntax ? "application/javascript+module" : "application/javascript"
    }

    /// Reads a `content/v2` response: a multipart body with one part per
    /// module, or a single script.
    public static func parseContent(_ data: Data, contentType: String?, entrypoint: String?) -> WorkerContent {
        if let boundary = multipartBoundary(contentType) {
            let modules = parseMultipart(data, boundary: boundary).map { p in
                WorkerModule(
                    name: p.filename ?? p.name ?? "module", contentType: p.contentType ?? "application/javascript+module",
                    data: p.data)
            }
            let main = entrypoint ?? modules.first?.name ?? "worker.js"
            let mainModule = modules.first { $0.name == main }
            let moduleSyntax =
                !(mainModule?.contentType == "application/javascript" && !(mainModule?.text.contains("export ") ?? false))
            return WorkerContent(mainModule: main, modules: modules, moduleSyntax: moduleSyntax)
        }
        let name = entrypoint ?? "worker.js"
        let text = String(decoding: data, as: UTF8.self)
        let moduleSyntax = text.contains("export default") || text.contains("export {")
        return WorkerContent(
            mainModule: name,
            modules: [WorkerModule(name: name, contentType: Self.contentType(for: name, moduleSyntax: moduleSyntax), data: data)],
            moduleSyntax: moduleSyntax)
    }

    /// The multipart body of a script upload: `metadata` plus every module.
    public static func scriptForm(metadata: JSON, modules: [WorkerModule]) -> MultipartForm {
        var form = MultipartForm()
        form.addFile("metadata", filename: "metadata.json", contentType: "application/json", data: metadata.encoded())
        for m in modules {
            form.addFile(
                m.name, filename: m.name, contentType: m.contentType.isEmpty ? "application/octet-stream" : m.contentType,
                data: m.data)
        }
        return form
    }

    /// The metadata for replacing only the code (bindings and settings stay).
    public static func contentMetadata(_ content: WorkerContent) -> JSON {
        content.moduleSyntax ? ["main_module": .string(content.mainModule)] : ["body_part": .string(content.mainModule)]
    }

    public static func settingsForm(_ settings: JSON) -> MultipartForm {
        var form = MultipartForm()
        form.addFile("settings", filename: "settings.json", contentType: "application/json", data: settings.encoded())
        return form
    }

    /// A full bindings list for a settings PATCH: every existing binding is
    /// kept (secrets as `inherit`, since their values can't be read), with
    /// [replace] swapped in (or added) and [remove] left out.
    public static func rebuildBindings(_ settings: JSON, replace: JSON? = nil, remove: String? = nil) -> [JSON] {
        var out: [JSON] = []
        var replaced = false
        for b in settings["bindings"].items {
            let name = b["name"].string
            if let remove, name == remove { continue }
            if let replace, name == replace["name"].string {
                out.append(replace)
                replaced = true
                continue
            }
            let type = b["type"].string
            if type == "secret_text" || type == "secret_key" {
                out.append(["name": .string(name ?? ""), "type": "inherit"])
            } else {
                out.append(b)
            }
        }
        if let replace, !replaced { out.append(replace) }
        return out
    }

    /// What a binding points at, for display.
    public static func bindingTarget(_ b: JSON) -> String {
        for k in [
            "namespace_id", "bucket_name", "id", "database_id", "service", "queue_name", "index_name", "class_name",
            "dataset", "certificate_id", "store_id", "workflow_name", "namespace",
        ] where !b[k].isNull {
            return b[k].text ?? ""
        }
        if b["type"].string == "plain_text" { return b["text"].text ?? "" }
        if b["type"].string == "json" { return b["json"].compactString }
        return ""
    }

    public static func bindingLabel(_ type: String) -> String {
        switch type {
        case "plain_text": return L("Variable", "变量")
        case "json": return L("JSON variable", "JSON 变量")
        case "secret_text": return L("Secret", "密钥")
        case "kv_namespace": return L("KV namespace", "KV 命名空间")
        case "r2_bucket": return L("R2 bucket", "R2 存储桶")
        case "d1": return L("D1 database", "D1 数据库")
        case "durable_object_namespace": return "Durable Object"
        case "service": return L("Service", "服务绑定")
        case "queue": return L("Queue", "队列")
        case "ai": return "Workers AI"
        case "vectorize": return "Vectorize"
        case "hyperdrive": return "Hyperdrive"
        case "analytics_engine": return "Analytics Engine"
        case "browser": return L("Browser Rendering", "浏览器渲染")
        case "version_metadata": return L("Version metadata", "版本元数据")
        case "assets": return L("Static assets", "静态资源")
        case "secrets_store_secret": return "Secrets Store"
        case "workflow": return L("Workflow", "工作流")
        case "dispatch_namespace": return L("Dispatch namespace", "分发命名空间")
        case "mtls_certificate": return L("mTLS certificate", "mTLS 证书")
        default: return type
        }
    }

    /// Starter code for new Workers, in display order.
    public static let templates: [(name: String, code: String)] = [
        (
            "Hello World",
            """
            export default {
              async fetch(request, env, ctx) {
                return new Response("Hello from Cirrus!", {
                  headers: { "content-type": "text/plain; charset=utf-8" },
                });
              },
            };

            """
        ),
        (
            "JSON API router",
            """
            export default {
              async fetch(request, env, ctx) {
                const url = new URL(request.url);
                switch (`${request.method} ${url.pathname}`) {
                  case "GET /":
                    return Response.json({ ok: true, time: new Date().toISOString() });
                  case "GET /headers":
                    return Response.json(Object.fromEntries(request.headers));
                  case "POST /echo":
                    return Response.json(await request.json());
                  default:
                    return Response.json({ error: "Not found" }, { status: 404 });
                }
              },
            };

            """
        ),
        (
            "Redirect",
            """
            const REDIRECTS = new Map([
              ["/old", "https://example.com/new"],
            ]);

            export default {
              async fetch(request) {
                const url = new URL(request.url);
                const target = REDIRECTS.get(url.pathname);
                if (target) return Response.redirect(target, 301);
                return fetch(request);
              },
            };

            """
        ),
        (
            "Reverse proxy with cache",
            """
            const ORIGIN = "https://example.com";

            export default {
              async fetch(request, env, ctx) {
                const url = new URL(request.url);
                const upstream = new URL(url.pathname + url.search, ORIGIN);
                const response = await fetch(upstream, {
                  method: request.method,
                  headers: request.headers,
                  body: request.body,
                  cf: { cacheTtl: 300, cacheEverything: true },
                });
                const res = new Response(response.body, response);
                res.headers.set("x-proxied-by", "cirrus-worker");
                return res;
              },
            };

            """
        ),
        (
            "Cron job",
            """
            export default {
              async fetch() {
                return new Response("This Worker runs on a schedule.");
              },
              async scheduled(controller, env, ctx) {
                console.log("Cron fired at", new Date(controller.scheduledTime).toISOString(), controller.cron);
              },
            };

            """
        ),
    ]

    // MARK: Metrics

    static let scriptMetricsQuery = """
        query WorkerMetrics($accountTag: string, $script: string, $since: Time, $until: Time) {
          viewer {
            accounts(filter: { accountTag: $accountTag }) {
              workersInvocationsAdaptive(limit: 500, filter: { scriptName: $script, datetime_geq: $since, datetime_leq: $until }, orderBy: [datetimeHour_ASC]) {
                sum { requests errors subrequests }
                quantiles { cpuTimeP50 cpuTimeP99 }
                dimensions { datetimeHour }
              }
            }
          }
        }
        """

    static let accountMetricsQuery = """
        query WorkersSummary($accountTag: string, $since: Time, $until: Time) {
          viewer {
            accounts(filter: { accountTag: $accountTag }) {
              workersInvocationsAdaptive(limit: 2000, filter: { datetime_geq: $since, datetime_leq: $until }) {
                sum { requests errors }
                dimensions { scriptName }
              }
            }
          }
        }
        """

    /// Hourly points from a `WorkerMetrics` result (rows of one hour merged).
    public static func parseMetrics(_ data: JSON) -> [WorkerMetricsPoint] {
        var byHour: [String: [Double]] = [:]
        for r in data["viewer"]["accounts"][0]["workersInvocationsAdaptive"].items {
            let h = r["dimensions"]["datetimeHour"].text ?? ""
            let s = r["sum"]
            let q = r["quantiles"]
            let cur = byHour[h] ?? [0, 0, 0, 0, 0]
            byHour[h] = [
                cur[0] + (s["requests"].double ?? 0), cur[1] + (s["errors"].double ?? 0),
                cur[2] + (s["subrequests"].double ?? 0), max(cur[3], q["cpuTimeP50"].double ?? 0),
                max(cur[4], q["cpuTimeP99"].double ?? 0),
            ]
        }
        return byHour.keys.sorted().map { k in
            let v = byHour[k]!
            return WorkerMetricsPoint(
                at: ISODate.parse(k) ?? Date(timeIntervalSince1970: 0), requests: v[0], errors: v[1], subrequests: v[2],
                cpuP50: v[3], cpuP99: v[4])
        }
    }

    /// Requests and errors per script from a `WorkersSummary` result.
    public static func parseSummary(_ data: JSON) -> [String: (requests: Double, errors: Double)] {
        var out: [String: (requests: Double, errors: Double)] = [:]
        for r in data["viewer"]["accounts"][0]["workersInvocationsAdaptive"].items {
            let name = r["dimensions"]["scriptName"].text ?? ""
            let cur = out[name] ?? (0, 0)
            out[name] = (cur.requests + (r["sum"]["requests"].double ?? 0), cur.errors + (r["sum"]["errors"].double ?? 0))
        }
        return out
    }

    static func window(hours: Int, now: Date = Date()) -> (String, String) {
        (ISODate.format(now.addingTimeInterval(-Double(hours) * 3600)), ISODate.format(now))
    }
}

/// One event of a Worker's live tail, summarised for display.
public struct TailEvent: Identifiable, Sendable {
    public let id = UUID()
    public var raw: JSON
    public var outcome: String
    public var status: Int?
    /// `GET https://…` or `cron */5 * * * *`.
    public var title: String
    public var at: Date?
    /// `(level, message)` of each console log.
    public var logs: [(level: String, message: String)]
    public var exceptions: [String]

    public init(_ raw: JSON) {
        self.raw = raw
        outcome = raw["outcome"].string ?? ""
        let event = raw["event"]
        status = event["response"]["status"].int
        if let cron = event["cron"].string {
            title = "cron " + cron
        } else {
            title = [event["request"]["method"].string, event["request"]["url"].string].compactMap { $0 }
                .joined(separator: " ")
        }
        at = raw["eventTimestamp"].double.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        logs = raw["logs"].items.map { l in
            let m = l["message"]
            let text = m.array.map { $0.map { $0.text ?? "" }.joined(separator: " ") } ?? (m.text ?? "")
            return (l["level"].string ?? "log", text)
        }
        exceptions = raw["exceptions"].items.map { "\($0["name"].text ?? ""): \($0["message"].text ?? "")" }
    }

    /// Text to search when filtering.
    public var searchText: String {
        ([outcome, title] + logs.map { $0.message } + exceptions).joined(separator: " ").lowercased()
    }
}

public extension CFClient {
    func workerContent(_ accountId: String, _ script: String) async throws -> WorkerContent {
        let r = try await rawOK("GET", Workers.scriptPath(accountId, script) + "/content/v2")
        return Workers.parseContent(r.data, contentType: r.header("content-type"), entrypoint: r.header("cf-entrypoint"))
    }

    /// Replaces a Worker's code; bindings and settings are kept.
    func uploadWorkerContent(_ accountId: String, _ script: String, _ content: WorkerContent) async throws {
        let form = Workers.scriptForm(metadata: Workers.contentMetadata(content), modules: content.modules)
        try await send("PUT", Workers.scriptPath(accountId, script) + "/content", body: .multipart(form))
    }

    /// Creates (or fully replaces) a Worker from one ES module.
    func createWorker(_ accountId: String, _ script: String, code: String, compatibilityDate: String? = nil) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let metadata: JSON = [
            "main_module": "worker.js", "compatibility_date": .string(compatibilityDate ?? f.string(from: Date())),
            "bindings": [],
        ]
        let module = WorkerModule(name: "worker.js", contentType: "application/javascript+module", data: Data(code.utf8))
        try await send(
            "PUT", Workers.scriptPath(accountId, script), body: .multipart(Workers.scriptForm(metadata: metadata, modules: [module])))
    }

    /// Patches script settings (the multipart `settings` part).
    func patchWorkerSettings(_ accountId: String, _ script: String, _ settings: JSON) async throws {
        try await send("PATCH", Workers.scriptPath(accountId, script) + "/settings", body: .multipart(Workers.settingsForm(settings)))
    }

    func workerMetrics(_ accountId: String, _ script: String, hours: Int = 24) async throws -> [WorkerMetricsPoint] {
        let (since, until) = Workers.window(hours: hours)
        let data = try await graphql(
            Workers.scriptMetricsQuery,
            variables: ["accountTag": .string(accountId), "script": .string(script), "since": .string(since), "until": .string(until)])
        return Workers.parseMetrics(data)
    }

    func workersSummary(_ accountId: String) async throws -> [String: (requests: Double, errors: Double)] {
        let (since, until) = Workers.window(hours: 24)
        let data = try await graphql(
            Workers.accountMetricsQuery,
            variables: ["accountTag": .string(accountId), "since": .string(since), "until": .string(until)])
        return Workers.parseSummary(data)
    }
}

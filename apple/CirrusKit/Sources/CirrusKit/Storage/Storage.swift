import Foundation

/// Workers KV.
public enum KV {
    public static func namespaces(_ accountId: String) -> String {
        "/accounts/\(accountId.pathEncoded)/storage/kv/namespaces"
    }

    public static func namespace(_ accountId: String, _ id: String) -> String {
        namespaces(accountId) + "/" + id.pathEncoded
    }

    /// Whether a value looks like UTF-8 text (no NUL bytes in its start, decodable).
    public static func looksText(_ data: Data) -> Bool {
        let head = data.prefix(2048)
        if head.contains(0) { return false }
        // A multi-byte character may be cut at the end of the sample: allow up to 3 trailing bytes.
        for cut in 0...min(3, head.count) {
            if String(data: head.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }
}

/// R2 buckets and objects (through the Cloudflare API, not S3).
public enum R2 {
    public static func buckets(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/r2/buckets" }

    public static func bucket(_ accountId: String, _ name: String) -> String { buckets(accountId) + "/" + name.pathEncoded }

    public static func object(_ accountId: String, _ bucket: String, _ key: String) -> String {
        self.bucket(accountId, bucket) + "/objects/" + key.pathEncoded
    }

    /// One page of a bucket listing.
    public struct Listing: Sendable {
        public var objects: [JSON]
        /// Common prefixes ("folders") under the listed prefix.
        public var folders: [String]
        /// Set when more objects follow.
        public var cursor: String?
    }

    /// Reads a `GET …/objects?delimiter=/` response.
    public static func parseListing(_ res: CFResponse, prefix: String) -> Listing {
        let objects = (res.result.array ?? res.result["objects"].items).filter { $0["key"].string != prefix }
        let info = res.resultInfo ?? .null
        let delimited = info["delimited"].array ?? res.result["delimited"].items
        let truncated = info["is_truncated"].isTrue || info["is_truncated"].string == "true"
        let cursor = info["cursor"].string
        return Listing(
            objects: objects, folders: delimited.compactMap(\.text),
            cursor: truncated && !(cursor ?? "").isEmpty ? cursor : nil)
    }

    /// The buckets of a `GET /r2/buckets` result.
    public static func parseBuckets(_ result: JSON) -> [JSON] { result.array ?? result["buckets"].items }

    public static let locations: [(code: String, name: String)] = [
        ("apac", "Asia-Pacific (APAC)"), ("enam", "Eastern North America (ENAM)"),
        ("wnam", "Western North America (WNAM)"), ("weur", "Western Europe (WEUR)"),
        ("eeur", "Eastern Europe (EEUR)"), ("oc", "Oceania (OC)"),
    ]

    public static func mimeType(for name: String) -> String {
        let n = name.lowercased()
        let map: [(String, String)] = [
            (".html", "text/html"), (".htm", "text/html"), (".css", "text/css"), (".js", "application/javascript"),
            (".mjs", "application/javascript"), (".json", "application/json"), (".txt", "text/plain"),
            (".md", "text/markdown"), (".csv", "text/csv"), (".xml", "application/xml"), (".yaml", "application/yaml"),
            (".yml", "application/yaml"), (".png", "image/png"), (".jpg", "image/jpeg"), (".jpeg", "image/jpeg"),
            (".gif", "image/gif"), (".webp", "image/webp"), (".svg", "image/svg+xml"), (".avif", "image/avif"),
            (".ico", "image/x-icon"), (".pdf", "application/pdf"), (".zip", "application/zip"), (".mp4", "video/mp4"),
            (".webm", "video/webm"), (".mp3", "audio/mpeg"), (".wasm", "application/wasm"),
        ]
        return map.first { n.hasSuffix($0.0) }?.1 ?? "application/octet-stream"
    }

    /// An SF Symbol for a file name.
    public static func symbol(for key: String) -> String {
        let ext = (key.lowercased().split(separator: ".").last).map(String.init) ?? ""
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico": return "photo"
        case "mp4", "mov", "webm", "mkv": return "film"
        case "mp3", "wav", "flac", "ogg": return "waveform"
        case "zip", "gz", "tar", "7z", "rar", "zst": return "archivebox"
        case "js", "ts", "json", "html", "css", "xml", "yaml", "yml", "md", "txt", "csv": return "doc.text"
        default: return "doc"
        }
    }

    /// Whether the app can preview an object of this type.
    public static func previewKind(contentType: String) -> PreviewKind? {
        if contentType.hasPrefix("image/") && !contentType.contains("svg") { return .image }
        if contentType.hasPrefix("text/") || ["json", "javascript", "xml", "yaml", "svg"].contains(where: contentType.contains) {
            return .text
        }
        return nil
    }

    public enum PreviewKind: Sendable { case image, text }
}

/// D1 databases.
public enum D1 {
    public static func databases(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/d1/database" }

    public static func database(_ accountId: String, _ id: String) -> String { databases(accountId) + "/" + id.pathEncoded }

    /// The result of one statement.
    public struct Result: Sendable, Identifiable {
        public let id = UUID()
        public var columns: [String]
        public var rows: [[JSON]]
        public var meta: JSON

        /// `3 rows · 0.42 ms · read 10 · written 0`.
        public var summary: String {
            var parts = [L("\(rows.count) rows", "\(rows.count) 行")]
            if let d = meta["duration"].double { parts.append(String(format: "%.2f ms", d)) }
            if let r = meta["rows_read"].int { parts.append("read \(r)") }
            if let w = meta["rows_written"].int { parts.append("written \(w)") }
            if let c = meta["changes"].int { parts.append("changes \(c)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Reads a `POST …/raw` result (one entry per statement).
    public static func parseRaw(_ result: JSON) -> [Result] {
        let list = result.array ?? [result]
        return list.filter { $0.object != nil }.map { s in
            Result(
                columns: s["results"]["columns"].items.map { $0.text ?? "" },
                rows: s["results"]["rows"].items.map { $0.array ?? [] },
                meta: s["meta"])
        }
    }

    public static func isDestructive(_ sql: String) -> Bool {
        sql.range(of: #"\b(drop|delete|truncate|alter)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func changesSchema(_ sql: String) -> Bool {
        sql.range(of: #"\b(create|drop|alter)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A quoted SQL identifier.
    public static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    public static let tablesQuery =
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY name;"

    /// A cell as text (`NULL` for null).
    public static func cell(_ v: JSON) -> String {
        switch v {
        case .null: return "NULL"
        case .array, .object: return v.compactString
        default: return v.text ?? ""
        }
    }
}

/// Workers AI.
public enum WorkersAI {
    public static func models(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/ai/models/search" }

    public static func run(_ accountId: String, _ model: String) -> String {
        // Model names contain slashes (`@cf/meta/llama-…`), which the API expects as is.
        "/accounts/\(accountId.pathEncoded)/ai/run/\(model)"
    }

    public static func task(_ model: JSON) -> String { model["task"]["name"].string ?? "" }

    /// The text of a chat completion (Workers AI or OpenAI-style), else the JSON.
    public static func reply(_ result: JSON) -> String {
        if let r = result["response"].string { return r }
        if let c = result["choices"][0]["message"]["content"].string { return c }
        if case .string(let s) = result { return s }
        return result.prettyString
    }

    /// The image of a text-to-image run: the raw bytes, or base64 in `result.image`.
    public static func image(data: Data, contentType: String?) throws -> Data? {
        if (contentType ?? "").hasPrefix("image/") { return data }
        let body = try JSON.parse(data)
        if body["success"].bool == false {
            throw CFAPIError(method: "POST", path: "/ai/run", statusCode: nil, errors: body["errors"].items.map(CFMessage.init(json:)))
        }
        return body["result"]["image"].string.flatMap { Data(base64Encoded: $0) }
    }

    /// A sample input for running a model of [task].
    public static func example(task: String) -> JSON {
        switch task {
        case "Text Generation": return ["messages": [["role": "user", "content": "Hello!"]]]
        case "Text Embeddings": return ["text": ["Cirrus is fast"]]
        case "Translation": return ["text": "Hello world", "source_lang": "english", "target_lang": "chinese"]
        case "Summarization": return ["input_text": "Long text to summarize…", "max_length": 128]
        case "Text Classification": return ["text": "I love this product!"]
        default: return ["prompt": "Hello"]
        }
    }
}

/// Pages projects.
public enum Pages {
    public static func projects(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/pages/projects" }

    public static func project(_ accountId: String, _ name: String) -> String { projects(accountId) + "/" + name.pathEncoded }

    /// A browsable URL (Pages returns some without a scheme).
    public static func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("http") ? s : "https://" + s)
    }
}

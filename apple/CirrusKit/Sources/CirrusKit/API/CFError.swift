import Foundation

/// One entry of the `errors` / `messages` arrays of a Cloudflare API envelope.
public struct CFMessage: Hashable, Sendable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var chain: [CFMessage]

    public init(code: Int, message: String, chain: [CFMessage] = []) {
        self.code = code
        self.message = message
        self.chain = chain
    }

    public init(json: JSON) {
        if case .object = json {
            code = json["code"].int ?? 0
            message = json["message"].string ?? json["msg"].string ?? json.compactString
            chain = json["error_chain"].items.map(CFMessage.init(json:))
        } else {
            code = 0
            message = json.text ?? ""
            chain = []
        }
    }

    public var description: String {
        let base = code == 0 ? message : "\(message) (\(code))"
        if chain.isEmpty { return base }
        return "\(base): " + chain.map(\.description).joined(separator: "; ")
    }
}

/// Thrown for any failed call to the Cloudflare API.
public struct CFAPIError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var method: String
    public var path: String
    /// Nil for transport errors (no response).
    public var statusCode: Int?
    public var errors: [CFMessage]
    /// The response body when it could not be read as an envelope.
    public var body: String?
    /// The underlying transport or token error.
    public var cause: String?

    public init(
        method: String, path: String, statusCode: Int? = nil, errors: [CFMessage] = [], body: String? = nil,
        cause: String? = nil
    ) {
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.errors = errors
        self.body = body
        self.cause = cause
    }

    public var isAuthError: Bool { statusCode == 401 || errors.contains { $0.code == 10000 || $0.code == 9109 } }
    public var isForbidden: Bool { statusCode == 403 }
    public var isNotFound: Bool { statusCode == 404 }
    public var isRateLimited: Bool { statusCode == 429 }
    public var isNetworkError: Bool { statusCode == nil && cause != nil }

    /// What went wrong, for display.
    public var summary: String {
        if !errors.isEmpty { return errors.map(\.description).joined(separator: "\n") }
        if let cause { return cause }
        if let body, !body.isEmpty { return body.count > 400 ? String(body.prefix(400)) + "…" : body }
        return "HTTP \(statusCode.map(String.init) ?? "-")"
    }

    public var description: String { "\(method) \(path) → \(statusCode.map(String.init) ?? "network error"): \(summary)" }
    public var errorDescription: String? { summary }
}

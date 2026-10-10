import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import CirrusKit

/// Answers requests of a test `URLSession` with a handler, and records them.
final class MockServer: @unchecked Sendable {
    struct Request {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data

        var path: String { url.path }
        var query: [String: String] {
            var out: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                out[item.name] = item.value ?? ""
            }
            return out
        }
        var json: JSON { (try? JSON.parse(body)) ?? .null }
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data

        static func json(_ j: JSON, status: Int = 200, headers: [String: String] = [:]) -> Response {
            var h = ["Content-Type": "application/json"]
            for (k, v) in headers { h[k] = v }
            return Response(status: status, headers: h, body: j.encoded())
        }

        /// A successful Cloudflare envelope.
        static func ok(_ result: JSON, info: JSON? = nil) -> Response {
            var o: [String: JSON] = ["success": true, "errors": [], "messages": [], "result": result]
            if let info { o["result_info"] = info }
            return .json(.object(o))
        }

        static func error(_ status: Int, code: Int, message: String) -> Response {
            .json(["success": false, "errors": [["code": .int(code), "message": .string(message)]], "messages": [],
                   "result": nil], status: status)
        }
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var handler: (Request) -> Response
    /// Requests to this host come here (each server gets its own).
    let host: String

    init(host: String = UUID().uuidString.lowercased() + ".test", _ handler: @escaping (Request) -> Response) {
        self.host = host
        self.handler = handler
        MockURLProtocol.register(host, self)
    }

    /// The API base URL served by this server.
    var baseURL: URL { URL(string: "https://\(host)/client/v4")! }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func handle(_ r: Request) -> Response {
        lock.lock()
        _requests.append(r)
        let h = handler
        lock.unlock()
        return h(r)
    }

    /// A session whose requests mock servers answer (by host).
    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MockServer] = [:]

    static func register(_ id: String, _ server: MockServer) {
        lock.lock()
        servers[id] = server
        lock.unlock()
    }

    static func server(_ id: String?) -> MockServer? {
        lock.lock()
        defer { lock.unlock() }
        return id.flatMap { servers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        guard let server = MockURLProtocol.server(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let r = server.handle(
            MockServer.Request(
                method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: body))
        let res = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

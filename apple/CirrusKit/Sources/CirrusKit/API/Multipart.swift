import Foundation

/// A `multipart/form-data` body (RFC 7578).
public struct MultipartForm: Sendable {
    public struct Part: Sendable {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data

        public init(name: String, filename: String? = nil, contentType: String? = nil, data: Data) {
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    public var parts: [Part]
    public let boundary: String

    public init(parts: [Part] = [], boundary: String = "cirrus-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) {
        self.parts = parts
        self.boundary = boundary
    }

    public mutating func add(_ name: String, _ value: String) {
        parts.append(Part(name: name, data: Data(value.utf8)))
    }

    public mutating func addFile(_ name: String, filename: String, contentType: String? = nil, data: Data) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public var body: Data {
        var out = Data()
        func line(_ s: String) { out.append(Data((s + "\r\n").utf8)) }
        for p in parts {
            line("--\(boundary)")
            var disposition = "Content-Disposition: form-data; name=\"\(Self.quote(p.name))\""
            if let f = p.filename { disposition += "; filename=\"\(Self.quote(f))\"" }
            line(disposition)
            if let ct = p.contentType ?? (p.filename != nil ? "application/octet-stream" : nil) {
                line("Content-Type: \(ct)")
            }
            line("")
            out.append(p.data)
            line("")
        }
        line("--\(boundary)--")
        return out
    }

    private static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// One part of a received multipart body.
public struct ReceivedPart: Sendable {
    /// Lower-cased header names.
    public var headers: [String: String]
    public var data: Data

    public var contentType: String? { headers["content-type"] }
    public var name: String? { dispositionParam("name") }
    public var filename: String? { dispositionParam("filename") }
    public var text: String { String(decoding: data, as: UTF8.self) }

    private func dispositionParam(_ key: String) -> String? {
        guard let d = headers["content-disposition"] else { return nil }
        for raw in d.split(separator: ";") {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix(key + "=") else { continue }
            var v = String(piece.dropFirst(key.count + 1))
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            return v
        }
        return nil
    }
}

/// The boundary from a `Content-Type` header value.
public func multipartBoundary(_ contentType: String?) -> String? {
    guard let ct = contentType, let r = ct.range(of: "boundary=", options: .caseInsensitive) else { return nil }
    var b = ct[r.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
    if b.hasPrefix("\""), b.hasSuffix("\""), b.count >= 2 { b = String(b.dropFirst().dropLast()) }
    return b.isEmpty ? nil : b
}

/// Splits a multipart body (enough for Workers script downloads).
public func parseMultipart(_ body: Data, boundary: String) -> [ReceivedPart] {
    let bytes = [UInt8](body)
    let delimiter = [UInt8](("--" + boundary).utf8)
    func indexOf(_ pattern: [UInt8], from start: Int) -> Int? {
        let n = bytes.count
        let m = pattern.count
        guard m > 0, m <= n else { return nil }
        var i = start
        outer: while i <= n - m {
            if bytes[i] == pattern[0] {
                var j = 1
                while j < m {
                    if bytes[i + j] != pattern[j] {
                        i += 1
                        continue outer
                    }
                    j += 1
                }
                return i
            }
            i += 1
        }
        return nil
    }
    var parts: [ReceivedPart] = []
    var pos = indexOf(delimiter, from: 0)
    while let p = pos {
        var start = p + delimiter.count
        // "--" after the delimiter ends the body.
        if start + 1 < bytes.count, bytes[start] == 45, bytes[start + 1] == 45 { break }
        if start < bytes.count, bytes[start] == 13 { start += 1 }
        if start < bytes.count, bytes[start] == 10 { start += 1 }
        guard let next = indexOf(delimiter, from: start) else { break }
        var end = next
        if end > start, bytes[end - 1] == 10 { end -= 1 }
        if end > start, bytes[end - 1] == 13 { end -= 1 }
        let chunk = Array(bytes[start..<end])
        // Headers end at the first blank line.
        var split: Int?
        var sepLen = 4
        var i = 0
        while i + 3 < chunk.count {
            if chunk[i] == 13, chunk[i + 1] == 10, chunk[i + 2] == 13, chunk[i + 3] == 10 {
                split = i
                break
            }
            i += 1
        }
        if split == nil {
            i = 0
            while i + 1 < chunk.count {
                if chunk[i] == 10, chunk[i + 1] == 10 {
                    split = i
                    sepLen = 2
                    break
                }
                i += 1
            }
        }
        var headers: [String: String] = [:]
        let content: [UInt8]
        if let s = split {
            let headerText = String(decoding: chunk[0..<s], as: UTF8.self)
            for line in headerText.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            content = Array(chunk[(s + sepLen)...])
        } else {
            content = chunk
        }
        parts.append(ReceivedPart(headers: headers, data: Data(content)))
        pos = next
    }
    return parts
}

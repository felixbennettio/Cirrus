import Foundation

/// A JSON reader straight into `JSON` values. Much faster than decoding
/// `JSON` through `JSONDecoder` (which tries each type in turn), which
/// matters for the multi-megabyte API catalog.
struct JSONParser {
    struct Failure: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "Invalid JSON at byte \(offset): \(reason)" }
    }

    static func parse(_ data: Data) throws -> JSON {
        try data.withUnsafeBytes { raw -> JSON in
            var p = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            p.skipSpace()
            let v = try p.value(depth: 0)
            p.skipSpace()
            if p.i != p.bytes.count { throw p.fail("unexpected data after the value") }
            return v
        }
    }

    let bytes: UnsafeBufferPointer<UInt8>
    var i = 0

    func fail(_ reason: String) -> Failure { Failure(offset: i, reason: reason) }

    mutating func skipSpace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x0A, 0x0D, 0x09: i += 1
            default: return
            }
        }
    }

    mutating func value(depth: Int) throws -> JSON {
        guard depth < 512 else { throw fail("nested too deeply") }
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    mutating func literal(_ word: StaticString) throws {
        let n = word.utf8CodeUnitCount
        guard i + n <= bytes.count else { throw fail("unexpected end") }
        let w = word.utf8Start
        for k in 0..<n where bytes[i + k] != w[k] { throw fail("invalid literal") }
        i += n
    }

    mutating func object(depth: Int) throws -> JSON {
        i += 1
        var out: [String: JSON] = [:]
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return .object(out)
        }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try string()
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            i += 1
            skipSpace()
            out[key] = try value(depth: depth + 1)
            skipSpace()
            guard i < bytes.count else { throw fail("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(out)
            }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func array(depth: Int) throws -> JSON {
        i += 1
        var out: [JSON] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return .array(out)
        }
        while true {
            skipSpace()
            out.append(try value(depth: depth + 1))
            skipSpace()
            guard i < bytes.count else { throw fail("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(out)
            }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func string() throws -> String {
        i += 1
        let start = i
        // Fast path: no escapes.
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            if c < 0x20 { throw fail("control character in string") }
            i += 1
        }
        var buf = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<i]))
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: buf, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // A surrogate pair: 😀.
                        if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    let s = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    buf.append(contentsOf: Array(String(Character(s)).utf8))
                default:
                    throw fail("invalid escape")
                }
                continue
            }
            if c < 0x20 { throw fail("control character in string") }
            buf.append(c)
            i += 1
        }
        throw fail("unterminated string")
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw fail("short \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
            default: throw fail("invalid \\u escape")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func number() throws -> JSON {
        let start = i
        var isDouble = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) else {
            throw fail("unexpected character")
        }
        while i < bytes.count {
            let c = bytes[i]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) {
                i += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
                || c == UInt8(ascii: "+") || c == UInt8(ascii: "-")
            {
                isDouble = true
                i += 1
            } else {
                break
            }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        if !isDouble, let v = Int(text) { return .int(v) }
        guard let d = Double(text) else { throw fail("invalid number") }
        return .double(d)
    }
}

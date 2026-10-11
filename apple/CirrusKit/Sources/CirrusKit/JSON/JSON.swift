import Foundation

/// A decoded JSON value. Cloudflare's API returns many differently shaped
/// objects, so most of the app works with this dynamic type (like the Flutter
/// version's `Map<String, dynamic>`) and reads fields with subscripts:
/// `zone["plan"]["name"].string`.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

// MARK: - Reading

public extension JSON {
    /// The member [key] of an object, or `.null` (so lookups can be chained).
    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// The element at [index] of an array, or `.null`.
    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Whole numbers, also from integral doubles and numeric strings.
    var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e18: return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Any number, also from numeric strings.
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Elements of an array (empty for anything else).
    var items: [JSON] { array ?? [] }

    /// Strings of an array of strings (other elements are skipped).
    var strings: [String] { items.compactMap(\.string) }

    /// `true` only for the JSON value `true`.
    var isTrue: Bool { bool == true }

    /// A short text for display: strings as they are, numbers and booleans
    /// formatted, `nil` for null, compact JSON for arrays and objects.
    var text: String? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return JSON.format(d)
        case .string(let s): return s
        case .array, .object: return compactString
        }
    }

    /// [text], or [fallback] for null and empty strings.
    func text(or fallback: String = "—") -> String {
        guard let t = text, !t.isEmpty else { return fallback }
        return t
    }

    internal static func format(_ d: Double) -> String {
        if d.isFinite, d.rounded() == d, abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
}

// MARK: - Building

public extension JSON {
    /// Returns a copy of this object with [key] set to [value].
    func setting(_ key: String, to value: JSON) -> JSON {
        var o = object ?? [:]
        o[key] = value
        return .object(o)
    }

    /// Returns a copy of this object with the members of [other] added.
    func merging(_ other: [String: JSON]) -> JSON {
        var o = object ?? [:]
        for (k, v) in other { o[k] = v }
        return .object(o)
    }

    /// Wraps a JSON-compatible Swift value: `nil`, `Bool`, `Int`, `Double`,
    /// strings, arrays and dictionaries of those. Not for `JSONSerialization`
    /// output, whose `NSNumber`s would all read as booleans; use [parse].
    init(any value: Any?) {
        switch value {
        case nil: self = .null
        case let v as JSON: self = v
        case is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let a as [Any?]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any?]: self = .object(o.mapValues { JSON(any: $0) })
        default: self = .string(String(describing: value!))
        }
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}

// MARK: - Coding

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSON].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSON {
    /// Parses JSON text. Throws for invalid input.
    static func parse(_ data: Data) throws -> JSON {
        try JSONParser.parse(data)
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// Compact JSON text.
    func encoded() -> Data {
        (try? JSONEncoder.compact.encode(self)) ?? Data("null".utf8)
    }

    var compactString: String { String(decoding: encoded(), as: UTF8.self) }

    /// Indented JSON with sorted keys, for display and editing.
    var prettyString: String {
        let data = (try? JSONEncoder.pretty.encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static let compact: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

// MARK: - Paths

public extension JSON {
    /// Reads a nested value with a dotted path (`a.b.0.c`).
    func pick(_ path: String) -> JSON {
        var cur = self
        for part in path.split(separator: ".") {
            switch cur {
            case .object(let o): cur = o[String(part)] ?? .null
            case .array(let a):
                guard let i = Int(part), a.indices.contains(i) else { return .null }
                cur = a[i]
            default: return .null
            }
        }
        return cur
    }
}

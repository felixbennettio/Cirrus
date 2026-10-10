import Foundation

/// DNS record types and the form behind the record editor.
public enum DNSCatalog {
    /// Every record type the API supports.
    public static let types = [
        "A", "AAAA", "CNAME", "MX", "TXT", "NS", "SRV", "CAA", "HTTPS", "SVCB", "PTR", "TLSA", "SSHFP", "URI", "LOC",
        "CERT", "DS", "DNSKEY", "NAPTR", "SMIMEA", "OPENPGPKEY",
    ]

    /// Types that can be proxied through Cloudflare.
    public static let proxiable: Set<String> = ["A", "AAAA", "CNAME"]

    /// Standard TTLs (1 = automatic).
    public static let ttls = [1, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18000, 43200, 86400]

    /// A field of a type with structured `data`.
    public struct Field: Sendable {
        public let key: String
        public let label: LocalizedText
        public let numeric: Bool
        public let options: [String]?
        public let hint: String?

        init(_ key: String, _ en: String, _ zh: String, numeric: Bool = false, options: [String]? = nil,
             hint: String? = nil) {
            self.key = key
            label = LocalizedText(en, zh)
            self.numeric = numeric
            self.options = options
            self.hint = hint
        }
    }

    /// Types edited field by field (their record carries `data`).
    public static let dataFields: [String: [Field]] = [
        "CAA": [
            Field("flags", "Flags", "标志", numeric: true, hint: "0"),
            Field("tag", "Tag", "标签", options: ["issue", "issuewild", "iodef"]),
            Field("value", "CA domain / URL", "CA 域名 / URL", hint: "letsencrypt.org"),
        ],
        "SRV": [
            Field("priority", "Priority", "优先级", numeric: true, hint: "10"),
            Field("weight", "Weight", "权重", numeric: true, hint: "5"),
            Field("port", "Port", "端口", numeric: true, hint: "443"),
            Field("target", "Target", "目标", hint: "service.example.com"),
        ],
        "HTTPS": [
            Field("priority", "Priority", "优先级", numeric: true, hint: "1"),
            Field("target", "Target", "目标", hint: "."),
            Field("value", "Value", "值", hint: "alpn=\"h3,h2\" ipv4hint=\"203.0.113.1\""),
        ],
        "SVCB": [
            Field("priority", "Priority", "优先级", numeric: true, hint: "1"),
            Field("target", "Target", "目标", hint: "."),
            Field("value", "Value", "值", hint: "alpn=\"h2\""),
        ],
        "TLSA": [
            Field("usage", "Usage", "用途", numeric: true, hint: "3"),
            Field("selector", "Selector", "选择器", numeric: true, hint: "1"),
            Field("matching_type", "Matching type", "匹配类型", numeric: true, hint: "1"),
            Field("certificate", "Certificate", "证书", hint: "hex digest"),
        ],
        "SMIMEA": [
            Field("usage", "Usage", "用途", numeric: true),
            Field("selector", "Selector", "选择器", numeric: true),
            Field("matching_type", "Matching type", "匹配类型", numeric: true),
            Field("certificate", "Certificate", "证书"),
        ],
        "SSHFP": [
            Field("algorithm", "Algorithm", "算法", numeric: true, hint: "4"),
            Field("type", "Fingerprint type", "指纹类型", numeric: true, hint: "2"),
            Field("fingerprint", "Fingerprint", "指纹"),
        ],
        "DS": [
            Field("key_tag", "Key tag", "密钥标签", numeric: true),
            Field("algorithm", "Algorithm", "算法", numeric: true),
            Field("digest_type", "Digest type", "摘要类型", numeric: true),
            Field("digest", "Digest", "摘要"),
        ],
        "DNSKEY": [
            Field("flags", "Flags", "标志", numeric: true, hint: "257"),
            Field("protocol", "Protocol", "协议", numeric: true, hint: "3"),
            Field("algorithm", "Algorithm", "算法", numeric: true, hint: "13"),
            Field("public_key", "Public key", "公钥"),
        ],
        "CERT": [
            Field("type", "Cert type", "证书类型", numeric: true),
            Field("key_tag", "Key tag", "密钥标签", numeric: true),
            Field("algorithm", "Algorithm", "算法", numeric: true),
            Field("certificate", "Certificate", "证书"),
        ],
        "NAPTR": [
            Field("order", "Order", "顺序", numeric: true),
            Field("preference", "Preference", "偏好", numeric: true),
            Field("flags", "Flags", "标志", hint: "U"),
            Field("service", "Service", "服务", hint: "E2U+sip"),
            Field("regex", "Regex", "正则"),
            Field("replacement", "Replacement", "替换", hint: "."),
        ],
        "URI": [
            Field("weight", "Weight", "权重", numeric: true, hint: "1"),
            Field("target", "Target URI", "目标 URI", hint: "https://example.com"),
        ],
        "LOC": [
            Field("lat_degrees", "Latitude °", "纬度 °", numeric: true),
            Field("lat_minutes", "Latitude ′", "纬度 ′", numeric: true),
            Field("lat_seconds", "Latitude ″", "纬度 ″", numeric: true),
            Field("lat_direction", "N/S", "南/北", options: ["N", "S"]),
            Field("long_degrees", "Longitude °", "经度 °", numeric: true),
            Field("long_minutes", "Longitude ′", "经度 ′", numeric: true),
            Field("long_seconds", "Longitude ″", "经度 ″", numeric: true),
            Field("long_direction", "E/W", "东/西", options: ["E", "W"]),
            Field("altitude", "Altitude (m)", "海拔（米）", numeric: true),
            Field("size", "Size (m)", "大小（米）", numeric: true),
            Field("precision_horz", "Horizontal precision", "水平精度", numeric: true),
            Field("precision_vert", "Vertical precision", "垂直精度", numeric: true),
        ],
    ]

    /// MX and URI records carry a priority.
    public static func hasPriority(_ type: String) -> Bool { type == "MX" || type == "URI" }

    public static func contentHint(_ type: String) -> String? {
        switch type {
        case "A": return "203.0.113.10"
        case "AAAA": return "2001:db8::1"
        case "CNAME": return "target.example.net"
        case "MX": return "mail.example.com"
        case "TXT": return "v=spf1 include:_spf.example.com ~all"
        case "NS": return "ns1.example.net"
        case "PTR": return "host.example.com"
        case "OPENPGPKEY": return "base64 key"
        default: return nil
        }
    }

    public static func contentLabel(_ type: String) -> String {
        switch type {
        case "A": return L("IPv4 address", "IPv4 地址")
        case "AAAA": return L("IPv6 address", "IPv6 地址")
        case "CNAME": return L("Target", "目标")
        case "MX": return L("Mail server", "邮件服务器")
        case "NS": return L("Nameserver", "名称服务器")
        default: return L("Content", "内容")
        }
    }

    /// An error message for invalid content, or nil.
    public static func validate(type: String, content: String) -> String? {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return L("Required", "必填") }
        if type == "A" {
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            let ok = parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && Int(p).map { (0...255).contains($0) } == true }
            if !ok { return L("Must be an IPv4 address", "必须是 IPv4 地址") }
        }
        if type == "AAAA" && !t.contains(":") { return L("Must be an IPv6 address", "必须是 IPv6 地址") }
        return nil
    }

    /// A name relative to [zone]: `@` for the apex, `www` for `www.zone`.
    public static func relativeName(_ name: String, zone: String) -> String {
        if name == zone { return "@" }
        let suffix = "." + zone
        return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }
}

/// The state of the record editor, turned into a request body by [body].
public struct DNSRecordDraft: Sendable, Equatable {
    public var type: String
    /// Relative (`www`, `@`) or full name.
    public var name: String
    public var content: String
    public var priority: String
    public var comment: String
    /// Comma separated.
    public var tags: String
    public var proxied: Bool
    /// One of `DNSCatalog.ttls`, or -1 for [customTTL].
    public var ttl: Int
    public var customTTL: String
    /// Fields of structured types.
    public var data: [String: String]
    public var flattenCNAME: Bool

    public init(type: String = "A") {
        self.type = type
        name = ""
        content = ""
        priority = ""
        comment = ""
        tags = ""
        proxied = true
        ttl = 1
        customTTL = ""
        data = [:]
        flattenCNAME = false
    }

    /// The editor state for an existing record.
    public init(record r: JSON, zone: String) {
        type = r["type"].string ?? "A"
        name = DNSCatalog.relativeName(r["name"].string ?? "", zone: zone)
        content = r["content"].text ?? ""
        priority = r["priority"].text ?? ""
        comment = r["comment"].string ?? ""
        tags = r["tags"].strings.joined(separator: ", ")
        proxied = r["proxied"].bool ?? true
        let t = r["ttl"].int ?? 1
        ttl = DNSCatalog.ttls.contains(t) ? t : -1
        customTTL = DNSCatalog.ttls.contains(t) ? "" : String(t)
        var d: [String: String] = [:]
        for (k, v) in r["data"].object ?? [:] { d[k] = v.text ?? "" }
        data = d
        flattenCNAME = r["settings"]["flatten_cname"].isTrue
    }

    public var usesData: Bool { DNSCatalog.dataFields[type] != nil }
    public var isProxiable: Bool { DNSCatalog.proxiable.contains(type) }

    /// The `POST`/`PATCH` body for the record.
    public func body(zone: String) -> JSON {
        let n = name.trimmingCharacters(in: .whitespaces)
        var b: [String: JSON] = [
            "type": .string(type),
            "name": .string(n.isEmpty || n == "@" ? zone : n),
            "ttl": .int(ttl == -1 ? (Int(customTTL.trimmingCharacters(in: .whitespaces)) ?? 1) : ttl),
            "comment": .string(comment.trimmingCharacters(in: .whitespaces)),
            "tags": .array(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map(JSON.string)),
        ]
        if isProxiable { b["proxied"] = .bool(proxied) }
        if DNSCatalog.hasPriority(type) { b["priority"] = .int(Int(priority.trimmingCharacters(in: .whitespaces)) ?? 10) }
        if let fields = DNSCatalog.dataFields[type] {
            var d: [String: JSON] = [:]
            for f in fields {
                if let options = f.options {
                    let v = data[f.key].flatMap { $0.isEmpty ? nil : $0 } ?? options[0]
                    d[f.key] = .string(v)
                } else {
                    let t = (data[f.key] ?? "").trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { continue }
                    if f.numeric, let i = Int(t) {
                        d[f.key] = .int(i)
                    } else if f.numeric, let x = Double(t) {
                        d[f.key] = .double(x)
                    } else {
                        d[f.key] = .string(t)
                    }
                }
            }
            b["data"] = .object(d)
        } else {
            b["content"] = .string(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if type == "CNAME" { b["settings"] = ["flatten_cname": .bool(flattenCNAME)] }
        return .object(b)
    }
}

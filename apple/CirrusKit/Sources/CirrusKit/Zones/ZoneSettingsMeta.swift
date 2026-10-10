import Foundation

/// Groups of zone settings, in display order.
public enum SettingGroup: String, CaseIterable, Sendable {
    case ssl, speed, caching, network, security, scrape, other

    public var label: LocalizedText {
        switch self {
        case .ssl: return LocalizedText("SSL/TLS", "SSL/TLS")
        case .speed: return LocalizedText("Speed", "速度优化")
        case .caching: return LocalizedText("Caching", "缓存")
        case .network: return LocalizedText("Network", "网络")
        case .security: return LocalizedText("Security", "安全")
        case .scrape: return LocalizedText("Scrape Shield", "内容保护")
        case .other: return LocalizedText("Other", "其他")
        }
    }
}

/// What the app knows about a zone setting. Settings the API returns that
/// are not listed still show (under "Other") with a generic editor.
public struct SettingMeta: Sendable {
    public let group: SettingGroup
    public let label: LocalizedText
    public let description: LocalizedText?
    /// Allowed string values (for enums other than on/off).
    public let options: [String]?
    /// Suggested numeric values (seconds etc.).
    public let numberOptions: [Int]?

    init(_ group: SettingGroup, _ en: String, _ zh: String, description: LocalizedText? = nil,
         options: [String]? = nil, numberOptions: [Int]? = nil) {
        self.group = group
        label = LocalizedText(en, zh)
        self.description = description
        self.options = options
        self.numberOptions = numberOptions
    }
}

public enum ZoneSettingsCatalog {
    static let ttlOptions = [
        0, 30, 60, 120, 300, 1200, 1800, 3600, 7200, 10800, 14400, 18000, 28800, 43200, 57600, 72000, 86400, 172800,
        259200, 345600, 432000, 691200, 1382400, 2073600, 2678400, 5356800, 16070400, 31536000,
    ]

    /// Known settings in display order.
    public static let ordered: [(String, SettingMeta)] = [
        // SSL/TLS
        ("ssl", SettingMeta(.ssl, "Encryption mode", "加密模式",
                            description: LocalizedText("How Cloudflare connects to your origin.", "Cloudflare 连接源站的方式。"),
                            options: ["off", "flexible", "full", "strict"])),
        ("always_use_https", SettingMeta(.ssl, "Always Use HTTPS", "始终使用 HTTPS",
                                         description: LocalizedText("Redirect all HTTP requests to HTTPS.", "将所有 HTTP 请求重定向到 HTTPS。"))),
        ("min_tls_version", SettingMeta(.ssl, "Minimum TLS version", "最低 TLS 版本", options: ["1.0", "1.1", "1.2", "1.3"])),
        ("tls_1_3", SettingMeta(.ssl, "TLS 1.3", "TLS 1.3", options: ["on", "off", "zrt"])),
        ("automatic_https_rewrites", SettingMeta(.ssl, "Automatic HTTPS Rewrites", "自动 HTTPS 重写")),
        ("opportunistic_encryption", SettingMeta(.ssl, "Opportunistic Encryption", "机会性加密")),
        ("tls_client_auth", SettingMeta(.ssl, "Authenticated Origin Pulls", "源站认证拉取")),
        ("ssl_recommender", SettingMeta(.ssl, "SSL/TLS Recommender", "SSL/TLS 推荐器")),
        ("security_header", SettingMeta(.ssl, "HSTS", "HSTS 严格传输安全")),
        ("ciphers", SettingMeta(.ssl, "Cipher suites", "密码套件")),
        ("ssl_automatic_mode", SettingMeta(.ssl, "Automatic SSL/TLS", "自动 SSL/TLS", options: ["auto", "custom"])),
        // Speed
        ("brotli", SettingMeta(.speed, "Brotli", "Brotli 压缩")),
        ("early_hints", SettingMeta(.speed, "Early Hints", "Early Hints")),
        ("rocket_loader", SettingMeta(.speed, "Rocket Loader", "Rocket Loader")),
        ("polish", SettingMeta(.speed, "Polish (image optimization)", "Polish 图片优化", options: ["off", "lossless", "lossy"])),
        ("webp", SettingMeta(.speed, "WebP", "WebP 转换")),
        ("mirage", SettingMeta(.speed, "Mirage", "Mirage")),
        ("image_resizing", SettingMeta(.speed, "Image Resizing", "图片缩放", options: ["on", "off", "open"])),
        ("h2_prioritization", SettingMeta(.speed, "HTTP/2 prioritization", "HTTP/2 优先级", options: ["on", "off", "custom"])),
        ("prefetch_preload", SettingMeta(.speed, "Prefetch preload", "预取预加载")),
        ("fonts", SettingMeta(.speed, "Cloudflare Fonts", "Cloudflare 字体")),
        ("speed_brain", SettingMeta(.speed, "Speed Brain", "Speed Brain")),
        ("automatic_platform_optimization", SettingMeta(.speed, "Automatic Platform Optimization", "平台自动优化 (APO)")),
        ("minify", SettingMeta(.speed, "Auto Minify (legacy)", "自动压缩（旧版）")),
        ("mobile_redirect", SettingMeta(.speed, "Mobile redirect (legacy)", "移动端重定向（旧版）")),
        // Caching
        ("cache_level", SettingMeta(.caching, "Caching level", "缓存级别", options: ["basic", "simplified", "aggressive"])),
        ("browser_cache_ttl", SettingMeta(.caching, "Browser cache TTL", "浏览器缓存 TTL", numberOptions: ttlOptions)),
        ("edge_cache_ttl", SettingMeta(.caching, "Edge cache TTL", "边缘缓存 TTL", numberOptions: ttlOptions)),
        ("development_mode", SettingMeta(.caching, "Development mode", "开发模式")),
        ("always_online", SettingMeta(.caching, "Always Online", "始终在线")),
        ("sort_query_string_for_cache", SettingMeta(.caching, "Sort query string", "查询字符串排序")),
        ("origin_error_page_pass_thru", SettingMeta(.caching, "Origin error page pass-through", "透传源站错误页")),
        ("crawler_hints", SettingMeta(.caching, "Crawler Hints", "爬虫提示")),
        // Network
        ("http2", SettingMeta(.network, "HTTP/2", "HTTP/2")),
        ("http3", SettingMeta(.network, "HTTP/3 (QUIC)", "HTTP/3 (QUIC)")),
        ("0rtt", SettingMeta(.network, "0-RTT Connection Resumption", "0-RTT 连接恢复")),
        ("ipv6", SettingMeta(.network, "IPv6 compatibility", "IPv6 兼容")),
        ("websockets", SettingMeta(.network, "WebSockets", "WebSockets")),
        ("grpc", SettingMeta(.network, "gRPC", "gRPC")),
        ("pseudo_ipv4", SettingMeta(.network, "Pseudo IPv4", "伪 IPv4", options: ["off", "add_header", "overwrite_header"])),
        ("ip_geolocation", SettingMeta(.network, "IP geolocation header", "IP 地理位置头")),
        ("max_upload", SettingMeta(.network, "Maximum upload size (MB)", "最大上传大小（MB）",
                                   numberOptions: [100, 125, 150, 175, 200, 225, 250, 275, 300, 325, 350, 375, 400, 425, 450, 475, 500])),
        ("opportunistic_onion", SettingMeta(.network, "Onion routing", "洋葱路由")),
        ("true_client_ip_header", SettingMeta(.network, "True-Client-IP header", "True-Client-IP 头")),
        ("orange_to_orange", SettingMeta(.network, "Orange-to-Orange (O2O)", "橙云到橙云 (O2O)")),
        ("response_buffering", SettingMeta(.network, "Response buffering", "响应缓冲")),
        ("proxy_read_timeout", SettingMeta(.network, "Proxy read timeout (s)", "代理读取超时（秒）")),
        ("origin_max_http_version", SettingMeta(.network, "Max HTTP version to origin", "回源最高 HTTP 版本", options: ["1", "2"])),
        ("nel", SettingMeta(.network, "Network Error Logging", "网络错误日志")),
        ("visitor_ip", SettingMeta(.network, "Visitor IP", "访客 IP")),
        // Security
        ("security_level", SettingMeta(.security, "Security level", "安全级别",
                                       options: ["off", "essentially_off", "low", "medium", "high", "under_attack"])),
        ("challenge_ttl", SettingMeta(.security, "Challenge passage", "质询通过有效期",
                                      numberOptions: [300, 900, 1800, 2700, 3600, 7200, 10800, 14400, 28800, 57600, 86400, 604800, 2592000, 31536000])),
        ("browser_check", SettingMeta(.security, "Browser integrity check", "浏览器完整性检查")),
        ("privacy_pass", SettingMeta(.security, "Privacy Pass", "Privacy Pass")),
        ("waf", SettingMeta(.security, "WAF (legacy)", "WAF（旧版）")),
        ("replace_insecure_js", SettingMeta(.security, "Replace insecure JS libraries", "替换不安全的 JS 库")),
        ("advanced_ddos", SettingMeta(.security, "Advanced DDoS", "高级 DDoS 防护")),
        ("aegis", SettingMeta(.security, "Aegis (dedicated egress IPs)", "Aegis 专用出口 IP")),
        // Scrape shield
        ("email_obfuscation", SettingMeta(.scrape, "Email address obfuscation", "电子邮件地址混淆")),
        ("server_side_exclude", SettingMeta(.scrape, "Server-side excludes", "服务端排除")),
        ("hotlink_protection", SettingMeta(.scrape, "Hotlink protection", "防盗链")),
    ]

    public static let byId: [String: SettingMeta] = Dictionary(uniqueKeysWithValues: ordered)
    static let rank: [String: Int] = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.0, $0) })

    public static func group(of id: String) -> SettingGroup { byId[id]?.group ?? .other }

    /// Setting ids of [group] among [available], in display order.
    public static func ids(in group: SettingGroup, of available: some Sequence<String>) -> [String] {
        available.filter { self.group(of: $0) == group }.sorted { (rank[$0] ?? 999, $0) < (rank[$1] ?? 999, $1) }
    }

    /// A setting value for display.
    public static func valueLabel(_ id: String, _ value: JSON) -> String {
        if id.hasSuffix("_ttl"), let s = value.int {
            if s == 0 { return id == "browser_cache_ttl" ? L("Respect existing headers", "遵循源站头") : "0" }
            return Format.duration(seconds: s)
        }
        if id == "ssl" {
            switch value.string {
            case "off": return L("Off (not secure)", "关闭（不安全）")
            case "flexible": return L("Flexible", "灵活")
            case "full": return L("Full", "完全")
            case "strict": return L("Full (strict)", "完全（严格）")
            default: break
            }
        }
        if id == "tls_1_3", value.string == "zrt" { return L("On + 0-RTT", "开启 + 0-RTT") }
        return value.text(or: "—")
    }

    /// Reads `GET /zones/{id}/settings` into id → setting object.
    public static func index(_ list: JSON) -> [String: JSON] {
        var out: [String: JSON] = [:]
        for s in list.items { if let id = s["id"].string { out[id] = s } }
        return out
    }
}

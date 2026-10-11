import Foundation

/// A phase of the Rulesets Engine and how its rules are edited.
public struct RulePhase: Sendable, Hashable, Identifiable {
    public var phase: String
    public var title: LocalizedText
    public var description: LocalizedText?
    public var symbol: String
    public var actions: [String]
    /// Example `action_parameters` per action.
    public var templates: [String: JSON]
    public var ratelimit: Bool

    public var id: String { phase }

    public init(
        _ phase: String, _ en: String, _ zh: String, description: LocalizedText? = nil, symbol: String, actions: [String],
        templates: [String: JSON] = [:], ratelimit: Bool = false
    ) {
        self.phase = phase
        title = LocalizedText(en, zh)
        self.description = description
        self.symbol = symbol
        self.actions = actions
        self.templates = templates
        self.ratelimit = ratelimit
    }
}

public enum Rules {
    public static let securityPhases: [RulePhase] = [
        RulePhase(
            "http_request_firewall_custom", "Custom rules", "自定义规则",
            description: LocalizedText("Block, challenge or skip requests matching an expression.", "对匹配表达式的请求进行拦截、质询或跳过。"),
            symbol: "shield", actions: ["block", "managed_challenge", "js_challenge", "challenge", "log", "skip"],
            templates: [
                "block": ["response": ["status_code": 403, "content_type": "text/plain", "content": "Forbidden"]],
                "skip": [
                    "ruleset": "current", "phases": ["http_ratelimit", "http_request_firewall_managed"],
                    "products": ["bic", "securityLevel", "uaBlock", "zoneLockdown", "hot"],
                ],
            ]),
        RulePhase(
            "http_ratelimit", "Rate limiting rules", "限速规则",
            description: LocalizedText("Throttle clients that exceed a request rate.", "限制超过请求速率的客户端。"),
            symbol: "speedometer", actions: ["block", "managed_challenge", "js_challenge", "challenge", "log"], ratelimit: true),
        RulePhase(
            "http_request_firewall_managed", "Managed rules", "托管规则",
            description: LocalizedText("Deploy Cloudflare-managed WAF rulesets.", "部署 Cloudflare 托管的 WAF 规则集。"),
            symbol: "checkmark.shield", actions: ["execute", "skip"],
            templates: ["execute": ["id": "efb7b8c949ac4650a09736fc376e9aee"], "skip": ["ruleset": "current"]]),
        RulePhase(
            "http_response_firewall_managed", "Response managed rules", "响应托管规则",
            description: LocalizedText("Sensitive data detection on responses.", "响应中的敏感数据检测。"),
            symbol: "doc.text.magnifyingglass", actions: ["execute", "skip"]),
    ]

    public static let transformPhases: [RulePhase] = [
        RulePhase(
            "http_request_dynamic_redirect", "Redirect rules", "重定向规则", symbol: "arrow.turn.up.right", actions: ["redirect"],
            templates: [
                "redirect": [
                    "from_value": [
                        "status_code": 301,
                        "target_url": ["expression": "concat(\"https://www.example.com\", http.request.uri.path)"],
                        "preserve_query_string": true,
                    ]
                ]
            ]),
        RulePhase(
            "http_request_transform", "URL rewrite rules", "URL 重写规则", symbol: "arrow.triangle.swap", actions: ["rewrite"],
            templates: ["rewrite": ["uri": ["path": ["value": "/new-path"], "query": ["expression": "http.request.uri.query"]]]]),
        RulePhase(
            "http_request_late_transform", "Request header transforms", "请求头转换", symbol: "arrow.down.doc",
            actions: ["rewrite"],
            templates: [
                "rewrite": [
                    "headers": ["X-Example": ["operation": "set", "value": "value"], "X-Remove-Me": ["operation": "remove"]]
                ]
            ]),
        RulePhase(
            "http_response_headers_transform", "Response header transforms", "响应头转换", symbol: "arrow.up.doc",
            actions: ["rewrite"],
            templates: [
                "rewrite": [
                    "headers": [
                        "Strict-Transport-Security": ["operation": "set", "value": "max-age=31536000"],
                        "X-Powered-By": ["operation": "remove"],
                    ]
                ]
            ]),
        RulePhase(
            "http_config_settings", "Configuration rules", "配置规则", symbol: "gearshape.2", actions: ["set_config"],
            templates: [
                "set_config": [
                    "ssl": "full", "automatic_https_rewrites": true, "rocket_loader": false, "security_level": "medium",
                ]
            ]),
        RulePhase(
            "http_request_origin", "Origin rules", "源站规则", symbol: "server.rack", actions: ["route"],
            templates: ["route": ["host_header": "origin.example.com", "origin": ["host": "origin.example.com", "port": 8443]]]),
        RulePhase(
            "http_request_cache_settings", "Cache rules", "缓存规则", symbol: "arrow.triangle.2.circlepath",
            actions: ["set_cache_settings"],
            templates: [
                "set_cache_settings": [
                    "cache": true, "edge_ttl": ["mode": "override_origin", "default": 3600],
                    "browser_ttl": ["mode": "respect_origin"],
                ]
            ]),
        RulePhase(
            "http_response_compression", "Compression rules", "压缩规则", symbol: "rectangle.compress.vertical",
            actions: ["compress_response"],
            templates: ["compress_response": ["algorithms": [["name": "zstd"], ["name": "brotli"], ["name": "gzip"]]]]),
        RulePhase(
            "http_custom_errors", "Custom error rules", "自定义错误规则", symbol: "exclamationmark.octagon",
            actions: ["serve_error"],
            templates: [
                "serve_error": ["content": "<h1>Something went wrong</h1>", "content_type": "text/html", "status_code": 503]
            ]),
        RulePhase(
            "http_log_custom_fields", "Custom log fields", "自定义日志字段", symbol: "list.bullet.rectangle",
            actions: ["log_custom_field"],
            templates: ["log_custom_field": ["request_fields": [["name": "content-type"]], "cookie_fields": [["name": "__cfruid"]]]]),
    ]

    /// Account-level bulk redirects (Lists page).
    public static let bulkRedirects = RulePhase(
        "http_request_redirect", "Bulk redirect rules", "批量重定向规则",
        description: LocalizedText(
            "Enable redirect lists with an expression. Rule action must be \"redirect\" with from_list.",
            "用表达式启用重定向列表。规则动作需为 redirect 并使用 from_list。"),
        symbol: "arrow.turn.up.right", actions: ["redirect"],
        templates: ["redirect": ["from_list": ["name": "my_redirect_list", "key": "http.request.full_uri"]]])

    /// Fields offered as quick inserts in the expression editor.
    public static let expressionFields = [
        "http.host", "http.request.uri.path", "http.request.uri.query", "http.request.full_uri", "http.request.method",
        "http.user_agent", "http.referer", "http.cookie", "ip.src", "ip.src.country", "ip.src.asnum", "ip.src.continent",
        "cf.client.bot", "cf.threat_score", "cf.bot_management.score", "ssl", "http.request.headers[\"x-example\"][0]",
        "http.response.code",
    ]

    public static let expressionTemplates: [(title: LocalizedText, expression: String)] = [
        (LocalizedText("Everything", "全部请求"), "true"),
        (LocalizedText("Hostname equals", "主机名等于"), "(http.host eq \"www.example.com\")"),
        (LocalizedText("Path starts with", "路径前缀"), "starts_with(http.request.uri.path, \"/admin\")"),
        (LocalizedText("Country in list", "国家/地区在列表中"), "(ip.src.country in {\"CN\" \"RU\"})"),
        (LocalizedText("IP in range", "IP 段"), "(ip.src in {192.0.2.0/24 2001:db8::/32})"),
        (LocalizedText("Not a verified bot", "非已验证爬虫"), "(not cf.client.bot)"),
        (LocalizedText("Uses IP list", "使用 IP 列表"), "(ip.src in $my_list)"),
    ]

    public static let defaultRatelimit: JSON = [
        "characteristics": ["cf.colo.id", "ip.src"], "period": 60, "requests_per_period": 100, "mitigation_timeout": 600,
    ]

    /// A rule with only the fields a PATCH accepts.
    public static func ruleBody(_ rule: JSON) -> JSON {
        let keep: Set<String> = [
            "action", "action_parameters", "description", "enabled", "expression", "logging", "ratelimit", "ref",
            "exposed_credential_check",
        ]
        return .object((rule.object ?? [:]).filter { keep.contains($0.key) })
    }

    public static func actionTone(_ action: String?) -> StatusTone {
        switch action {
        case "block": return .bad
        case "challenge", "js_challenge", "managed_challenge": return .warn
        case "skip", "log": return .neutral
        default: return .good
        }
    }

    public static func entrypoint(_ basePath: String, _ phase: String) -> String {
        "\(basePath)/rulesets/phases/\(phase)/entrypoint"
    }
}

/// Email Routing rules.
public enum EmailRouting {
    public static func describe(actions: JSON) -> String {
        let list = actions.items
        if list.isEmpty { return "—" }
        return list.map { a in
            let v = a["value"].strings.joined(separator: ", ")
            switch a["type"].string {
            case "forward": return "→ " + v
            case "worker": return "⚡ Worker: " + v
            case "drop": return "✗ drop"
            default: return "\(a["type"].text ?? "") \(v)"
            }
        }
        .joined(separator: "; ")
    }

    public static func describe(matchers: JSON) -> String {
        let list = matchers.items
        if list.isEmpty { return "—" }
        return list.map { $0["type"].string == "all" ? "*" : ($0["value"].text ?? "") }.joined(separator: ", ")
    }

    public static func isCatchAll(_ rule: JSON) -> Bool { rule["matchers"].items.contains { $0["type"].string == "all" } }

    /// The body of a routing rule. [values] are destination addresses or a Worker name.
    public static func ruleBody(
        local: String?, zone: String, type: String, values: [String], name: String, enabled: Bool
    ) -> JSON {
        var action: [String: JSON] = ["type": .string(type)]
        if type != "drop" { action["value"] = .array(values.map(JSON.string)) }
        let matchers: JSON = local == nil
            ? [["type": "all"]] : [["type": "literal", "field": "to", "value": .string("\(local!)@\(zone)")]]
        return ["name": .string(name), "enabled": .bool(enabled), "matchers": matchers, "actions": [.object(action)]]
    }
}

/// Cloudflare Tunnel configuration helpers.
public enum Tunnels {
    public static let schemes = ["http", "https", "tcp", "ssh", "rdp", "smb", "unix", "http_status", "hello_world"]

    public static func path(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/cfd_tunnel" }

    public static func isCatchAll(_ rule: JSON) -> Bool { rule["hostname"].isNull && rule["path"].isNull }

    /// The ingress rules to save: the catch-all (or `http_status:404`) last, as cloudflared requires.
    public static func ingress(_ rules: [JSON]) -> [JSON] {
        let specific = rules.filter { !isCatchAll($0) }
        let catchAll = rules.last(where: isCatchAll) ?? ["service": "http_status:404"]
        return specific + [catchAll]
    }

    /// Splits a service URL into the editor's scheme and target.
    public static func split(service: String?) -> (scheme: String, target: String) {
        let s = service ?? "http://localhost:8080"
        if s.hasPrefix("http_status:") { return ("http_status", String(s.dropFirst(12))) }
        if s == "hello_world" { return ("hello_world", "") }
        if let r = s.range(of: "://") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return ("http", s)
    }

    public static func service(scheme: String, target: String) -> String {
        switch scheme {
        case "http_status": return "http_status:" + target
        case "hello_world": return "hello_world"
        default: return scheme + "://" + target
        }
    }

    /// The zone of [zones] a host name belongs to (the longest match).
    public static func zone(for hostname: String, in zones: [JSON]) -> JSON? {
        zones.filter { z in
            let n = z["name"].string ?? ""
            return hostname == n || hostname.hasSuffix("." + n)
        }
        .max { ($0["name"].string ?? "").count < ($1["name"].string ?? "").count }
    }

    public static func installCommands(token: String) -> [(title: String, command: String)] {
        [
            (L("Install as a service", "安装为系统服务"), "cloudflared service install \(token)"),
            (L("Run in the foreground", "前台运行"), "cloudflared tunnel run --token \(token)"),
            (
                "Docker",
                "docker run -d --restart unless-stopped cloudflare/cloudflared:latest tunnel --no-autoupdate run --token \(token)"
            ),
        ]
    }
}

/// Account lists (IP, hostname, ASN, redirect).
public enum RuleLists {
    public static let kinds: [(kind: String, title: LocalizedText)] = [
        ("ip", LocalizedText("IP addresses", "IP 地址")), ("redirect", LocalizedText("Bulk redirects", "批量重定向")),
        ("hostname", LocalizedText("Hostnames", "主机名")), ("asn", LocalizedText("ASNs", "ASN")),
    ]

    public static func path(_ accountId: String) -> String { "/accounts/\(accountId.pathEncoded)/rules/lists" }

    public static func title(of kind: String) -> String { kinds.first { $0.kind == kind }?.title.text ?? kind }

    public static func label(_ item: JSON, kind: String) -> String {
        switch kind {
        case "ip": return item["ip"].text ?? ""
        case "asn": return "AS" + (item["asn"].text ?? "")
        case "hostname": return item["hostname"]["url_hostname"].text ?? ""
        case "redirect":
            return "\(item["redirect"]["source_url"].text ?? "")  →  \(item["redirect"]["target_url"].text ?? "")"
        default: return item.compactString
        }
    }

    public static func hint(kind: String) -> String {
        switch kind {
        case "ip": return "203.0.113.7 optional comment\n198.51.100.0/24"
        case "asn": return "13335\nAS15169"
        case "hostname": return "www.example.com"
        default: return "https://old.example.com/a https://new.example.com/b 301"
        }
    }

    /// One item from a line of text (`value [more values] [comment…]`).
    public static func parse(_ line: String, kind: String) -> JSON? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return nil }
        let first = kind == "redirect" ? 3 : 1
        let comment = parts.count > first ? parts[first...].joined(separator: " ") : nil
        var item: [String: JSON]
        switch kind {
        case "ip":
            item = ["ip": .string(parts[0])]
        case "asn":
            guard let n = Int(parts[0].replacingOccurrences(of: "as", with: "", options: .caseInsensitive)) else { return nil }
            item = ["asn": .int(n)]
        case "hostname":
            item = ["hostname": ["url_hostname": .string(parts[0])]]
        case "redirect":
            guard parts.count >= 2 else { return nil }
            item = [
                "redirect": [
                    "source_url": .string(parts[0]), "target_url": .string(parts[1]),
                    "status_code": .int(parts.count > 2 ? Int(parts[2]) ?? 301 : 301),
                ]
            ]
        default:
            return nil
        }
        if let comment { item["comment"] = .string(comment) }
        return .object(item)
    }
}

/// API token creation.
public enum APITokens {
    /// `account`, `zone` or `user`, from a permission group's scopes.
    public static func scope(of group: JSON) -> String {
        let scopes = group["scopes"].strings
        if scopes.contains(where: { $0.hasSuffix(".zone") }) { return "zone" }
        if scopes.contains(where: { $0.hasSuffix(".user") }) { return "user" }
        return "account"
    }

    /// The `policies` of a new token for the chosen permission groups.
    public static func policies(
        groups: [JSON], accountId: String?, zoneId: String?, currentZoneOnly: Bool, userId: String?
    ) -> [JSON] {
        var byScope: [String: [JSON]] = [:]
        for g in groups { byScope[scope(of: g), default: []].append(["id": g["id"]]) }
        var out: [JSON] = []
        if let perms = byScope["account"], let accountId {
            out.append([
                "effect": "allow", "resources": .object(["com.cloudflare.api.account.\(accountId)": "*"]),
                "permission_groups": .array(perms),
            ])
        }
        if let perms = byScope["zone"], let accountId {
            let resources: JSON = currentZoneOnly && zoneId != nil
                ? .object(["com.cloudflare.api.account.zone.\(zoneId!)": "*"])
                : .object(["com.cloudflare.api.account.\(accountId)": ["com.cloudflare.api.account.zone.*": "*"]])
            out.append(["effect": "allow", "resources": resources, "permission_groups": .array(perms)])
        }
        if let perms = byScope["user"], let userId {
            out.append([
                "effect": "allow", "resources": .object(["com.cloudflare.api.user.\(userId)": "*"]),
                "permission_groups": .array(perms),
            ])
        }
        return out
    }

    /// `expires_on` for a token valid for [days].
    public static func expiry(days: Int, now: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(Double(days) * 86400))
    }
}

/// Ready-made GraphQL Analytics queries.
public struct GraphQLTemplate: Sendable, Identifiable {
    public var title: LocalizedText
    public var query: String
    /// Variable name → placeholder: `{zone}`, `{account}`, `{since}`, `{until}`, `{sinceDate}`, `{untilDate}`.
    public var variables: [(String, String)]

    public var id: String { title.en }

    /// The variables JSON with the placeholders filled in.
    public func filledVariables(zoneId: String?, accountId: String?, now: Date = Date()) -> JSON {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let values: [String: String] = [
            "{zone}": zoneId ?? "", "{account}": accountId ?? "",
            "{since}": ISODate.format(now.addingTimeInterval(-86400)), "{until}": ISODate.format(now),
            "{sinceDate}": day.string(from: now.addingTimeInterval(-7 * 86400)), "{untilDate}": day.string(from: now),
        ]
        var out: [String: JSON] = [:]
        for (k, v) in variables { out[k] = .string(values[v] ?? v) }
        return .object(out)
    }

    public static let all: [GraphQLTemplate] = [
        GraphQLTemplate(
            title: LocalizedText("Zone traffic by day", "域名每日流量"),
            query: """
                query ($zoneTag: string, $since: Date, $until: Date) {
                  viewer {
                    zones(filter: { zoneTag: $zoneTag }) {
                      httpRequests1dGroups(limit: 31, filter: { date_geq: $since, date_leq: $until }, orderBy: [date_ASC]) {
                        dimensions { date }
                        sum { requests cachedRequests bytes threats pageViews }
                        uniq { uniques }
                      }
                    }
                  }
                }
                """,
            variables: [("zoneTag", "{zone}"), ("since", "{sinceDate}"), ("until", "{untilDate}")]),
        GraphQLTemplate(
            title: LocalizedText("Top paths (adaptive)", "热门路径（自适应）"),
            query: """
                query ($zoneTag: string, $since: Time, $until: Time) {
                  viewer {
                    zones(filter: { zoneTag: $zoneTag }) {
                      httpRequestsAdaptiveGroups(limit: 20, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [count_DESC]) {
                        count
                        dimensions { clientRequestPath clientRequestHTTPHost }
                      }
                    }
                  }
                }
                """,
            variables: [("zoneTag", "{zone}"), ("since", "{since}"), ("until", "{until}")]),
        GraphQLTemplate(
            title: LocalizedText("Firewall events", "防火墙事件"),
            query: """
                query ($zoneTag: string, $since: Time, $until: Time) {
                  viewer {
                    zones(filter: { zoneTag: $zoneTag }) {
                      firewallEventsAdaptive(limit: 50, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
                        action source datetime clientIP clientCountryName clientRequestPath userAgent ruleId
                      }
                    }
                  }
                }
                """,
            variables: [("zoneTag", "{zone}"), ("since", "{since}"), ("until", "{until}")]),
        GraphQLTemplate(
            title: LocalizedText("Workers invocations", "Workers 调用"),
            query: """
                query ($accountTag: string, $since: Time, $until: Time) {
                  viewer {
                    accounts(filter: { accountTag: $accountTag }) {
                      workersInvocationsAdaptive(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }) {
                        sum { requests errors subrequests }
                        quantiles { cpuTimeP50 cpuTimeP99 }
                        dimensions { scriptName status }
                      }
                    }
                  }
                }
                """,
            variables: [("accountTag", "{account}"), ("since", "{since}"), ("until", "{until}")]),
        GraphQLTemplate(
            title: LocalizedText("R2 operations", "R2 操作"),
            query: """
                query ($accountTag: string, $since: Time, $until: Time) {
                  viewer {
                    accounts(filter: { accountTag: $accountTag }) {
                      r2OperationsAdaptiveGroups(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }) {
                        sum { requests }
                        dimensions { bucketName actionType }
                      }
                    }
                  }
                }
                """,
            variables: [("accountTag", "{account}"), ("since", "{since}"), ("until", "{until}")]),
        GraphQLTemplate(
            title: LocalizedText("R2 storage", "R2 存储量"),
            query: """
                query ($accountTag: string, $since: Time, $until: Time) {
                  viewer {
                    accounts(filter: { accountTag: $accountTag }) {
                      r2StorageAdaptiveGroups(limit: 100, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
                        max { objectCount payloadSize metadataSize }
                        dimensions { bucketName datetime }
                      }
                    }
                  }
                }
                """,
            variables: [("accountTag", "{account}"), ("since", "{since}"), ("until", "{until}")]),
        GraphQLTemplate(
            title: LocalizedText("D1 queries", "D1 查询"),
            query: """
                query ($accountTag: string, $since: Date, $until: Date) {
                  viewer {
                    accounts(filter: { accountTag: $accountTag }) {
                      d1AnalyticsAdaptiveGroups(limit: 100, filter: { date_geq: $since, date_leq: $until }) {
                        sum { readQueries writeQueries rowsRead rowsWritten }
                        dimensions { databaseId date }
                      }
                    }
                  }
                }
                """,
            variables: [("accountTag", "{account}"), ("since", "{sinceDate}"), ("until", "{untilDate}")]),
        GraphQLTemplate(
            title: LocalizedText("DNS queries", "DNS 查询"),
            query: """
                query ($zoneTag: string, $since: Time, $until: Time) {
                  viewer {
                    zones(filter: { zoneTag: $zoneTag }) {
                      dnsAnalyticsAdaptiveGroups(limit: 50, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [count_DESC]) {
                        count
                        dimensions { queryName queryType responseCode }
                      }
                    }
                  }
                }
                """,
            variables: [("zoneTag", "{zone}"), ("since", "{since}"), ("until", "{until}")]),
    ]

    /// Recent firewall events of a zone (Security page).
    public static let securityEvents = """
        query SecurityEvents($zoneTag: string, $since: Time, $until: Time) {
          viewer {
            zones(filter: { zoneTag: $zoneTag }) {
              firewallEventsAdaptive(limit: 200, filter: { datetime_geq: $since, datetime_leq: $until }, orderBy: [datetime_DESC]) {
                action source datetime clientIP clientCountryName clientAsn clientRequestHTTPHost clientRequestHTTPMethodName
                clientRequestPath clientRequestQuery userAgent ruleId rayName description
              }
            }
          }
        }
        """
}

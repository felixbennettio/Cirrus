import Foundation

/// What Cirrus Pro unlocks in App Store builds. Managing zones (DNS, SSL/TLS,
/// security, rules, caching, zone settings, analytics) stays free.
public enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case compute, storage, zeroTrust, account, credentials, consoleWrites, graphql, longAnalytics

    public var id: String { rawValue }

    /// An SF Symbol.
    public var symbol: String {
        switch self {
        case .compute: return "bolt"
        case .storage: return "externaldrive"
        case .zeroTrust: return "shield.lefthalf.filled"
        case .account: return "person.2.badge.gearshape"
        case .credentials: return "person.2"
        case .consoleWrites: return "terminal"
        case .graphql: return "point.3.connected.trianglepath.dotted"
        case .longAnalytics: return "chart.xyaxis.line"
        }
    }

    public var label: LocalizedText {
        switch self {
        case .compute: return LocalizedText("Workers, Pages & Workers AI", "Workers、Pages 与 Workers AI")
        case .storage: return LocalizedText("KV, R2, D1 and other storage", "KV、R2、D1 等存储与数据库")
        case .zeroTrust:
            return LocalizedText("Zero Trust: Tunnels, Access, Gateway, devices", "Zero Trust：隧道、Access、Gateway、设备")
        case .account: return LocalizedText("Members, API tokens, audit log & more", "成员、API Token、审计日志等账户管理")
        case .credentials: return LocalizedText("More than one credential", "保存多套凭据")
        case .consoleWrites: return LocalizedText("Write requests in the API console", "在 API 控制台发送写请求")
        case .graphql: return LocalizedText("GraphQL explorer", "GraphQL 查询")
        case .longAnalytics: return LocalizedText("30-day analytics", "30 天流量分析")
        }
    }
}

/// The product sold for Cirrus Pro (a non-consumable).
public let proProductID = "cirrus_pro_lifetime"

/// The channel a build is sold through. Pro is only sold (and only
/// enforced) in store builds; every other build is fully unlocked.
public enum StoreChannel: String, Sendable {
    case none
    case appStore
    case license

    public init(setting: String?) {
        switch (setting ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "appstore", "app_store", "apple": self = .appStore
        case "license", "licence", "direct": self = .license
        default: self = .none
        }
    }
}

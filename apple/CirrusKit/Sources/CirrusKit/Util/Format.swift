import Foundation

/// Formatting helpers shared by the screens.
public enum Format {
    /// `1.5 MB` (1024-based, like the Flutter app).
    public static func bytes(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = value
        var i = 0
        while abs(v) >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return String(format: "%.\(i == 0 ? 0 : decimals)f", v) + " " + units[i]
    }

    /// `12.3K`, `4.5M` (compact counts).
    public static func count(_ value: Double?) -> String {
        guard let value else { return "—" }
        let a = abs(value)
        func trim(_ x: Double) -> String {
            let s = String(format: x >= 100 ? "%.0f" : "%.1f", x)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if AppLanguage.current == .zh {
            if a >= 1e8 { return trim(value / 1e8) + "亿" }
            if a >= 1e4 { return trim(value / 1e4) + "万" }
            return number(value)
        }
        if a >= 1e9 { return trim(value / 1e9) + "B" }
        if a >= 1e6 { return trim(value / 1e6) + "M" }
        if a >= 1e3 { return trim(value / 1e3) + "K" }
        return number(value)
    }

    /// `12,345` in the current language.
    public static func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = AppLanguage.current.locale
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func percent(_ ratio: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", ratio * 100)
    }

    /// Dates as strings (ISO 8601), or seconds / milliseconds since 1970.
    public static func date(_ value: JSON) -> Date? {
        switch value {
        case .string(let s): return ISODate.parse(s)
        case .int, .double:
            guard let v = value.double else { return nil }
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        default: return nil
        }
    }

    /// `2026-10-10 14:05` (local time), or the raw value when it isn't a date.
    public static func date(_ value: JSON, withTime: Bool = true) -> String {
        guard let d = date(value) else { return value.text(or: "—") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = withTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// `5m ago` / `5 分钟前`.
    public static func relative(_ value: JSON, now: Date = Date()) -> String {
        guard let d = date(value) else { return value.text(or: "—") }
        return relative(d, now: now)
    }

    public static func relative(_ d: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(d)
        let future = diff < 0
        let a = abs(diff)
        let zh = AppLanguage.current == .zh
        if a < 60 { return zh ? "刚刚" : "just now" }
        let unit: String
        if a < 3600 {
            unit = zh ? "\(Int(a / 60)) 分钟" : "\(Int(a / 60))m"
        } else if a < 86400 {
            unit = zh ? "\(Int(a / 3600)) 小时" : "\(Int(a / 3600))h"
        } else if a < 86400 * 30 {
            unit = zh ? "\(Int(a / 86400)) 天" : "\(Int(a / 86400))d"
        } else if a < 86400 * 365 {
            unit = zh ? "\(Int(a / 86400 / 30)) 个月" : "\(Int(a / 86400 / 30))mo"
        } else {
            unit = zh ? "\(Int(a / 86400 / 365)) 年" : "\(Int(a / 86400 / 365))y"
        }
        if zh { return future ? "\(unit)后" : "\(unit)前" }
        return future ? "in \(unit)" : "\(unit) ago"
    }

    /// A DNS TTL: `Auto` for 1, else `5m`, `1h`, `1d` or seconds.
    public static func ttl(_ value: JSON) -> String {
        let t = value.int ?? 1
        if t <= 1 { return L("Auto", "自动") }
        if t % 86400 == 0 { return "\(t / 86400)d" }
        if t % 3600 == 0 { return "\(t / 3600)h" }
        if t % 60 == 0 { return "\(t / 60)m" }
        return "\(t)s"
    }

    /// A duration in seconds as `3 hour(s)` / `3 小时` (zone setting TTLs).
    public static func duration(seconds s: Int) -> String {
        if s > 0 && s % 86400 == 0 { return L("\(s / 86400) day(s)", "\(s / 86400) 天") }
        if s > 0 && s % 3600 == 0 { return L("\(s / 3600) hour(s)", "\(s / 3600) 小时") }
        if s > 0 && s % 60 == 0 { return L("\(s / 60) minute(s)", "\(s / 60) 分钟") }
        return "\(s) s"
    }
}

/// Fills `{account_id}`, `{zone_id}` and friends in an API path template.
public func expandPath(_ template: String, ids: [String: String?]) -> String {
    var out = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
        out += rest[..<open]
        let key = String(rest[rest.index(after: open)..<close])
        var value = ids[key] ?? nil
        if value == nil {
            switch key {
            case "account_identifier", "account_tag": value = ids["account_id"] ?? nil
            case "zone_identifier", "zone_tag": value = ids["zone_id"] ?? nil
            default: break
            }
        }
        out += value.map(\.pathEncoded) ?? String(rest[open...close])
        rest = rest[rest.index(after: close)...]
    }
    return out + rest
}

import Foundation

/// One time bucket of zone HTTP traffic.
public struct TrafficPoint: Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var requests: Double
    public var cachedRequests: Double
    public var bytes: Double
    public var cachedBytes: Double
    public var threats: Double
    public var pageViews: Double
    public var uniques: Double
}

/// Zone HTTP traffic over a period (GraphQL Analytics API).
public struct ZoneTraffic: Sendable {
    public var points: [TrafficPoint]
    public var statusCodes: [String: Double]
    public var countries: [String: Double]
    public var hourly: Bool

    private func sum(_ f: (TrafficPoint) -> Double) -> Double { points.reduce(0) { $0 + f($1) } }
    public var requests: Double { sum(\.requests) }
    public var cachedRequests: Double { sum(\.cachedRequests) }
    public var bytes: Double { sum(\.bytes) }
    public var cachedBytes: Double { sum(\.cachedBytes) }
    public var threats: Double { sum(\.threats) }
    public var pageViews: Double { sum(\.pageViews) }
    /// The highest daily/hourly unique count (uniques don't add up).
    public var uniques: Double { points.map(\.uniques).max() ?? 0 }
    public var cacheRatio: Double { requests == 0 ? 0 : cachedRequests / requests }

    /// The [n] largest entries.
    public static func top(_ m: [String: Double], _ n: Int = 10) -> [(String, Double)] {
        Array(m.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) })
    }

    static let fields = """
                sum {
                  requests
                  cachedRequests
                  bytes
                  cachedBytes
                  threats
                  pageViews
                  responseStatusMap { edgeResponseStatus requests }
                  countryMap { clientCountryName requests }
                }
                uniq { uniques }
        """

    public static let dailyQuery = """
        query ZoneDaily($zoneTag: string, $since: Date, $until: Date) {
          viewer {
            zones(filter: { zoneTag: $zoneTag }) {
              httpRequests1dGroups(limit: 92, filter: { date_geq: $since, date_leq: $until }, orderBy: [date_ASC]) {
                dimensions { date }
        \(fields)
              }
            }
          }
        }
        """

    public static let hourlyQuery = """
        query ZoneHourly($zoneTag: string, $since: Time, $until: Time) {
          viewer {
            zones(filter: { zoneTag: $zoneTag }) {
              httpRequests1hGroups(limit: 72, filter: { datetime_geq: $since, datetime_lt: $until }, orderBy: [datetime_ASC]) {
                dimensions { datetime }
        \(fields)
              }
            }
          }
        }
        """

    /// The GraphQL variables for the last [hours] hours (hourly) or [days] days.
    public static func variables(zoneId: String, days: Int = 7, hours: Int? = nil, now: Date = Date()) -> JSON {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        if let hours {
            let hourStart = utc.dateInterval(of: .hour, for: now)!.start
            let until = hourStart.addingTimeInterval(3600)
            let since = until.addingTimeInterval(-Double(hours) * 3600)
            return ["zoneTag": .string(zoneId), "since": .string(isoSeconds(since)), "until": .string(isoSeconds(until))]
        }
        let since = utc.date(byAdding: .day, value: -(days - 1), to: now)!
        return ["zoneTag": .string(zoneId), "since": .string(day(since)), "until": .string(day(now))]
    }

    static func isoSeconds(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Reads a GraphQL `data` object.
    public static func parse(_ data: JSON, hourly: Bool) -> ZoneTraffic {
        let groups = data["viewer"]["zones"][0][hourly ? "httpRequests1hGroups" : "httpRequests1dGroups"].items
        var status: [String: Double] = [:]
        var countries: [String: Double] = [:]
        var points: [TrafficPoint] = []
        for g in groups {
            let sum = g["sum"]
            let raw = g["dimensions"][hourly ? "datetime" : "date"].string ?? ""
            let date = ISODate.parse(raw) ?? Date(timeIntervalSince1970: 0)
            points.append(
                TrafficPoint(
                    date: date, requests: sum["requests"].double ?? 0, cachedRequests: sum["cachedRequests"].double ?? 0,
                    bytes: sum["bytes"].double ?? 0, cachedBytes: sum["cachedBytes"].double ?? 0,
                    threats: sum["threats"].double ?? 0, pageViews: sum["pageViews"].double ?? 0,
                    uniques: g["uniq"]["uniques"].double ?? 0))
            for s in sum["responseStatusMap"].items {
                let k = s["edgeResponseStatus"].text ?? "?"
                status[k, default: 0] += s["requests"].double ?? 0
            }
            for s in sum["countryMap"].items {
                let k = s["clientCountryName"].text ?? "?"
                countries[k, default: 0] += s["requests"].double ?? 0
            }
        }
        return ZoneTraffic(points: points, statusCodes: status, countries: countries, hourly: hourly)
    }

    /// Loads zone traffic: hourly for [hours], else daily for [days].
    public static func fetch(_ client: CFClient, zoneId: String, days: Int = 7, hours: Int? = nil) async throws
        -> ZoneTraffic
    {
        let hourly = hours != nil
        let data = try await client.graphql(
            hourly ? hourlyQuery : dailyQuery, variables: variables(zoneId: zoneId, days: days, hours: hours))
        return parse(data, hourly: hourly)
    }
}

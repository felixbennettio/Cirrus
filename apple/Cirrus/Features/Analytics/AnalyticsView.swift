import Charts
import CirrusKit
import SwiftUI

struct AnalyticsView: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var range = "7d"
    @State private var paywall = false

    var body: some View {
        QueryView("analytics:\(zone.id):\(range)", fetch: { (c: CFClient) async throws -> ZoneTraffic in
            if range == "24h" { return try await ZoneTraffic.fetch(c, zoneId: zone.id, hours: 24) }
            return try await ZoneTraffic.fetch(c, zoneId: zone.id, days: range == "7d" ? 7 : 30)
        }) { t, h in
            TrafficView(traffic: t).refreshable { await h.reload() }
        }
        .id(range)
        .safeAreaInset(edge: .top) {
            Picker(L("Range", "时间范围"), selection: Binding(get: { range }, set: { v in
                if v == "30d" && !model.pro.hasPro { paywall = true } else { range = v }
            })) {
                Text("24h").tag("24h")
                Text("7d").tag("7d")
                Text("30d").tag("30d")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(L("Analytics", "分析"))
        .toolbar { ZoneToolbar() }
        .sheet(isPresented: $paywall) { PaywallSheet(feature: .longAnalytics) }
    }
}

struct TrafficView: View {
    let traffic: ZoneTraffic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatGrid(minWidth: 160) {
                    StatTile(label: L("Requests", "请求数"), value: Format.count(traffic.requests), symbol: "arrow.up.arrow.down")
                    StatTile(
                        label: L("Cached", "缓存命中"), value: Format.percent(traffic.cacheRatio), symbol: "arrow.triangle.2.circlepath",
                        sub: Format.count(traffic.cachedRequests))
                    StatTile(
                        label: L("Bandwidth", "带宽"), value: Format.bytes(traffic.bytes), symbol: "chart.pie",
                        sub: L("cached", "缓存") + " " + Format.bytes(traffic.cachedBytes))
                    StatTile(label: L("Unique visitors", "独立访客"), value: Format.count(traffic.uniques), symbol: "person.2")
                    StatTile(label: L("Page views", "页面浏览"), value: Format.count(traffic.pageViews), symbol: "eye")
                    StatTile(label: L("Threats", "威胁"), value: Format.count(traffic.threats), symbol: "exclamationmark.shield")
                }
                if traffic.points.isEmpty {
                    EmptyState(title: L("No data for this period", "该时间段没有数据"), symbol: "chart.bar")
                } else {
                    card(L("Requests", "请求")) {
                        SeriesChart(
                            points: traffic.points, hourly: traffic.hourly, format: { Format.count($0) },
                            series: [
                                (L("Total", "总计"), Color.accentColor, { $0.requests }),
                                (L("Cached", "已缓存"), Color.teal, { $0.cachedRequests }),
                            ])
                    }
                    card(L("Bandwidth", "带宽")) {
                        SeriesChart(
                            points: traffic.points, hourly: traffic.hourly, format: { Format.bytes($0, decimals: 0) },
                            series: [
                                (L("Total", "总计"), Color.indigo, { $0.bytes }),
                                (L("Cached", "已缓存"), Color.teal, { $0.cachedBytes }),
                            ])
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            statusCard
                            countryCard
                        }
                        VStack(spacing: 16) {
                            statusCard
                            countryCard
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
    }

    private var statusCard: some View {
        card(L("Status codes", "状态码")) { TopList(items: ZoneTraffic.top(traffic.statusCodes), color: .accentColor) }
            .frame(minWidth: 300)
    }

    private var countryCard: some View {
        card(L("Top countries", "主要国家/地区")) { TopList(items: ZoneTraffic.top(traffic.countries), color: .teal) }
            .frame(minWidth: 300)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Lines for a few series over the traffic points.
struct SeriesChart: View {
    let points: [TrafficPoint]
    let hourly: Bool
    let format: (Double) -> String
    let series: [(String, Color, (TrafficPoint) -> Double)]

    private var dateStyle: Date.FormatStyle {
        hourly ? Date.FormatStyle.dateTime.hour() : Date.FormatStyle.dateTime.month(.abbreviated).day()
    }

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Value", s.2(p)))
                        .foregroundStyle(by: .value("Series", s.0))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map { $0.0 }, range: series.map { $0.1 })
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { Text(format(v.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel(format: dateStyle)
            }
        }
        .frame(height: 220)
    }
}

/// Horizontal bars of the largest values.
struct TopList: View {
    let items: [(String, Double)]
    let color: Color

    var body: some View {
        let maxValue = items.map { $0.1 }.max() ?? 1
        VStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.0).lineLimit(1)
                        Spacer()
                        Text(Format.count(item.1)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    GeometryReader { g in
                        Capsule().fill(color.opacity(0.75))
                            .frame(width: max(4, g.size.width * item.1 / max(maxValue, 1)))
                    }
                    .frame(height: 6)
                }
            }
            if items.isEmpty { Text("—").foregroundStyle(.secondary) }
        }
    }
}

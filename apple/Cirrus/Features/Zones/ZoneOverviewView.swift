import Charts
import CirrusKit
import SwiftUI

/// The zone's details, quick switches and the last week of traffic.
struct ZoneOverviewView: View {
    let zone: ZoneRef

    struct Overview {
        var zone: JSON
        var devMode: JSON?
        var securityLevel: String?
    }

    var body: some View {
        QueryView("zone-overview:" + zone.id, fetch: { c in try await load(c) }) { s, h in
            OverviewContent(state: s, handle: h)
        }
        .navigationTitle(L("Zone overview", "域名概览"))
        .toolbar { ZoneToolbar() }
    }

    private func load(_ c: CFClient) async throws -> Overview {
        let id = zone.id
        async let z = c.get("/zones/\(id)")
        async let dev = try? c.get("/zones/\(id)/settings/development_mode")
        async let level = try? c.get("/zones/\(id)/settings/security_level")
        return Overview(zone: try await z, devMode: await dev, securityLevel: await level?["value"].string)
    }
}

private struct OverviewContent: View {
    let state: ZoneOverviewView.Overview
    let handle: QueryHandle<ZoneOverviewView.Overview>
    @Environment(AppModel.self) private var model
    @Environment(\.openScreen) private var openScreen
    @State private var confirmPause = false
    @State private var confirmPurge = false

    var body: some View {
        let z = state.zone
        let id = z["id"].string ?? ""
        let paused = z["paused"].isTrue
        let status = z["status"].string ?? ""
        let devOn = state.devMode?["value"].string == "on"
        let devLeft = state.devMode?["time_remaining"].double ?? 0
        Form {
            if status == "pending" {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("Waiting for nameserver change", "等待名称服务器生效"), systemImage: "hourglass")
                            .font(.headline)
                        Text(
                            L(
                                "Point the domain to the Cloudflare nameservers below at your registrar, then re-check.",
                                "请在域名注册商处把名称服务器改为下面的 Cloudflare 名称服务器，然后重新检查。"))
                        Button(L("Re-check now", "立即重新检查")) {
                            Task {
                                await model.run(L("Check requested", "已请求检查")) {
                                    try await model.client?.put("/zones/\(id)/activation_check")
                                }
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            Section {
                LabeledContent(L("Status", "状态")) { ZoneStatusBadge(zone: z) }
                InfoRow(L("Plan", "套餐"), z["plan"]["name"].string)
                InfoRow(L("Setup", "接入方式"), z["type"].string)
                InfoRow("Zone ID", id, mono: true, copy: true)
                InfoRow(L("Account ID", "账户 ID"), z["account"]["id"].string, mono: true, copy: true)
                ForEach(Array(z["name_servers"].strings.enumerated()), id: \.offset) { i, ns in
                    InfoRow(L("Nameserver", "名称服务器") + " \(i + 1)", ns, mono: true, copy: true)
                }
                if !z["original_name_servers"].strings.isEmpty {
                    InfoRow(L("Original nameservers", "原名称服务器"), z["original_name_servers"].strings.joined(separator: ", "))
                }
                if let r = z["original_registrar"].string { InfoRow(L("Registrar", "注册商"), r) }
                InfoRow(L("Created", "创建时间"), Format.date(z["created_on"]))
                if !z["activated_on"].isNull { InfoRow(L("Activated", "激活时间"), Format.date(z["activated_on"])) }
            } header: {
                Text(z["name"].string ?? "")
            }

            Section(L("Quick actions", "快捷操作")) {
                Toggle(isOn: Binding(get: { devOn }, set: { v in Task { await setDevMode(id, v) } })) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(L("Development mode", "开发模式"))
                            Text(
                                devOn && devLeft > 0
                                    ? L("Cache bypassed · \(Int((devLeft / 60).rounded(.up))) min left", "已绕过缓存 · 剩余 \(Int((devLeft / 60).rounded(.up))) 分钟")
                                    : L("Temporarily bypass the cache for 3 hours", "临时绕过缓存 3 小时")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hammer")
                    }
                }
                Toggle(isOn: Binding(get: { state.securityLevel == "under_attack" }, set: { v in Task { await setUnderAttack(id, v) } })) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(L("I'm Under Attack mode", "“正在遭受攻击”模式"))
                            Text(L("Challenge every visitor with a JS check", "对所有访客启用 JS 质询"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                }
                Toggle(
                    isOn: Binding(
                        get: { paused },
                        set: { v in
                            if v { confirmPause = true } else { Task { await setPaused(id, false) } }
                        })
                ) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(L("Pause Cloudflare on site", "暂停 Cloudflare"))
                            Text(L("DNS only — traffic goes directly to your origin", "仅 DNS——流量直接发往源站"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pause.circle")
                    }
                }
                Button(L("Purge everything", "清除全部缓存"), systemImage: "trash", role: .destructive) {
                    confirmPurge = true
                }
            }

            Section {
                HStack {
                    shortcut(.dns)
                    shortcut(.ssl)
                    shortcut(.analytics)
                }
                .buttonStyle(.glass)
            }

            MiniTraffic(zoneId: id)
        }
        .formStyle(.grouped)
        .refreshable { await handle.reload() }
        .confirmationDialog(L("Pause Cloudflare?", "暂停 Cloudflare？"), isPresented: $confirmPause, titleVisibility: .visible) {
            Button(L("Pause", "暂停"), role: .destructive) { Task { await setPaused(id, true) } }
        } message: {
            Text(L("Your origin IPs will be exposed and protections disabled.", "源站 IP 将暴露，所有防护将失效。"))
        }
        .confirmationDialog(L("Purge all cached files?", "清除全部缓存文件？"), isPresented: $confirmPurge, titleVisibility: .visible) {
            Button(L("Purge everything", "清除全部缓存"), role: .destructive) {
                Task {
                    await model.run(L("Cache purged", "缓存已清除")) {
                        try await model.client?.post("/zones/\(id)/purge_cache", ["purge_everything": true])
                    }
                }
            }
        } message: {
            Text(L("This may temporarily increase load on your origin.", "这可能会暂时增加源站负载。"))
        }
    }

    private func shortcut(_ s: Screen) -> some View {
        Button {
            openScreen(s)
        } label: {
            Label(s.title, systemImage: s.symbol).frame(maxWidth: .infinity)
        }
    }

    private func setDevMode(_ id: String, _ on: Bool) async {
        await model.run { try await model.client?.patch("/zones/\(id)/settings/development_mode", ["value": .string(on ? "on" : "off")]) }
        await handle.reload()
    }

    private func setUnderAttack(_ id: String, _ on: Bool) async {
        await model.run {
            try await model.client?.patch("/zones/\(id)/settings/security_level", ["value": .string(on ? "under_attack" : "medium")])
        }
        await handle.reload()
    }

    private func setPaused(_ id: String, _ paused: Bool) async {
        await model.run { try await model.client?.patch("/zones/\(id)", ["paused": .bool(paused)]) }
        await model.loadZones(force: true)
        await handle.reload()
    }
}

/// The last 7 days of requests (zone overview).
private struct MiniTraffic: View {
    let zoneId: String

    var body: some View {
        Section(L("Last 7 days", "最近 7 天")) {
            QueryView("analytics:\(zoneId):7d", fetch: { c in try await ZoneTraffic.fetch(c, zoneId: zoneId, days: 7) }) { t, _ in
                VStack(alignment: .leading, spacing: 14) {
                    StatGrid(minWidth: 130) {
                        StatTile(label: L("Requests", "请求数"), value: Format.count(t.requests))
                        StatTile(label: L("Bandwidth", "带宽"), value: Format.bytes(t.bytes))
                        StatTile(label: L("Cached", "缓存率"), value: Format.percent(t.cacheRatio))
                        StatTile(label: L("Threats", "威胁"), value: Format.count(t.threats))
                    }
                    Chart(t.points) { p in
                        AreaMark(x: .value("Date", p.date), y: .value(L("Requests", "请求"), p.requests))
                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", p.date), y: .value(L("Requests", "请求"), p.requests))
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { Text(Format.count(v.as(Double.self))) }
                        }
                    }
                    .frame(height: 170)
                }
                .padding(.vertical, 6)
            }
            .frame(minHeight: 120)
        }
    }
}

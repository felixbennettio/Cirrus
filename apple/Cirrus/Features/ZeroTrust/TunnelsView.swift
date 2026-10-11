import CirrusKit
import SwiftUI

private func tunnelColor(_ status: String?) -> Color {
    switch status {
    case "healthy": return .green
    case "degraded": return .orange
    case "down": return .red
    default: return .secondary
    }
}

/// The tunnel token's install commands.
struct TunnelInstallItem: Identifiable {
    let id = UUID()
    var token: String
}

struct TunnelInstallSheet: View {
    let item: TunnelInstallItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("Run one of these on the machine that can reach your services:", "在能访问你的服务的机器上运行以下任一命令："))
                }
                ForEach(Tunnels.installCommands(token: item.token), id: \.title) { c in
                    Section(c.title) {
                        Text(c.command).font(.caption.monospaced()).textSelection(.enabled)
                        Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(c.command) }
                    }
                }
                Section {
                    Text(L("The token grants access to run this tunnel — keep it secret.", "该 Token 可运行此隧道，请妥善保管。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Install connector", "安装连接器"))
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } } }
        }
        .frame(minWidth: 600, minHeight: 480)
    }
}

struct TunnelsView: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var install: TunnelInstallItem?

    var body: some View {
        QueryView(
            "tunnels:" + accountId,
            fetch: { c in try await c.list(Tunnels.path(accountId), query: ["is_deleted": "false"], perPage: 100) }
        ) { tunnels, h in
            List(tunnels, id: \.self) { t in
                let conns = t["connections"].items
                let colos = Set(conns.compactMap { $0["colo_name"].string }).sorted().joined(separator: ", ")
                NavigationLink {
                    TunnelDetailView(accountId: accountId, tunnelId: t["id"].text ?? "")
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .foregroundStyle(tunnelColor(t["status"].string))
                            .frame(width: 30, height: 30)
                            .background(tunnelColor(t["status"].string).opacity(0.15), in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t["name"].text ?? "").fontWeight(.semibold)
                            Text(
                                [
                                    t["config_src"].string == "cloudflare" ? L("Remotely managed", "远程管理") : L("Locally managed", "本地管理"),
                                    conns.isEmpty ? nil : "\(conns.count) \(L("connections", "个连接")) (\(colos))",
                                    Format.date(t["created_at"], withTime: false),
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(t["status"].text ?? "")
                    }
                }
            }
            .overlay {
                if tunnels.isEmpty {
                    EmptyState(
                        title: L("No tunnels", "没有隧道"), symbol: "point.3.connected.trianglepath.dotted",
                        message: L("Expose local services securely without opening ports.", "无需开放端口即可安全地暴露内网服务。"))
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create tunnel", "创建隧道"), systemImage: "plus") {
                        prompt = TextPrompt(title: L("Tunnel name", "隧道名称"), placeholder: "home-lab", confirm: L("Create", "创建")) { name in
                            await create(name.trimmingCharacters(in: .whitespaces), h)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Tunnels", "隧道"))
        .textPrompt($prompt)
        .sheet(item: $install) { TunnelInstallSheet(item: $0) }
    }

    private func create(_ name: String, _ h: QueryHandle<[JSON]>) async {
        guard let client = model.client, !name.isEmpty else { return }
        let result = await model.run(L("Tunnel created", "隧道已创建")) {
            try await client.post(Tunnels.path(accountId), ["name": .string(name), "config_src": "cloudflare"])
        }
        guard let t = result else { return }
        await h.reload()
        var token = t["token"].string
        if token == nil, let id = t["id"].text {
            token = (try? await client.get("\(Tunnels.path(accountId))/\(id)/token"))?.string
        }
        if let token { install = TunnelInstallItem(token: token) }
    }
}

struct TunnelDetailView: View {
    let accountId: String
    let tunnelId: String

    enum Part: String, CaseIterable, Identifiable {
        case overview, hostnames, networks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return L("Overview", "概览")
            case .hostnames: return L("Public hostnames", "公共主机名")
            case .networks: return L("Private networks", "私有网络")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var part = Part.overview
    @State private var prompt: TextPrompt?
    @State private var install: TunnelInstallItem?
    @State private var json: JSONItem?

    private var base: String { "\(Tunnels.path(accountId))/\(tunnelId)" }

    var body: some View {
        QueryView("tunnel:" + base, fetch: { c in try await c.get(base) }) { t, h in
            VStack(spacing: 0) {
                SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
                Group {
                    switch part {
                    case .overview: TunnelOverview(tunnel: t, reload: h.reload)
                    case .hostnames:
                        if t["config_src"].string == "cloudflare" {
                            IngressEditor(base: base, tunnelId: tunnelId)
                        } else {
                            EmptyState(
                                title: L("Locally managed tunnel", "本地管理的隧道"), symbol: "desktopcomputer",
                                message: L("Its ingress rules live in config.yml on the connector host.", "其 ingress 规则保存在连接器主机的 config.yml 中。"))
                        }
                    case .networks: PrivateRoutes(accountId: accountId, tunnelId: tunnelId)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle(t["name"].text ?? L("Tunnel", "隧道"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(L("Install / run", "安装 / 运行"), systemImage: "terminal") {
                            Task {
                                let r = await model.run { try await model.client?.get(base + "/token") }
                                if let o = r, let token = o?.string { install = TunnelInstallItem(token: token) }
                            }
                        }
                        Button(L("Rename", "重命名"), systemImage: "pencil") {
                            prompt = TextPrompt(title: L("Rename tunnel", "重命名隧道"), text: t["name"].text ?? "") { n in
                                await model.run { try await model.client?.patch(base, ["name": .string(n.trimmingCharacters(in: .whitespaces))]) }
                                await h.reload()
                            }
                        }
                        Button(L("Clean up stale connections", "清理失效连接"), systemImage: "bolt.horizontal.circle") {
                            Task {
                                await model.run(L("Stale connections removed", "已清理失效连接")) { try await model.client?.delete(base + "/connections") }
                                await h.reload()
                            }
                        }
                        Button("JSON", systemImage: "curlybraces") { json = JSONItem(title: t["name"].text ?? "", json: t) }
                        Divider()
                        Button(L("Delete tunnel", "删除隧道"), systemImage: "trash", role: .destructive) {
                            prompt = typedDelete(
                                L("Delete tunnel?", "删除隧道？"), name: t["name"].text ?? "",
                                message: L("Connectors will be disconnected and the tunnel removed.", "连接器将断开，隧道将被删除。"),
                                feedback: model.feedback
                            ) {
                                _ = try? await model.client?.delete(base + "/connections")
                                let r = await model.run(L("Deleted", "已删除")) { try await model.client?.send("DELETE", base) }
                                if r != nil {
                                    QueryCache.shared.clear()
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        Label(L("More", "更多"), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .inlineTitle()
        .textPrompt($prompt)
        .sheet(item: $install) { TunnelInstallSheet(item: $0) }
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

private struct TunnelOverview: View {
    let tunnel: JSON
    let reload: () async -> Void

    var body: some View {
        let t = tunnel
        let conns = t["connections"].items
        Form {
            Section {
                LabeledContent(L("Status", "状态")) { StatusBadge(t["status"].text ?? "") }
                InfoRow("Tunnel ID", t["id"].text, mono: true, copy: true)
                InfoRow("CNAME", "\(t["id"].text ?? "").cfargotunnel.com", mono: true, copy: true)
                InfoRow(L("Type", "类型"), t["tun_type"].string ?? "cfd_tunnel")
                InfoRow(
                    L("Configuration", "配置方式"),
                    t["config_src"].string == "cloudflare" ? L("Remote (dashboard/API)", "远程（面板/API）") : L("Local (config.yml)", "本地 (config.yml)"))
                InfoRow(L("Created", "创建时间"), Format.date(t["created_at"]))
                if !t["conns_active_at"].isNull { InfoRow(L("Active since", "活跃自"), Format.date(t["conns_active_at"])) }
            }
            Section(L("Connections (\(conns.count))", "连接（\(conns.count)）")) {
                if conns.isEmpty { Text(L("No active connectors", "没有活跃的连接器")).foregroundStyle(.secondary) }
                ForEach(Array(conns.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c["colo_name"].text ?? "")  \(c["origin_ip"].text ?? "")")
                        Text(
                            [
                                c["client_version"].string.map { "cloudflared " + $0 },
                                c["opened_at"].isNull ? nil : Format.relative(c["opened_at"]),
                                c["is_pending_reconnect"].isTrue ? "pending reconnect" : nil,
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .refreshable { await reload() }
    }
}

/// The ingress rules of a remotely managed tunnel.
private struct IngressEditor: View {
    let base: String
    let tunnelId: String
    @Environment(AppModel.self) private var model
    @State private var editing: IngressDraft?
    @State private var rawConfig: String?
    @State private var confirm: ConfirmItem?

    struct IngressDraft: Identifiable {
        let id = UUID()
        var index: Int?
        var rule: JSON?
    }

    var body: some View {
        QueryView("tunnel-config:" + base, fetch: { c in try await c.get(base + "/configurations") }) { cfg, h in
            let rules = cfg["config"]["ingress"].items
            List {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.offset) { i, r in
                        let catchAll = Tunnels.isCatchAll(r)
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).frame(width: 24, height: 24).background(Color.accentColor.opacity(0.15), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(catchAll ? L("Catch-all", "兜底规则") : "\(r["hostname"].text ?? "*")\(r["path"].string.map { "  " + $0 } ?? "")")
                                Text("→ " + (r["service"].text ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { if !catchAll { editing = IngressDraft(index: i, rule: r) } }
                        .swipeActions {
                            if !catchAll {
                                Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) {
                                    confirm = ConfirmItem(title: L("Remove \(r["hostname"].text ?? "")?", "移除 \(r["hostname"].text ?? "")？"), button: L("Remove", "移除")) {
                                        var copy = rules
                                        copy.remove(at: i)
                                        _ = await save(cfg, copy, h)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text(L("Rules are matched top to bottom.", "规则按从上到下的顺序匹配。"))
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(L("Edit raw config", "编辑原始配置"), systemImage: "curlybraces") { rawConfig = cfg["config"].prettyString }
                    Button(L("Add hostname", "添加主机名"), systemImage: "plus") { editing = IngressDraft(index: nil, rule: nil) }
                }
            }
            .sheet(item: $editing) { d in
                IngressRuleSheet(rule: d.rule) { rule, createDNS in
                    var list = rules
                    if let i = d.index {
                        list[i] = rule
                    } else {
                        let catchAllIndex = list.firstIndex(where: Tunnels.isCatchAll) ?? list.count
                        list.insert(rule, at: catchAllIndex)
                    }
                    guard await save(cfg, list, h) else { return false }
                    if createDNS, let host = rule["hostname"].string { await ensureDNS(host) }
                    return true
                }
            }
            .sheet(isPresented: Binding(get: { rawConfig != nil }, set: { if !$0 { rawConfig = nil } })) {
                JSONEditorSheet(title: "config", text: rawConfig ?? "{}") { text in
                    guard let parsed = try? JSON.parse(text) else {
                        model.feedback.show(L("Invalid JSON", "JSON 格式错误"), error: true)
                        return false
                    }
                    let r = await model.run(L("Saved", "已保存")) { try await model.client?.put(base + "/configurations", ["config": parsed]) }
                    if r != nil { await h.reload() }
                    return r != nil
                }
            }
        }
        .confirm($confirm)
    }

    private func save(_ cfg: JSON, _ rules: [JSON], _ h: QueryHandle<JSON>) async -> Bool {
        let config = cfg["config"].setting("ingress", to: .array(Tunnels.ingress(rules)))
        let r = await model.run(L("Configuration saved", "配置已保存")) {
            try await model.client?.put(base + "/configurations", ["config": config])
        }
        if r != nil { await h.reload() }
        return r != nil
    }

    private func ensureDNS(_ hostname: String) async {
        guard let zone = Tunnels.zone(for: hostname, in: model.zones), let zoneId = zone["id"].text else {
            model.feedback.show(
                L("No zone in this account matches \(hostname); add the CNAME manually.", "账户中没有与 \(hostname) 匹配的域名，请手动添加 CNAME。"),
                error: true)
            return
        }
        await model.run(L("DNS record created", "DNS 记录已创建")) {
            try await model.client?.post(
                "/zones/\(zoneId)/dns_records",
                [
                    "type": "CNAME", "name": .string(hostname), "content": .string("\(tunnelId).cfargotunnel.com"), "proxied": true,
                    "comment": "Cloudflare Tunnel (Cirrus)",
                ])
        }
    }
}

private struct IngressRuleSheet: View {
    let rule: JSON?
    let save: (JSON, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var path = ""
    @State private var scheme = "http"
    @State private var target = ""
    @State private var origin = ""
    @State private var createDNS = true
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Hostname", "主机名"), text: $host, prompt: Text("app.example.com")).plainInput()
                    TextField(L("Path (regex, optional)", "路径（正则，可选）"), text: $path, prompt: Text("^/api/")).plainInput()
                }
                Section(L("Service", "服务")) {
                    Picker(L("Type", "类型"), selection: $scheme) {
                        ForEach(Tunnels.schemes, id: \.self) { Text($0).tag($0) }
                    }
                    if scheme != "hello_world" {
                        TextField(scheme == "http_status" ? L("Status code", "状态码") : "URL", text: $target, prompt: Text(scheme == "http_status" ? "404" : "localhost:8080"))
                            .plainInput()
                    }
                }
                Section("originRequest (JSON)") {
                    TextField("{\"noTLSVerify\": true}", text: $origin, axis: .vertical).font(.caption.monospaced()).plainInput().lineLimit(2...8)
                }
                if rule == nil {
                    Section {
                        Toggle(L("Create the proxied CNAME DNS record", "创建已代理的 CNAME DNS 记录"), isOn: $createDNS)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? L("Public hostname", "公共主机名") : L("Edit hostname", "编辑主机名"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save", "保存")) { Task { await submit() } } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                host = rule?["hostname"].string ?? ""
                path = rule?["path"].string ?? ""
                let s = Tunnels.split(service: rule?["service"].string)
                scheme = s.scheme
                target = s.target
                origin = rule?["originRequest"].isNull == false ? rule!["originRequest"].prettyString : ""
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private func submit() async {
        var r: [String: JSON] = ["service": .string(Tunnels.service(scheme: scheme, target: target.trimmingCharacters(in: .whitespaces)))]
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = path.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { r["hostname"] = .string(h) }
        if !p.isEmpty { r["path"] = .string(p) }
        if !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let o = try? JSON.parse(origin) else {
                error = L("originRequest must be valid JSON", "originRequest 必须是合法 JSON")
                return
            }
            r["originRequest"] = o
        }
        if await save(.object(r), createDNS && rule == nil) { dismiss() }
    }
}

private struct PrivateRoutes: View {
    let accountId: String
    let tunnelId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    var body: some View {
        let base = "/accounts/\(accountId)/teamnet/routes"
        QueryView(
            "tunnel-routes:" + tunnelId,
            fetch: { c in try await c.list(base, query: ["tunnel_id": tunnelId, "is_deleted": "false"]) }
        ) { routes, h in
            List {
                Section {
                    ForEach(routes, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r["network"].text ?? "").font(.body.monospaced())
                            Text((r["comment"].text ?? "") + (r["virtual_network_id"].isNull ? "" : " · vnet " + (r["virtual_network_id"].text ?? "")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(title: L("Delete route \(r["network"].text ?? "")?", "删除路由 \(r["network"].text ?? "")？"), button: L("Delete", "删除")) {
                                    await model.run { try await model.client?.delete("\(base)/\(r["id"].text ?? "")") }
                                    await h.reload()
                                }
                            }
                        }
                    }
                } footer: {
                    Text(L("CIDR routes reachable through this tunnel (WARP to Tunnel).", "通过此隧道可访问的 CIDR 路由（WARP 到隧道）。"))
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Add route", "添加路由"), systemImage: "plus") {
                        prompt = TextPrompt(title: "CIDR", placeholder: "10.0.0.0/24", confirm: L("Add", "添加")) { cidr in
                            await model.run(L("Route added", "路由已添加")) {
                                try await model.client?.post(base, ["network": .string(cidr.trimmingCharacters(in: .whitespaces)), "tunnel_id": .string(tunnelId)])
                            }
                            await h.reload()
                        }
                    }
                }
            }
        }
        .textPrompt($prompt)
        .confirm($confirm)
    }
}

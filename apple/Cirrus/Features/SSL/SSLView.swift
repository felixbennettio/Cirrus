import CirrusKit
import SwiftUI

struct SSLView: View {
    let zone: ZoneRef

    enum Part: String, CaseIterable, Identifiable {
        case overview, edge, origin, custom, client
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return L("Overview", "概览")
            case .edge: return L("Edge certificates", "边缘证书")
            case .origin: return L("Origin server", "源服务器")
            case .custom: return L("Custom", "自定义证书")
            case .client: return L("Client", "客户端证书")
            }
        }
    }

    @State private var part = Part.overview

    var body: some View {
        Group {
            switch part {
            case .overview: SSLOverview(zoneId: zone.id)
            case .edge: EdgeCertificates(zone: zone)
            case .origin: OriginCertificates(zone: zone)
            case .custom:
                CertificateList(
                    key: "custom-certs:" + zone.id, path: "/zones/\(zone.id)/custom_certificates",
                    title: { $0["hosts"].strings.joined(separator: ", ") },
                    subtitle: { c in
                        [c["issuer"].string, c["expires_on"].isNull ? nil : Format.date(c["expires_on"], withTime: false), c["bundle_method"].string]
                            .compactMap { $0 }.joined(separator: " · ")
                    },
                    empty: L("No custom certificates", "没有自定义证书"))
            case .client:
                CertificateList(
                    key: "client-certs:" + zone.id, path: "/zones/\(zone.id)/client_certificates",
                    title: { $0["common_name"].string ?? $0["id"].string ?? "" },
                    subtitle: { c in
                        [c["expires_on"].isNull ? nil : Format.date(c["expires_on"], withTime: false), c["serial_number"].string]
                            .compactMap { $0 }.joined(separator: " · ")
                    },
                    empty: L("No client certificates", "没有客户端证书"))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
        }
        .navigationTitle("SSL/TLS")
        .toolbar { ZoneToolbar() }
    }
}

/// Encryption mode, edge settings and HSTS.
private struct SSLOverview: View {
    let zoneId: String
    @Environment(AppModel.self) private var model

    static let edgeIds = [
        "always_use_https", "min_tls_version", "tls_1_3", "automatic_https_rewrites", "opportunistic_encryption",
        "tls_client_auth", "ssl_automatic_mode", "ciphers",
    ]

    var body: some View {
        QueryView("zone-settings:" + zoneId, fetch: { c in try await loadZoneSettings(c, zoneId) }) { settings, h in
            let update: (JSON) -> Void = { s in
                var next = settings
                if let id = s["id"].string { next[id] = s }
                h.set(next)
            }
            Form {
                Section(L("Encryption mode", "加密模式")) {
                    let mode = settings["ssl"]?["value"].string
                    ForEach(Self.modes) { m in
                        Button {
                            Task {
                                let result = await model.run(L("Encryption mode updated", "加密模式已更新")) {
                                    try await model.client?.patch("/zones/\(zoneId)/settings/ssl", ["value": .string(m.id)])
                                }
                                if let response = result, let r = response { update(r) }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: m.symbol).foregroundStyle(.tint).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).fontWeight(.medium)
                                    Text(m.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode == m.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section(L("Edge settings", "边缘设置")) {
                    ForEach(Self.edgeIds, id: \.self) { id in
                        if let s = settings[id] { ZoneSettingRow(zoneId: zoneId, setting: s, changed: update) }
                    }
                }
                if let header = settings["security_header"] {
                    HSTSSection(zoneId: zoneId, setting: header, changed: update)
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
        }
    }

    struct Mode: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    static var modes: [Mode] {
        [
            Mode(id: "off", symbol: "lock.open", title: L("Off", "关闭"), detail: L("No encryption. Not recommended.", "不加密，不推荐。")),
            Mode(id: "flexible", symbol: "lock", title: L("Flexible", "灵活"), detail: L("HTTPS to visitors, HTTP to origin.", "访客到 Cloudflare 加密，回源 HTTP。")),
            Mode(id: "full", symbol: "lock.fill", title: L("Full", "完全"), detail: L("HTTPS to origin, any certificate.", "回源 HTTPS，接受任意证书。")),
            Mode(id: "strict", symbol: "checkmark.shield.fill", title: L("Full (strict)", "完全（严格）"), detail: L("HTTPS to origin with a valid certificate.", "回源 HTTPS，要求有效证书。")),
        ]
    }
}

/// HSTS from the `security_header` zone setting.
struct HSTSSection: View {
    let zoneId: String
    let setting: JSON
    let changed: (JSON) -> Void
    @Environment(AppModel.self) private var model
    @State private var hsts: JSON
    @State private var saving = false

    static let ages = [0, 2_592_000, 5_184_000, 7_776_000, 10_368_000, 12_960_000, 15_552_000, 31_536_000, 63_072_000]

    static func ageLabel(_ a: Int) -> String {
        a == 0 ? L("0 (disable)", "0（关闭）") : a % 2_592_000 == 0 ? L("\(a / 2_592_000) months", "\(a / 2_592_000) 个月") : "\(a) s"
    }

    /// One line for the setting's value, e.g. "On · 6 months · subdomains".
    static func summary(_ value: JSON) -> String {
        let h = value["strict_transport_security"]
        guard h["enabled"].isTrue else { return L("Off", "关闭") }
        var parts = [L("On", "开启")]
        if let a = h["max_age"].int, a > 0 { parts.append(ageLabel(a)) }
        if h["include_subdomains"].isTrue { parts.append(L("subdomains", "含子域名")) }
        if h["preload"].isTrue { parts.append("preload") }
        return parts.joined(separator: " · ")
    }

    init(zoneId: String, setting: JSON, changed: @escaping (JSON) -> Void) {
        self.zoneId = zoneId
        self.setting = setting
        self.changed = changed
        _hsts = State(initialValue: setting["value"]["strict_transport_security"].object != nil ? setting["value"]["strict_transport_security"] : [:])
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { hsts[key].isTrue }, set: { hsts = hsts.setting(key, to: .bool($0)) })
    }

    var body: some View {
        let maxAge = hsts["max_age"].int ?? 0
        Section {
            Toggle(L("Enable HSTS", "启用 HSTS"), isOn: flag("enabled"))
            Picker("Max-Age", selection: Binding(get: { maxAge }, set: { hsts = hsts.setting("max_age", to: .int($0)) })) {
                ForEach(Array(Set(Self.ages + [maxAge])).sorted(), id: \.self) { a in
                    Text(Self.ageLabel(a)).tag(a)
                }
            }
            Toggle(L("Include subdomains", "包含子域名"), isOn: flag("include_subdomains"))
            Toggle("Preload", isOn: flag("preload"))
            Toggle(L("No-Sniff header", "No-Sniff 头"), isOn: flag("nosniff"))
            Button(L("Save HSTS", "保存 HSTS")) { Task { await save() } }
                .disabled(saving)
        } header: {
            Text(L("HTTP Strict Transport Security (HSTS)", "HTTP 严格传输安全 (HSTS)"))
        } footer: {
            Text(
                L(
                    "Browsers will refuse plain HTTP for your domain. Disabling later only takes effect after max-age expires.",
                    "浏览器将拒绝以 HTTP 访问该域名。关闭后需等 max-age 过期才生效。"))
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body: JSON = ["value": ["strict_transport_security": hsts]]
        let result = await model.run(L("HSTS saved", "HSTS 已保存")) {
            try await model.client?.patch("/zones/\(zoneId)/settings/security_header", body)
        }
        if let response = result, let r = response { changed(r) }
    }
}

/// Universal SSL and certificate packs.
private struct EdgeCertificates: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var ordering = false
    @State private var jsonItem: JSONItem?
    @State private var deleting: JSON?
    @State private var confirmDisable = false

    struct Certs {
        var packs: [JSON]
        var universal: JSON?
    }

    var body: some View {
        QueryView("edge-certs:" + zone.id, fetch: { (c: CFClient) async throws -> Certs in
            async let packs = c.list("/zones/\(zone.id)/ssl/certificate_packs", query: ["status": "all"], perPage: 50)
            async let universal = try? c.get("/zones/\(zone.id)/ssl/universal/settings")
            return Certs(packs: try await packs, universal: await universal)
        }) { d, h in
            Form {
                if let u = d.universal {
                    Section {
                        Toggle(isOn: Binding(get: { u["enabled"].isTrue }, set: { v in
                            if v { Task { await setUniversal(true, h) } } else { confirmDisable = true }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Universal SSL", "通用 SSL"))
                                Text(L("Free certificate covering the apex and first-level subdomains.", "覆盖根域名和一级子域名的免费证书。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .confirmationDialog(L("Disable Universal SSL?", "关闭通用 SSL？"), isPresented: $confirmDisable, titleVisibility: .visible) {
                        Button(L("Disable", "关闭"), role: .destructive) { Task { await setUniversal(false, h) } }
                    } message: {
                        Text(L("Visitors may see certificate errors.", "访客可能会看到证书错误。"))
                    }
                }
                Section {
                    if d.packs.isEmpty { Text(L("No certificates", "没有证书")).foregroundStyle(.secondary) }
                    ForEach(d.packs, id: \.self) { p in
                        HStack(spacing: 12) {
                            Image(systemName: "rosette").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p["hosts"].strings.joined(separator: ", ")).lineLimit(2)
                                Text(packSubtitle(p)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(p["status"].string ?? "")
                        }
                        .contentShape(.rect)
                        .contextMenu {
                            Button(L("Details", "详情"), systemImage: "curlybraces") { jsonItem = JSONItem(title: L("Certificate pack", "证书包"), json: p) }
                            if p["type"].string != "universal" {
                                Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { deleting = p }
                            }
                        }
                        .onTapGesture { jsonItem = JSONItem(title: L("Certificate pack", "证书包"), json: p) }
                    }
                } header: {
                    HStack {
                        Text(L("Certificate packs", "证书包"))
                        Spacer()
                        Button(L("Order", "订购"), systemImage: "plus") { ordering = true }
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(isPresented: $ordering) {
                OrderCertificateSheet(zone: zone) { await h.reload() }
            }
            .confirmationDialog(
                L("Delete certificate pack?", "删除证书包？"),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting
            ) { p in
                Button(L("Delete", "删除"), role: .destructive) {
                    Task {
                        await model.run(L("Deleted", "已删除")) {
                            try await model.client?.delete("/zones/\(zone.id)/ssl/certificate_packs/\(p["id"].string ?? "")")
                        }
                        await h.reload()
                    }
                }
            } message: { p in
                Text(p["hosts"].strings.joined(separator: ", "))
            }
        }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func packSubtitle(_ p: JSON) -> String {
        var parts = [p["type"].string, p["certificate_authority"].string, p["validity_days"].int.map { "\($0)d" }].compactMap { $0 }
        if let first = p["certificates"].items.first, !first["expires_on"].isNull {
            parts.append(L("expires", "到期") + " " + Format.date(first["expires_on"], withTime: false))
        }
        return parts.joined(separator: " · ")
    }

    private func setUniversal(_ on: Bool, _ h: QueryHandle<Certs>) async {
        await model.run { try await model.client?.patch("/zones/\(zone.id)/ssl/universal/settings", ["enabled": .bool(on)]) }
        await h.reload()
    }
}

private struct OrderCertificateSheet: View {
    let zone: ZoneRef
    let done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: String
    @State private var ca = "lets_encrypt"
    @State private var validation = "txt"
    @State private var days = 90
    @State private var busy = false

    init(zone: ZoneRef, done: @escaping () async -> Void) {
        self.zone = zone
        self.done = done
        _hosts = State(initialValue: "\(zone.name)\n*.\(zone.name)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Hostnames (one per line)", "主机名（每行一个）")) {
                    TextField("", text: $hosts, axis: .vertical).plainInput().lineLimit(2...6)
                }
                Section {
                    Picker(L("Certificate authority", "证书颁发机构"), selection: $ca) {
                        Text("Let's Encrypt").tag("lets_encrypt")
                        Text("Google Trust Services").tag("google")
                        Text("SSL.com").tag("ssl_com")
                    }
                    Picker(L("Validation method", "验证方式"), selection: $validation) {
                        Text("TXT").tag("txt")
                        Text("HTTP").tag("http")
                        Text("Email").tag("email")
                    }
                    Picker(L("Validity", "有效期"), selection: $days) {
                        ForEach([14, 30, 90, 365], id: \.self) { Text(L("\($0) days", "\($0) 天")).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Order advanced certificate", "订购高级证书"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Order", "订购")) { Task { await order() } }.disabled(busy)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func order() async {
        let list = hosts.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        busy = true
        defer { busy = false }
        let body: JSON = [
            "type": "advanced", "hosts": .array(list.map(JSON.string)), "certificate_authority": .string(ca),
            "validation_method": .string(validation), "validity_days": .int(days),
        ]
        let r = await model.run(L("Certificate ordered", "证书已订购")) {
            try await model.client?.post("/zones/\(zone.id)/ssl/certificate_packs/order", body)
        }
        if r != nil {
            await done()
            dismiss()
        }
    }
}

/// A read-only list of certificates with JSON details.
private struct CertificateList: View {
    let key: String
    let path: String
    let title: (JSON) -> String
    let subtitle: (JSON) -> String
    let empty: String
    @State private var jsonItem: JSONItem?

    var body: some View {
        QueryView(key, fetch: { c in try await c.list(path, perPage: 50) }) { list, h in
            List {
                ForEach(list, id: \.self) { c in
                    Button {
                        jsonItem = JSONItem(title: title(c), json: c)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(c)).lineLimit(2)
                                Text(subtitle(c)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let s = c["status"].string { StatusBadge(s) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay { if list.isEmpty { EmptyState(title: empty, symbol: "doc.badge.ellipsis") } }
            .refreshable { await h.reload() }
        }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

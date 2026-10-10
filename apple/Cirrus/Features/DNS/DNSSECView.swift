import CirrusKit
import SwiftUI

/// DNSSEC status, the DS record for the registrar, and the switch.
struct DNSSECSheet: View {
    let zoneId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QueryView("dnssec:" + zoneId, fetch: { c in try await c.get("/zones/\(zoneId)/dnssec") }) { d, h in
                let status = d["status"].string ?? "disabled"
                let on = status == "active" || status == "pending"
                Form {
                    Section {
                        LabeledContent(L("Status", "状态")) {
                            StatusBadge(status, tone: status == "disabled" ? .bad : nil)
                        }
                        Button(on ? L("Disable DNSSEC", "关闭 DNSSEC") : L("Enable DNSSEC", "开启 DNSSEC")) {
                            Task {
                                await model.run(on ? L("DNSSEC disabled", "DNSSEC 已关闭") : L("DNSSEC enabled", "DNSSEC 已开启")) {
                                    try await model.client?.patch("/zones/\(zoneId)/dnssec", ["status": .string(on ? "disabled" : "active")])
                                }
                                await h.reload()
                            }
                        }
                    } footer: {
                        if on {
                            Text(L("Add the DS record below at your registrar.", "请在域名注册商处添加下面的 DS 记录。"))
                        }
                    }
                    if !d["ds"].isNull {
                        Section(L("DS record", "DS 记录")) {
                            Text(d["ds"].text ?? "").font(.callout.monospaced()).textSelection(.enabled)
                            Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(d["ds"].text ?? "") }
                        }
                    }
                    Section {
                        ForEach(["digest", "digest_type", "algorithm", "key_tag", "flags", "public_key", "modified_on"], id: \.self) { k in
                            if !d[k].isNull {
                                InfoRow(k, d[k].text, mono: true, copy: k == "digest" || k == "public_key")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .refreshable { await h.reload() }
            }
            .navigationTitle("DNSSEC")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

/// Zone-level DNS settings.
struct DNSSettingsSheet: View {
    let zoneId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var jsonItem: JSONItem?

    var body: some View {
        NavigationStack {
            QueryView("dns-settings:" + zoneId, fetch: { c in try await c.get("/zones/\(zoneId)/dns_settings") }) { d, h in
                Form {
                    Section {
                        ForEach(["flatten_all_cnames", "foundation_dns", "multi_provider", "secondary_overrides"], id: \.self) { k in
                            if let v = d[k].bool {
                                Toggle(k, isOn: Binding(get: { v }, set: { nv in
                                    Task {
                                        let result = await model.run(L("Saved", "已保存")) {
                                            try await model.client?.patch("/zones/\(zoneId)/dns_settings", [k: .bool(nv)])
                                        }
                                        if let response = result, let r = response { h.set(r) }
                                    }
                                }))
                            }
                        }
                        if !d["ns_ttl"].isNull { InfoRow("ns_ttl", d["ns_ttl"].text) }
                        if !d["zone_mode"].isNull { InfoRow("zone_mode", d["zone_mode"].text) }
                    }
                    Section {
                        Button(L("View all settings (JSON)", "查看全部设置（JSON）"), systemImage: "curlybraces") {
                            jsonItem = JSONItem(title: L("DNS settings", "DNS 设置"), json: d)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle(L("DNS settings", "DNS 设置"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
            }
            .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

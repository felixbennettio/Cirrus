import CirrusKit
import SwiftUI

struct CacheView: View {
    let zone: ZoneRef

    var body: some View {
        ZoneSettingsList(zoneId: zone.id, groups: [.caching]) {
            PurgeSection(zoneId: zone.id)
            CacheFeatures(zoneId: zone.id)
        }
        .navigationTitle(L("Caching", "缓存"))
        .toolbar { ZoneToolbar() }
    }
}

/// Purge by URL, host, tag, prefix, or everything.
private struct PurgeSection: View {
    let zoneId: String
    @Environment(AppModel.self) private var model
    @State private var mode = "files"
    @State private var input = ""
    @State private var confirmAll = false

    private var hint: String {
        switch mode {
        case "files": return "https://example.com/style.css\nhttps://example.com/app.js"
        case "hosts": return "www.example.com\nimages.example.com"
        case "tags": return "product-123\nheader"
        case "prefixes": return "www.example.com/blog/\nexample.com/assets/"
        default: return ""
        }
    }

    var body: some View {
        Section {
            Picker(L("Purge by", "清除方式"), selection: $mode) {
                Text(L("URLs", "URL")).tag("files")
                Text(L("Hostnames", "主机名")).tag("hosts")
                Text(L("Tags", "标签")).tag("tags")
                Text(L("Prefixes", "前缀")).tag("prefixes")
                Text(L("Everything", "全部")).tag("everything")
            }
            if mode != "everything" {
                TextField(hint, text: $input, axis: .vertical)
                    .plainInput()
                    .font(.callout.monospaced())
                    .lineLimit(3...10)
            }
            Button(L("Purge", "清除"), systemImage: "trash", role: mode == "everything" ? ButtonRole.destructive : nil) {
                if mode == "everything" { confirmAll = true } else { Task { await purge() } }
            }
        } header: {
            Text(L("Purge cache", "清除缓存"))
        } footer: {
            if mode != "everything" {
                Text(L("One per line (up to 30 per request on most plans)", "每行一个（多数套餐每次最多 30 个）"))
            }
        }
        .confirmationDialog(L("Purge everything?", "清除全部缓存？"), isPresented: $confirmAll, titleVisibility: .visible) {
            Button(L("Purge everything", "清除全部缓存"), role: .destructive) {
                Task {
                    await model.run(L("Purge requested", "已提交清除请求")) {
                        try await model.client?.post("/zones/\(zoneId)/purge_cache", ["purge_everything": true])
                    }
                }
            }
        } message: {
            Text(L("All cached content will be removed from every data center.", "所有数据中心的缓存内容都将被清除。"))
        }
    }

    private func purge() async {
        let items = input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        if items.isEmpty {
            model.feedback.show(L("Enter at least one value", "请至少输入一项"), error: true)
            return
        }
        let r = await model.run(L("Purge requested", "已提交清除请求")) {
            try await model.client?.post("/zones/\(zoneId)/purge_cache", [mode: .array(items.map(JSON.string))])
        }
        if r != nil { input = "" }
    }
}

/// Settings that live on their own endpoints (`{value: on|off}`).
private struct CacheFeatures: View {
    let zoneId: String

    var body: some View {
        Section(L("Cache features", "缓存功能")) {
            EndpointToggle(
                path: "/zones/\(zoneId)/argo/tiered_caching", title: L("Tiered Cache", "分层缓存"),
                subtitle: L("Use upper-tier data centers to reduce origin load", "使用上层数据中心减少回源"))
            EndpointToggle(
                path: "/zones/\(zoneId)/cache/tiered_cache_smart_topology_enable",
                title: L("Smart Tiered Cache topology", "智能分层缓存拓扑"),
                subtitle: L("Pick the best upper tier automatically", "自动选择最佳上层节点"))
            EndpointToggle(
                path: "/zones/\(zoneId)/cache/cache_reserve", title: L("Cache Reserve", "缓存储备"),
                subtitle: L("Persist cache in R2 (paid add-on)", "将缓存持久化到 R2（付费功能）"))
            EndpointToggle(
                path: "/zones/\(zoneId)/cache/regional_tiered_cache", title: L("Regional Tiered Cache", "区域分层缓存"),
                subtitle: L("Add a regional tier between lower and upper tiers", "在上下层之间增加区域层"))
            EndpointToggle(
                path: "/zones/\(zoneId)/argo/smart_routing", title: L("Argo Smart Routing", "Argo 智能路由"),
                subtitle: L("Route around congestion (paid)", "绕开网络拥塞（付费）"))
        }
    }
}

struct EndpointToggle: View {
    let path: String
    let title: String
    let subtitle: String
    @Environment(AppModel.self) private var model
    @State private var value: JSON?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        let available = value != nil && value?["editable"].bool != false
        let on = value?["value"].string == "on" || value?["value"].isTrue == true
        Toggle(
            isOn: Binding(get: { on }, set: { v in Task { await set(v) } })
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(available || value == nil && !failed ? subtitle : L("Not available on this plan / token", "当前套餐或 Token 不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!available || busy)
        .overlay(alignment: .trailing) {
            if value == nil && !failed { ProgressView().controlSize(.small).padding(.trailing, 60) }
        }
        .task(id: path) {
            do {
                value = try await model.client?.get(path)
            } catch {
                failed = true
            }
        }
    }

    private func set(_ on: Bool) async {
        busy = true
        defer { busy = false }
        let result = await model.run { try await model.client?.patch(path, ["value": .string(on ? "on" : "off")]) }
        if let response = result, let r = response { value = r }
    }
}

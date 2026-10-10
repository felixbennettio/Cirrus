import CirrusKit
import SwiftUI

struct DomainsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openScreen) private var openScreen
    @State private var query = ""
    @State private var status = "all"
    @State private var adding = false
    @State private var deleting: JSON?
    @State private var deleteConfirmation = ""

    private var filtered: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.zones.filter { z in
            if !q.isEmpty && !(z["name"].string ?? "").lowercased().contains(q) { return false }
            switch status {
            case "all": return true
            case "paused": return z["paused"].isTrue
            default: return z["status"].string == status
            }
        }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.self) { z in
                ZoneRow(zone: z) { action in
                    Task { await perform(action, z) }
                }
                .contentShape(.rect)
                .onTapGesture {
                    if let id = z["id"].string { model.setActiveZone(id) }
                    openScreen(.zoneOverview)
                }
            }
        }
        .overlay {
            if model.accountId == nil {
                EmptyState(title: L("No account", "无账户"), symbol: "person.crop.circle.badge.questionmark")
            } else if model.zones.isEmpty {
                if model.zonesLoading {
                    ProgressView()
                } else if let e = model.zonesError {
                    ErrorState(error: SimpleError(e)) { Task { await model.loadZones(force: true) } }
                } else {
                    EmptyState(
                        title: L("No domains", "没有域名"), symbol: "globe",
                        message: L("Add a domain to start.", "添加一个域名开始使用。"))
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: L("Search domains", "搜索域名"))
        .navigationTitle(L("Domains", "域名"))
        .refreshable { await model.loadZones(force: true) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("Status", "状态"), selection: $status) {
                        Text(L("All", "全部")).tag("all")
                        Text(L("Active", "已激活")).tag("active")
                        Text(L("Pending", "待激活")).tag("pending")
                        Text(L("Paused", "已暂停")).tag("paused")
                        Text(L("Moved", "已迁出")).tag("moved")
                    }
                } label: {
                    Label(L("Filter", "筛选"), systemImage: status == "all" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(L("Add domain", "添加域名"), systemImage: "plus") { adding = true }
                    .disabled(model.accountId == nil)
            }
        }
        .sheet(isPresented: $adding) { AddZoneSheet() }
        .alert(
            L("Delete domain?", "删除域名？"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { z in
            let name = z["name"].string ?? ""
            TextField(name, text: $deleteConfirmation).plainInput()
            Button(L("Delete", "删除"), role: .destructive) {
                if deleteConfirmation.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                    Task { await delete(z) }
                } else {
                    model.feedback.show(L("The name did not match; nothing was deleted.", "域名不匹配，未删除。"), error: true)
                }
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: { z in
            let name = z["name"].string ?? ""
            Text(
                L(
                    "This removes \(name) and all of its DNS records and settings from Cloudflare. Type the domain name to confirm.",
                    "这会从 Cloudflare 删除 \(name) 及其所有 DNS 记录和设置。请输入域名以确认。"))
        }
    }

    enum Action { case pause, check, copyID, delete }

    private func perform(_ action: Action, _ z: JSON) async {
        guard let client = model.client, let id = z["id"].string else { return }
        switch action {
        case .pause:
            let paused = z["paused"].isTrue
            await model.run(paused ? L("Resumed", "已恢复") : L("Paused", "已暂停")) {
                try await client.patch("/zones/\(id)", ["paused": .bool(!paused)])
            }
            await model.loadZones(force: true)
        case .check:
            await model.run(L("Activation check requested", "已请求重新检查激活状态")) {
                try await client.put("/zones/\(id)/activation_check")
            }
        case .copyID:
            Clipboard.copy(id)
            model.feedback.show(L("Copied", "已复制"))
        case .delete:
            deleteConfirmation = ""
            deleting = z
        }
    }

    private func delete(_ z: JSON) async {
        guard let client = model.client, let id = z["id"].string else { return }
        await model.run(L("Deleted", "已删除")) { try await client.delete("/zones/\(id)") }
        await model.loadZones(force: true)
    }
}

struct ZoneRow: View {
    let zone: JSON
    let action: (DomainsView.Action) -> Void

    var body: some View {
        let paused = zone["paused"].isTrue
        HStack(spacing: 12) {
            Image(systemName: "globe").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(zone["name"].string ?? "").fontWeight(.medium)
                Text(
                    [
                        zone["plan"]["name"].string, zone["type"].string,
                        zone["created_on"].isNull ? nil : Format.date(zone["created_on"], withTime: false),
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ZoneStatusBadge(zone: zone)
            Menu {
                Button(
                    paused ? L("Resume Cloudflare", "恢复 Cloudflare") : L("Pause Cloudflare", "暂停 Cloudflare"),
                    systemImage: paused ? "play.circle" : "pause.circle"
                ) { action(.pause) }
                if zone["status"].string == "pending" {
                    Button(L("Re-check nameservers", "重新检查名称服务器"), systemImage: "arrow.clockwise") { action(.check) }
                }
                Button(L("Copy zone ID", "复制 Zone ID"), systemImage: "doc.on.doc") { action(.copyID) }
                Divider()
                Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { action(.delete) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .swipeActions(edge: .trailing) {
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { action(.delete) }
        }
    }
}

/// An error made from a message.
struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Adds a zone to the current account.
struct AddZoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "full"
    @State private var jumpStart = true
    @State private var busy = false
    @State private var nameservers: [String] = []
    @State private var added = ""

    var body: some View {
        NavigationStack {
            Form {
                if nameservers.isEmpty {
                    Section {
                        TextField(L("Domain", "域名"), text: $name, prompt: Text("example.com")).plainInput()
                        Picker(L("Setup", "接入方式"), selection: $type) {
                            Text(L("Full (change nameservers)", "完全接入（修改 NS）")).tag("full")
                            Text(L("Partial (CNAME setup)", "部分接入（CNAME）")).tag("partial")
                            Text(L("Secondary DNS", "辅助 DNS")).tag("secondary")
                        }
                        Toggle(L("Scan existing DNS records", "扫描现有 DNS 记录"), isOn: $jumpStart)
                    }
                } else {
                    Section {
                        ForEach(Array(nameservers.enumerated()), id: \.offset) { i, ns in
                            InfoRow("NS \(i + 1)", ns, mono: true, copy: true)
                        }
                    } header: {
                        Text(L("Update your nameservers", "请修改名称服务器"))
                    } footer: {
                        Text(L("At your registrar, replace the nameservers of \(added) with these.", "请在域名注册商处将 \(added) 的名称服务器改为以上地址。"))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Add a domain", "添加域名"))
            .inlineTitle()
            .toolbar {
                if nameservers.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Add", "添加")) { Task { await add() } }
                            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }

    private func add() async {
        guard let client = model.client, let accountId = model.accountId else { return }
        let domain = name.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        defer { busy = false }
        let body: JSON = ["name": .string(domain), "account": ["id": .string(accountId)], "type": .string(type), "jump_start": .bool(jumpStart)]
        guard let zone = await model.run(L("Domain added", "域名已添加"), { try await client.post("/zones", body) }) else { return }
        await model.loadZones(force: true)
        if let id = zone["id"].string { model.setActiveZone(id) }
        let ns = zone["name_servers"].strings
        if ns.isEmpty {
            dismiss()
        } else {
            added = domain
            nameservers = ns
        }
    }
}

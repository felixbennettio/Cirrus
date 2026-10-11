import CirrusKit
import SwiftUI

struct EmailRoutingView: View {
    let zone: ZoneRef

    enum Part: String, CaseIterable, Identifiable {
        case rules, destinations, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rules: return L("Routing rules", "路由规则")
            case .destinations: return L("Destination addresses", "目标地址")
            case .settings: return L("Settings", "设置")
            }
        }
    }

    @State private var part = Part.rules

    var body: some View {
        VStack(spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
            Group {
                switch part {
                case .rules: EmailRules(zone: zone)
                case .destinations: AccountRequired { EmailDestinations(accountId: $0) }
                case .settings: EmailSettings(zone: zone)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(L("Email Routing", "邮件路由"))
        .inlineTitle()
        .toolbar { ZoneToolbar() }
    }
}

/// The rule being edited (nil for a new one); [catchAll] for the catch-all rule.
struct EmailRuleDraft: Identifiable {
    let id = UUID()
    var rule: JSON?
    var catchAll = false
}

private struct EmailRules: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var editing: EmailRuleDraft?
    @State private var confirm: ConfirmItem?

    private var base: String { "/zones/\(zone.id)/email/routing/rules" }

    var body: some View {
        QueryView("email-rules:" + zone.id, fetch: { c in try await c.list(base, perPage: 50) }) { rules, h in
            let custom = rules.filter { !EmailRouting.isCatchAll($0) }
            List {
                Section {
                    ForEach(custom, id: \.self) { r in
                        let id = r["id"].text ?? r["tag"].text ?? ""
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(EmailRouting.describe(matchers: r["matchers"])).fontWeight(.medium)
                                Text(
                                    EmailRouting.describe(actions: r["actions"])
                                        + ((r["name"].string ?? "").isEmpty ? "" : " · " + (r["name"].string ?? ""))
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { r["enabled"].bool != false }, set: { v in
                                Task {
                                    var body = r.setting("enabled", to: .bool(v)).object ?? [:]
                                    body["id"] = nil
                                    body["tag"] = nil
                                    await model.run { try await model.client?.put("\(base)/\(id)", .object(body)) }
                                    await h.reload()
                                }
                            }))
                            .labelsHidden()
                        }
                        .contentShape(.rect)
                        .onTapGesture { editing = EmailRuleDraft(rule: r) }
                        .swipeActions {
                            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(
                                    title: L("Delete rule?", "删除规则？"), message: EmailRouting.describe(matchers: r["matchers"]),
                                    button: L("Delete", "删除")
                                ) {
                                    await model.run { try await model.client?.delete("\(base)/\(id)") }
                                    await h.reload()
                                }
                            }
                        }
                    }
                } header: {
                    Text(L("\(custom.count) custom addresses", "\(custom.count) 个自定义地址"))
                }
            }
            .overlay { if custom.isEmpty { EmptyState(title: L("No routing rules", "没有路由规则"), symbol: "at") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create address", "创建地址"), systemImage: "plus") { editing = EmailRuleDraft(rule: nil) }
                }
            }
            .sheet(item: $editing) { d in
                EmailRuleSheet(zoneName: zone.name, draft: d) { body in
                    let r = await model.run(L("Saved", "已保存")) { () -> JSON? in
                        if let rule = d.rule {
                            return try await model.client?.put("\(base)/\(rule["id"].text ?? rule["tag"].text ?? "")", body)
                        }
                        return try await model.client?.post(base, body)
                    }
                    if r != nil { await h.reload() }
                    return r != nil
                }
            }
        }
        .confirm($confirm)
    }
}

struct EmailRuleSheet: View {
    let zoneName: String
    let draft: EmailRuleDraft
    let save: (JSON) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var local = ""
    @State private var type = "forward"
    @State private var value = ""
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if !draft.catchAll {
                    Section {
                        HStack {
                            TextField(L("Custom address", "自定义地址"), text: $local).plainInput()
                            Text("@" + zoneName).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Picker(L("Action", "动作"), selection: $type) {
                        Text(L("Send to an email", "转发到邮箱")).tag("forward")
                        Text(L("Send to a Worker", "交给 Worker 处理")).tag("worker")
                        Text(L("Drop", "丢弃")).tag("drop")
                    }
                    if type != "drop" {
                        TextField(type == "forward" ? L("Destination email(s)", "目标邮箱") : L("Worker name", "Worker 名称"), text: $value)
                            .plainInput()
                    }
                } footer: {
                    if type == "forward" { Text(L("Must be a verified destination address", "必须是已验证的目标地址")) }
                }
                Section {
                    TextField(L("Name (optional)", "名称（可选）"), text: $name)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.catchAll ? L("Catch-all address", "全部捕获地址") : L("Custom address", "自定义地址"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) {
                        let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let body = EmailRouting.ruleBody(
                            local: draft.catchAll ? nil : local.trimmingCharacters(in: .whitespaces), zone: zoneName, type: type,
                            values: values, name: name.trimmingCharacters(in: .whitespaces),
                            enabled: draft.rule?["enabled"].bool ?? true)
                        Task { if await save(body) { dismiss() } }
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let r = draft.rule
                local = (r?["matchers"][0]["value"].string ?? "").split(separator: "@").first.map(String.init) ?? ""
                type = r?["actions"][0]["type"].string ?? "forward"
                value = r?["actions"][0]["value"].strings.joined(separator: ", ") ?? ""
                name = r?["name"].string ?? ""
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

private struct EmailDestinations: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    private var base: String { "/accounts/\(accountId)/email/routing/addresses" }

    var body: some View {
        QueryView("email-dest:" + accountId, fetch: { c in try await c.list(base, perPage: 50) }) { list, h in
            List {
                Section {
                    ForEach(list, id: \.self) { a in
                        let verified = !a["verified"].isNull
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a["email"].text ?? "")
                                Text(verified ? L("Verified", "已验证") + " " + Format.date(a["verified"]) : L("Pending verification", "等待验证"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(verified ? "verified" : "pending", tone: verified ? .good : .warn)
                        }
                        .swipeActions {
                            Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(title: L("Remove address?", "移除地址？"), message: a["email"].text, button: L("Remove", "移除")) {
                                    await model.run { try await model.client?.delete("\(base)/\(a["id"].text ?? a["tag"].text ?? "")") }
                                    await h.reload()
                                }
                            }
                        }
                    }
                } footer: {
                    Text(L("Addresses must be verified before use.", "目标地址需验证后才能使用。"))
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Add", "添加"), systemImage: "plus") {
                        prompt = TextPrompt(title: L("Destination address", "目标地址"), placeholder: "me@example.com", confirm: L("Add", "添加")) { e in
                            await model.run(L("Verification email sent", "验证邮件已发送")) {
                                try await model.client?.post(base, ["email": .string(e.trimmingCharacters(in: .whitespaces))])
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

private struct EmailSettings: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var editing: EmailRuleDraft?

    struct Info {
        var settings: JSON
        var dns: [JSON]
        var catchAll: JSON?
    }

    var body: some View {
        let base = "/zones/\(zone.id)/email/routing"
        QueryView(
            "email-settings:" + zone.id,
            fetch: { (c: CFClient) async throws -> Info in
                async let s = c.get(base)
                async let d = try? c.get(base + "/dns")
                async let catchAll = try? c.get(base + "/rules/catch_all")
                let dns = await d ?? .null
                var records: [JSON] = dns.object == nil ? [] : [dns]
                if let a = dns["records"].array { records = a }
                if let a = dns.array { records = a }
                return Info(settings: try await s, dns: records, catchAll: await catchAll)
            }
        ) { info, h in
            let enabled = info.settings["enabled"].isTrue
            Form {
                Section {
                    LabeledContent(L("Status", "状态")) {
                        StatusBadge(info.settings["status"].string ?? (enabled ? "enabled" : "disabled"), tone: enabled ? .good : .warn)
                    }
                    Toggle(isOn: Binding(get: { enabled }, set: { v in
                        Task {
                            await model.run { try await model.client?.post(base + (v ? "/enable" : "/disable"), JSON.object([:])) }
                            await h.reload()
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Email Routing enabled", "启用邮件路由"))
                            Text(L("Adds the required MX and TXT records.", "会自动添加所需的 MX 和 TXT 记录。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(L("Catch-all address", "全部捕获地址")) {
                    HStack {
                        Text(EmailRouting.describe(actions: info.catchAll?["actions"] ?? .null))
                        Spacer()
                        Toggle("", isOn: Binding(get: { info.catchAll?["enabled"].isTrue ?? false }, set: { v in
                            guard let c = info.catchAll else { return }
                            Task {
                                await model.run {
                                    try await model.client?.put(
                                        base + "/rules/catch_all", ["enabled": .bool(v), "matchers": c["matchers"], "actions": c["actions"]])
                                }
                                await h.reload()
                            }
                        }))
                        .labelsHidden()
                        .disabled(info.catchAll == nil)
                    }
                    Button(L("Edit", "编辑"), systemImage: "pencil") { editing = EmailRuleDraft(rule: info.catchAll, catchAll: true) }
                }
                Section(L("Required DNS records", "所需 DNS 记录")) {
                    if info.dns.isEmpty { Text(L("No records reported", "无记录")).foregroundStyle(.secondary) }
                    ForEach(info.dns, id: \.self) { r in
                        InfoRow(
                            "\(r["type"].text ?? "") \(r["name"].text ?? "")",
                            (r["priority"].isNull ? "" : (r["priority"].text ?? "") + " ") + (r["content"].text ?? ""), mono: true, copy: true)
                    }
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(item: $editing) { d in
                EmailRuleSheet(zoneName: zone.name, draft: d) { body in
                    let r = await model.run(L("Saved", "已保存")) { try await model.client?.put(base + "/rules/catch_all", body) }
                    if r != nil { await h.reload() }
                    return r != nil
                }
            }
        }
    }
}

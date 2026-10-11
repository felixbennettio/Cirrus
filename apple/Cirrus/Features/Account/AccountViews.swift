import CirrusKit
import SwiftUI

// MARK: Members

struct MembersView: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var editing: MemberDraft?
    @State private var confirm: ConfirmItem?
    @State private var json: JSONItem?

    struct MemberDraft: Identifiable {
        let id = UUID()
        var member: JSON?
    }

    struct Info {
        var members: [JSON]
        var roles: [JSON]
    }

    private var base: String { "/accounts/\(accountId)/members" }

    var body: some View {
        QueryView(
            "members:" + accountId,
            fetch: { (c: CFClient) async throws -> Info in
                async let members = c.list(base, perPage: 50)
                async let roles = try? c.list("/accounts/\(accountId)/roles", perPage: 50)
                return Info(members: try await members, roles: await roles ?? [])
            }
        ) { d, h in
            List(d.members, id: \.self) { m in
                let user = m["user"]
                let name = [user["first_name"].string, user["last_name"].string].compactMap { $0 }.joined(separator: " ")
                let roles = m["roles"].items.compactMap { $0["name"].string }.joined(separator: ", ")
                let email = user["email"].text ?? m["email"].text ?? m["id"].text ?? ""
                HStack(spacing: 12) {
                    Text(String(email.prefix(1)).uppercased())
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.15), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email)
                        Text([name.isEmpty ? nil : name, roles.isEmpty ? nil : roles, user["two_factor_authentication_enabled"].isTrue ? "2FA ✓" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    StatusBadge(m["status"].text ?? "", tone: StatusTone.of(m["status"].string == "accepted" ? "active" : m["status"].string))
                }
                .contentShape(.rect)
                .onTapGesture { editing = MemberDraft(member: m) }
                .contextMenu {
                    Button(L("Edit roles", "编辑角色"), systemImage: "person.badge.key") { editing = MemberDraft(member: m) }
                    Button(L("Details", "详情"), systemImage: "curlybraces") { json = JSONItem(title: email, json: m) }
                    Divider()
                    Button(L("Remove", "移除"), systemImage: "person.badge.minus", role: .destructive) { askRemove(m, email, h) }
                }
                .swipeActions {
                    Button(L("Remove", "移除"), systemImage: "person.badge.minus", role: .destructive) { askRemove(m, email, h) }
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Invite", "邀请"), systemImage: "person.badge.plus") { editing = MemberDraft(member: nil) }
                }
            }
            .sheet(item: $editing) { e in
                MemberRolesSheet(member: e.member, roles: d.roles) { email, ids in
                    let r = await model.run(e.member == nil ? L("Invitation sent", "邀请已发送") : L("Roles updated", "角色已更新")) { () -> JSON? in
                        if let m = e.member {
                            return try await model.client?.put("\(base)/\(m["id"].text ?? "")", ["roles": .array(ids.map { ["id": .string($0)] })])
                        }
                        return try await model.client?.post(base, ["email": .string(email), "roles": .array(ids.map(JSON.string)), "status": "pending"])
                    }
                    if r != nil { await h.reload() }
                    return r != nil
                }
            }
        }
        .navigationTitle(L("Members", "成员"))
        .confirm($confirm)
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func askRemove(_ m: JSON, _ email: String, _ h: QueryHandle<Info>) {
        confirm = ConfirmItem(title: L("Remove member?", "移除成员？"), message: email, button: L("Remove", "移除")) {
            await model.run(L("Removed", "已移除")) { try await model.client?.delete("\(base)/\(m["id"].text ?? "")") }
            await h.reload()
        }
    }
}

private struct MemberRolesSheet: View {
    let member: JSON?
    let roles: [JSON]
    let save: (String, [String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var selected = Set<String>()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if member == nil {
                    Section { TextField(L("Email", "邮箱"), text: $email).plainInput().emailInput() }
                }
                Section(L("Roles", "角色")) {
                    ForEach(roles, id: \.self) { r in
                        let id = r["id"].text ?? ""
                        Toggle(isOn: Binding(get: { selected.contains(id) }, set: { v in
                            if v { selected.insert(id) } else { selected.remove(id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r["name"].text ?? id)
                                if let d = r["description"].string { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(member == nil ? L("Invite member", "邀请成员") : L("Edit roles", "编辑角色"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(member == nil ? L("Invite", "邀请") : L("Save", "保存")) {
                        Task { if await save(email.trimmingCharacters(in: .whitespaces), Array(selected)) { dismiss() } }
                    }
                    .disabled(selected.isEmpty || (member == nil && email.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                selected = Set(member?["roles"].items.compactMap { $0["id"].text } ?? [])
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}

// MARK: API tokens

struct TokensView: View {
    @Environment(AppModel.self) private var model
    @State private var accountTokens = false

    var body: some View {
        VStack(spacing: 0) {
            if model.accountId != nil {
                Picker("", selection: $accountTokens) {
                    Text(L("User tokens", "用户 Token")).tag(false)
                    Text(L("Account tokens", "账户 Token")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
            }
            if accountTokens, let id = model.accountId {
                TokenList(base: "/accounts/\(id)/tokens", account: true).id("account")
            } else {
                TokenList(base: "/user/tokens", account: false).id("user")
            }
        }
        .navigationTitle(L("API tokens", "API Token"))
    }
}

private struct TokenList: View {
    let base: String
    let account: Bool
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var confirm: ConfirmItem?
    @State private var prompt: TextPrompt?
    @State private var secrets: SecretItem?
    @State private var json: JSONItem?

    var body: some View {
        QueryView("tokens:" + base, fetch: { c in try await c.list(base, perPage: 50) }) { tokens, h in
            List {
                Section {
                    ForEach(tokens, id: \.self) { t in row(t, h) }
                } footer: {
                    Text(account ? L("Owned by the account; survive member changes.", "归属账户，不受成员变动影响。") : L("Owned by your user.", "归属当前用户。"))
                }
            }
            .overlay { if tokens.isEmpty { EmptyState(title: L("No tokens visible", "没有可见的 Token"), symbol: "key") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create token", "创建 Token"), systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                CreateTokenSheet(base: base) { result in
                    await h.reload()
                    secrets = SecretItem(
                        title: L("Token created", "Token 已创建"),
                        values: [("token", result["value"].text ?? ""), ("id", result["id"].text ?? "")])
                }
            }
        }
        .confirm($confirm)
        .textPrompt($prompt)
        .sheet(item: $secrets) { SecretsSheet(item: $0) }
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func row(_ t: JSON, _ h: QueryHandle<[JSON]>) -> some View {
        var perms: [String] = []
        for p in t["policies"].items {
            for g in p["permission_groups"].items {
                let n = g["name"].text ?? g["id"].text ?? ""
                if !perms.contains(n) { perms.append(n) }
            }
        }
        let id = t["id"].text ?? ""
        let name = t["name"].text ?? ""
        var parts: [String] = []
        if !perms.isEmpty { parts.append(perms.prefix(4).joined(separator: ", ") + (perms.count > 4 ? " +\(perms.count - 4)" : "")) }
        if !t["expires_on"].isNull { parts.append(L("expires", "过期") + " " + Format.date(t["expires_on"], withTime: false)) }
        if !t["last_used_on"].isNull { parts.append(L("used", "最近使用") + " " + Format.relative(t["last_used_on"])) }
        let active = t["status"].string == "active"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            StatusBadge(t["status"].text ?? "")
        }
        .contextMenu {
            Button(L("Roll value", "轮换值"), systemImage: "arrow.triangle.2.circlepath") {
                confirm = ConfirmItem(
                    title: L("Roll token?", "轮换 Token？"), message: L("The current value stops working immediately.", "当前值会立即失效。"),
                    button: L("Roll", "轮换")
                ) {
                    let r = await model.run { try await model.client?.put("\(base)/\(id)/value", JSON.object([:])) }
                    if let o = r, let v = o?.string {
                        secrets = SecretItem(title: L("New token value", "新的 Token 值"), values: [("token", v)])
                    }
                }
            }
            Button(active ? L("Disable", "停用") : L("Enable", "启用"), systemImage: active ? "pause.circle" : "play.circle") {
                Task {
                    var body = t.object ?? [:]
                    for k in ["id", "issued_on", "modified_on", "last_used_on"] { body[k] = nil }
                    body["status"] = .string(active ? "disabled" : "active")
                    await model.run { try await model.client?.put("\(base)/\(id)", .object(body)) }
                    await h.reload()
                }
            }
            Button(L("Details", "详情"), systemImage: "curlybraces") { json = JSONItem(title: name, json: t) }
            Divider()
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                prompt = typedDelete(L("Delete token?", "删除 Token？"), name: name, message: name, feedback: model.feedback) {
                    await model.run(L("Deleted", "已删除")) { try await model.client?.delete("\(base)/\(id)") }
                    await h.reload()
                }
            }
        }
    }
}

private struct CreateTokenSheet: View {
    let base: String
    let created: (JSON) async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Cirrus token"
    @State private var ips = ""
    @State private var search = ""
    @State private var selected = Set<String>()
    @State private var currentZoneOnly = false
    @State private var days = 0
    @State private var busy = false

    var body: some View {
        NavigationStack {
            QueryView("perm-groups:" + base, fetch: { c in try await c.list(base + "/permission_groups", paginate: false) }) { groups, _ in
                let q = search.trimmingCharacters(in: .whitespaces).lowercased()
                let filtered = groups.filter { q.isEmpty || ($0["name"].text ?? "").lowercased().contains(q) }
                    .sorted { ($0["name"].text ?? "") < ($1["name"].text ?? "") }
                Form {
                    Section {
                        TextField(L("Token name", "Token 名称"), text: $name)
                        Picker(L("Zone resources", "域名资源"), selection: $currentZoneOnly) {
                            Text(L("All zones in this account", "该账户下所有域名")).tag(false)
                            Text(L("Current zone only", "仅当前域名")).tag(true)
                        }
                        Picker(L("Expires", "有效期"), selection: $days) {
                            Text(L("Never", "永不过期")).tag(0)
                            Text(L("1 day", "1 天")).tag(1)
                            Text(L("7 days", "7 天")).tag(7)
                            Text(L("30 days", "30 天")).tag(30)
                            Text(L("90 days", "90 天")).tag(90)
                            Text(L("1 year", "1 年")).tag(365)
                        }
                        TextField(L("Client IP filter (optional)", "客户端 IP 限制（可选）"), text: $ips, prompt: Text("203.0.113.0/24, 2001:db8::/32"))
                            .plainInput()
                    }
                    ForEach(["account", "zone", "user"], id: \.self) { scope in
                        let list = filtered.filter { APITokens.scope(of: $0) == scope }
                        if !list.isEmpty {
                            Section(scope == "account" ? L("Account", "账户") : scope == "zone" ? L("Zone", "域名") : L("User", "用户")) {
                                ForEach(list, id: \.self) { g in
                                    let id = g["id"].text ?? ""
                                    Toggle(g["name"].text ?? id, isOn: Binding(get: { selected.contains(id) }, set: { v in
                                        if v { selected.insert(id) } else { selected.remove(id) }
                                    }))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .searchable(text: $search, prompt: L("Search permissions", "搜索权限"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Create", "创建")) { Task { await create(groups) } }.disabled(selected.isEmpty || busy)
                    }
                }
            }
            .navigationTitle(L("Create API token", "创建 API Token") + (selected.isEmpty ? "" : " (\(selected.count))"))
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } } }
        }
        .frame(minWidth: 620, minHeight: 700)
    }

    private func create(_ groups: [JSON]) async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        let chosen = groups.filter { selected.contains($0["id"].text ?? "") }
        var userId: String?
        if chosen.contains(where: { APITokens.scope(of: $0) == "user" }) { userId = (try? await client.get("/user"))?["id"].text }
        let policies = APITokens.policies(
            groups: chosen, accountId: model.accountId, zoneId: model.zoneId, currentZoneOnly: currentZoneOnly, userId: userId)
        var body: [String: JSON] = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "policies": .array(policies)]
        let ipList = ips.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if !ipList.isEmpty { body["condition"] = ["request_ip": ["in": .array(ipList.map(JSON.string))]] }
        if days > 0 { body["expires_on"] = .string(APITokens.expiry(days: days)) }
        let r = await model.run { try await client.post(base, .object(body)) }
        if let result = r {
            dismiss()
            try? await Task.sleep(for: .milliseconds(500))
            await created(result)
        }
    }
}

// MARK: Audit log

struct AuditLogView: View {
    let accountId: String
    @State private var days = 7
    @State private var query = ""
    @State private var json: JSONItem?

    var body: some View {
        QueryView(
            "audit:\(accountId):\(days)",
            fetch: { c in
                try await c.list(
                    "/accounts/\(accountId)/audit_logs",
                    query: ["direction": "desc", "since": ISODate.format(Date().addingTimeInterval(-Double(days) * 86400))], perPage: 100,
                    maxItems: 1000)
            }
        ) { logs, h in
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = q.isEmpty ? logs : logs.filter { $0.compactString.lowercased().contains(q) }
            List(Array(shown.enumerated()), id: \.offset) { _, l in
                let ok = l["action"]["result"].bool != false
                HStack(spacing: 12) {
                    Image(systemName: ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(ok ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(l["action"]["type"].text ?? "") · \(l["resource"]["type"].text ?? "")").lineLimit(1)
                        Text("\(l["actor"]["email"].text ?? l["actor"]["type"].text ?? "") · \(l["actor"]["ip"].text ?? "") · \(Format.date(l["when"]))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { json = JSONItem(title: l["action"]["type"].text ?? "Event", json: l) }
            }
            .overlay { if shown.isEmpty { EmptyState(title: L("No events", "没有事件"), symbol: "clock.arrow.circlepath") } }
            .searchable(text: $query, prompt: L("Filter by actor, action, resource", "按操作者、动作、资源过滤"))
            .refreshable { await h.reload() }
        }
        .id(days)
        .navigationTitle(L("Audit log", "审计日志"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L("Period", "时间段"), selection: $days) {
                    Text("24h").tag(1)
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
            }
        }
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

// MARK: Lists

struct ListsView: View {
    let accountId: String
    @State private var redirects = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $redirects) {
                Text(L("Lists", "列表")).tag(false)
                Text(L("Bulk redirect rules", "批量重定向规则")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            if redirects {
                RulesetPhaseView(phase: Rules.bulkRedirects, basePath: "/accounts/\(accountId)")
            } else {
                ListsList(accountId: accountId)
            }
        }
        .navigationTitle(L("Lists", "列表"))
    }
}

private struct ListsList: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var prompt: TextPrompt?

    var body: some View {
        QueryView("lists:" + accountId, fetch: { c in try await c.list(RuleLists.path(accountId), paginate: false) }) { lists, h in
            List {
                Section {
                    ForEach(lists, id: \.self) { l in
                        let name = l["name"].text ?? ""
                        NavigationLink {
                            ListItemsView(accountId: accountId, listId: l["id"].text ?? "", kind: l["kind"].string ?? "ip", name: name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("$" + name).font(.body.monospaced())
                                Text(
                                    "\(RuleLists.title(of: l["kind"].string ?? "")) · \(l["num_items"].text ?? "0") \(L("items", "项"))"
                                        + ((l["description"].string ?? "").isEmpty ? "" : " · " + (l["description"].string ?? ""))
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                                prompt = typedDelete(
                                    L("Delete list?", "删除列表？"), name: name,
                                    message: L("Rules referencing it must be removed first.", "需先删除引用该列表的规则。"), feedback: model.feedback
                                ) {
                                    await model.run(L("Deleted", "已删除")) { try await model.client?.delete("\(RuleLists.path(accountId))/\(l["id"].text ?? "")") }
                                    await h.reload()
                                }
                            }
                        }
                    }
                } footer: {
                    Text(L("Reference lists in expressions with $list_name.", "在表达式中使用 $list_name 引用列表。"))
                }
            }
            .overlay { if lists.isEmpty { EmptyState(title: L("No lists", "没有列表"), symbol: "list.bullet.rectangle") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create list", "创建列表"), systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                CreateListSheet { body in
                    let r = await model.run(L("List created", "列表已创建")) { try await model.client?.post(RuleLists.path(accountId), body) }
                    if r != nil { await h.reload() }
                    return r != nil
                }
            }
        }
        .textPrompt($prompt)
    }
}

private struct CreateListSheet: View {
    let save: (JSON) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "ip"
    @State private var desc = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name", "名称"), text: $name).plainInput()
                } footer: {
                    Text(L("Lowercase letters, numbers and underscores", "小写字母、数字和下划线"))
                }
                Picker(L("Type", "类型"), selection: $kind) {
                    ForEach(RuleLists.kinds, id: \.kind) { Text($0.title.text).tag($0.kind) }
                }
                TextField(L("Description", "描述"), text: $desc)
            }
            .formStyle(.grouped)
            .navigationTitle(L("Create list", "创建列表"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Create", "创建")) {
                        let body: JSON = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "kind": .string(kind), "description": .string(desc.trimmingCharacters(in: .whitespaces))]
                        Task { if await save(body) { dismiss() } }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}

private struct ListItemsView: View {
    let accountId: String
    let listId: String
    let kind: String
    let name: String
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding: String?

    private var base: String { "\(RuleLists.path(accountId))/\(listId)/items" }

    var body: some View {
        QueryView("list-items:" + base, fetch: { c in try await c.list(base, perPage: 500, maxItems: 100_000, cursorPagination: true) }) { items, h in
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = q.isEmpty ? items : items.filter { RuleLists.label($0, kind: kind).lowercased().contains(q) || ($0["comment"].text ?? "").lowercased().contains(q) }
            List(shown, id: \.self) { it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(RuleLists.label(it, kind: kind)).font(.callout.monospaced())
                    Text([it["comment"].string, Format.date(it["created_on"])].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                        Task {
                            await model.run { try await model.client?.delete(base, ["items": [["id": it["id"]]]]) }
                            try? await Task.sleep(for: .seconds(1))
                            await h.reload()
                        }
                    }
                }
            }
            .searchable(text: $query)
            .refreshable { await h.reload() }
            .sheet(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
                JSONEditorSheet(title: L("One item per line", "每行一个条目"), text: adding ?? "") { text in
                    let parsed = text.split(whereSeparator: \.isNewline).compactMap { RuleLists.parse(String($0), kind: kind) }
                    guard !parsed.isEmpty else { return false }
                    let r = await model.run(L("Items queued (applied asynchronously)", "条目已提交（异步生效）")) {
                        try await model.client?.post(base, .array(parsed))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    await h.reload()
                    return r != nil
                }
            }
        }
        .navigationTitle("$" + name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Add items", "添加条目"), systemImage: "plus") { adding = "" }
            }
        }
    }
}

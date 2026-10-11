import CirrusKit
import SwiftUI

/// The rules of one phase entry point (zone or account level).
struct RulesetPhaseView: View {
    let phase: RulePhase
    /// `/zones/{id}` or `/accounts/{id}`.
    let basePath: String
    @Environment(AppModel.self) private var model
    @State private var editing: RuleDraft?
    @State private var confirm: ConfirmItem?
    @State private var json: JSONItem?

    struct RuleDraft: Identifiable {
        let id = UUID()
        var rule: JSON?
    }

    private var entry: String { Rules.entrypoint(basePath, phase.phase) }

    var body: some View {
        QueryView(
            "ruleset:" + entry,
            fetch: { (c: CFClient) async throws -> JSON in
                do {
                    return try await c.get(entry)
                } catch let e as CFAPIError where e.isNotFound {
                    // No entry point yet: the phase has no rules.
                    return .null
                }
            }
        ) { ruleset, h in
            let rules = ruleset["rules"].items
            List {
                Section {
                    ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                        ruleRow(i, rule, ruleset, h)
                    }
                    .onMove { from, to in
                        guard let f = from.first else { return }
                        Task { await move(ruleset, from: f, to: to > f ? to - 1 : to, h) }
                    }
                } header: {
                    if let d = phase.description?.text { Text(d) }
                } footer: {
                    if !rules.isEmpty { Text(L("Rules run top to bottom.", "规则按从上到下的顺序执行。")) }
                }
            }
            .overlay {
                if rules.isEmpty {
                    EmptyState(
                        title: L("No rules in this phase", "该阶段还没有规则"), symbol: phase.symbol,
                        message: L("Rules run top to bottom.", "规则按从上到下的顺序执行。"))
                }
            }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !ruleset.isNull {
                        Button("JSON", systemImage: "curlybraces") { json = JSONItem(title: phase.title.text, json: ruleset) }
                    }
                    Button(L("Add rule", "添加规则"), systemImage: "plus") { editing = RuleDraft(rule: nil) }
                }
            }
            .sheet(item: $editing) { d in
                RuleEditorSheet(phase: phase, rule: d.rule) { body in await save(body, rule: d.rule, ruleset, h) }
            }
        }
        .confirm($confirm)
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func ruleRow(_ i: Int, _ rule: JSON, _ ruleset: JSON, _ h: QueryHandle<JSON>) -> some View {
        let enabled = rule["enabled"].bool != false
        let desc = rule["description"].string.flatMap { $0.isEmpty ? nil : $0 } ?? L("(no description)", "（无描述）")
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(i + 1). " + desc).fontWeight(.medium).lineLimit(1)
                    StatusBadge(rule["action"].string ?? "", tone: Rules.actionTone(rule["action"].string))
                }
                Text(rule["expression"].string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { enabled }, set: { v in Task { await toggle(ruleset, rule, v, h) } }))
                .labelsHidden()
        }
        .contentShape(.rect)
        .onTapGesture { editing = RuleDraft(rule: rule) }
        .contextMenu {
            Button(L("Edit", "编辑"), systemImage: "pencil") { editing = RuleDraft(rule: rule) }
            Button(L("View JSON", "查看 JSON"), systemImage: "curlybraces") { json = JSONItem(title: desc, json: rule) }
            if i > 0 {
                Button(L("Move up", "上移"), systemImage: "arrow.up") { Task { await move(ruleset, from: i, to: i - 1, h) } }
            }
            if i < ruleset["rules"].items.count - 1 {
                Button(L("Move down", "下移"), systemImage: "arrow.down") { Task { await move(ruleset, from: i, to: i + 1, h) } }
            }
            Divider()
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete(ruleset, rule, h) }
        }
        .swipeActions {
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete(ruleset, rule, h) }
        }
    }

    private func rulePath(_ ruleset: JSON, _ rule: JSON? = nil) -> String {
        var p = "\(basePath)/rulesets/\(ruleset["id"].text ?? "")/rules"
        if let id = rule?["id"].text { p += "/" + id }
        return p
    }

    private func save(_ body: JSON, rule: JSON?, _ ruleset: JSON, _ h: QueryHandle<JSON>) async -> Bool {
        let r = await model.run(L("Saved", "已保存")) { () -> CFResponse? in
            guard let c = model.client else { return nil }
            if ruleset.isNull {
                // Creating the entry point with the first rule.
                return try await c.send("PUT", entry, body: .json(["rules": [body]]))
            }
            if let rule { return try await c.send("PATCH", rulePath(ruleset, rule), body: .json(body)) }
            return try await c.send("POST", rulePath(ruleset), body: .json(body))
        }
        if r != nil { await h.reload() }
        return r != nil
    }

    private func toggle(_ ruleset: JSON, _ rule: JSON, _ on: Bool, _ h: QueryHandle<JSON>) async {
        h.set(ruleset.setting("rules", to: .array(ruleset["rules"].items.map { $0["id"] == rule["id"] ? $0.setting("enabled", to: .bool(on)) : $0 })))
        let body = Rules.ruleBody(rule).setting("enabled", to: .bool(on))
        let r = await model.run { try await model.client?.patch(rulePath(ruleset, rule), body) }
        if r == nil { await h.reload() }
    }

    private func move(_ ruleset: JSON, from: Int, to: Int, _ h: QueryHandle<JSON>) async {
        var rules = ruleset["rules"].items
        guard from != to, rules.indices.contains(from), (0...rules.count - 1).contains(to) else { return }
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
        h.set(ruleset.setting("rules", to: .array(rules)))
        let body = Rules.ruleBody(rule).setting("position", to: ["index": .int(to + 1)])
        let r = await model.run { try await model.client?.patch(rulePath(ruleset, rule), body) }
        if r == nil { await h.reload() }
    }

    private func askDelete(_ ruleset: JSON, _ rule: JSON, _ h: QueryHandle<JSON>) {
        let message = rule["description"].string.flatMap { $0.isEmpty ? nil : $0 } ?? rule["expression"].string
        confirm = ConfirmItem(title: L("Delete rule?", "删除规则？"), message: message, button: L("Delete", "删除")) {
            let r = await model.run(L("Deleted", "已删除")) { try await model.client?.delete(rulePath(ruleset, rule)) }
            if r != nil { await h.reload() }
        }
    }
}

/// Edits one rule: name, expression, action and its parameters.
struct RuleEditorSheet: View {
    let phase: RulePhase
    let rule: JSON?
    let save: (JSON) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var expression = ""
    @State private var action = ""
    @State private var params = ""
    @State private var ratelimit = ""
    @State private var enabled = true
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Rule name", "规则名称"), text: $name)
                    Toggle(L("Enabled", "启用"), isOn: $enabled)
                }
                Section {
                    TextField(L("Expression", "表达式"), text: $expression, axis: .vertical)
                        .font(.callout.monospaced())
                        .plainInput()
                        .lineLimit(3...10)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Rules.expressionTemplates.indices, id: \.self) { i in
                                Button(Rules.expressionTemplates[i].title.text) { expression = Rules.expressionTemplates[i].expression }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Rules.expressionFields, id: \.self) { f in
                                Button(f) { expression += (expression.isEmpty || expression.hasSuffix(" ") ? "" : " ") + f }
                                    .font(.caption.monospaced())
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                            }
                        }
                    }
                } header: {
                    Text(L("Expression", "表达式"))
                } footer: {
                    Text(L("Cloudflare Rules language (wirefilter)", "Cloudflare 规则语言 (wirefilter)"))
                }
                Section {
                    Picker(L("Action", "动作"), selection: Binding(get: { action }, set: { a in
                        action = a
                        params = phase.templates[a]?.prettyString ?? ""
                    })) {
                        ForEach(phase.actions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("action_parameters (JSON)", text: $params, axis: .vertical)
                        .font(.caption.monospaced())
                        .plainInput()
                        .lineLimit(3...14)
                } footer: {
                    Text(L("Leave empty if the action takes no parameters", "若动作无需参数可留空"))
                }
                if phase.ratelimit {
                    Section("ratelimit (JSON)") {
                        TextField("ratelimit", text: $ratelimit, axis: .vertical)
                            .font(.caption.monospaced())
                            .plainInput()
                            .lineLimit(3...10)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? L("New rule", "新建规则") : L("Edit rule", "编辑规则"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) { Task { await submit() } }.disabled(busy)
                }
            }
            .onAppear(perform: load)
        }
        .frame(minWidth: 640, minHeight: 640)
    }

    private func load() {
        guard action.isEmpty else { return }
        name = rule?["description"].string ?? ""
        expression = rule?["expression"].string ?? ""
        action = rule?["action"].string ?? phase.actions.first ?? ""
        let p = rule?["action_parameters"] ?? .null
        params = p.isNull ? (phase.templates[action]?.prettyString ?? "") : p.prettyString
        ratelimit = (rule?["ratelimit"].isNull == false ? rule!["ratelimit"] : Rules.defaultRatelimit).prettyString
        enabled = rule?["enabled"].bool != false
    }

    private func submit() async {
        var body: JSON = [
            "description": .string(name.trimmingCharacters(in: .whitespaces)),
            "expression": .string(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "true" : expression.trimmingCharacters(in: .whitespacesAndNewlines)),
            "action": .string(action), "enabled": .bool(enabled),
        ]
        if !params.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let p = try? JSON.parse(params) else {
                error = L("Parameters must be valid JSON", "参数必须是合法 JSON")
                return
            }
            body = body.setting("action_parameters", to: p)
        }
        if phase.ratelimit {
            guard let r = try? JSON.parse(ratelimit) else {
                error = L("ratelimit must be valid JSON", "ratelimit 必须是合法 JSON")
                return
            }
            body = body.setting("ratelimit", to: r)
        }
        if let ref = rule?["ref"], !ref.isNull { body = body.setting("ref", to: ref) }
        busy = true
        defer { busy = false }
        if await save(body) { dismiss() }
    }
}

/// Security & WAF: settings, WAF phases, events, IP and UA rules, lockdown and bots.
struct SecurityView: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var tab = "overview"

    struct Part: Identifiable, Hashable {
        var id: String
        var title: String
    }

    private var parts: [Part] {
        let specs = model.resources.specs(in: "security")
        var out = [Part(id: "overview", title: L("Overview", "概览"))]
        for p in Rules.securityPhases { out.append(Part(id: p.phase, title: p.title.text)) }
        out.append(Part(id: "events", title: L("Events", "安全事件")))
        if let first = specs.first { out.append(Part(id: first.id, title: first.title.text)) }
        out.append(Part(id: "bots", title: L("Bots", "机器人")))
        for s in specs.dropFirst() { out.append(Part(id: s.id, title: s.title.text)) }
        return out
    }

    var body: some View {
        let res = model.resources
        let parts = self.parts
        VStack(spacing: 0) {
            SectionTabs(tabs: parts, selection: Binding(get: { parts.first { $0.id == tab } ?? parts[0] }, set: { tab = $0.id })) { $0.title }
            Group {
                if tab == "overview" {
                    ZoneSettingsList(zoneId: zone.id, groups: [.security, .scrape])
                } else if let p = Rules.securityPhases.first(where: { $0.phase == tab }) {
                    RulesetPhaseView(phase: p, basePath: "/zones/\(zone.id)")
                } else if tab == "events" {
                    SecurityEventsView(zoneId: zone.id)
                } else if tab == "bots", let d = res.document("bot_management") {
                    DocumentView(spec: d)
                } else if let s = res.spec(tab) {
                    ResourceListView(spec: s)
                }
            }
            .id(tab)
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(L("Security & WAF", "安全与 WAF"))
        .inlineTitle()
        .toolbar { ZoneToolbar() }
    }
}

/// Transform, redirect, origin, cache and other rules.
struct RulesView: View {
    let zone: ZoneRef
    var initialPhase: String?
    @Environment(AppModel.self) private var model
    @State private var tab: String?

    private var parts: [SecurityView.Part] {
        let res = model.resources
        var out: [SecurityView.Part] = []
        for p in Rules.transformPhases { out.append(SecurityView.Part(id: p.phase, title: p.title.text)) }
        for s in res.specs(in: "rules") { out.append(SecurityView.Part(id: s.id, title: s.title.text)) }
        for id in ["managed_headers", "url_normalization"] {
            if let d = res.document(id) { out.append(SecurityView.Part(id: "doc:" + id, title: d.title.text)) }
        }
        return out
    }

    var body: some View {
        let res = model.resources
        let parts = self.parts
        let current = tab ?? initialPhase ?? parts[0].id
        VStack(spacing: 0) {
            SectionTabs(tabs: parts, selection: Binding(get: { parts.first { $0.id == current } ?? parts[0] }, set: { tab = $0.id })) { $0.title }
            Group {
                if let p = Rules.transformPhases.first(where: { $0.phase == current }) {
                    RulesetPhaseView(phase: p, basePath: "/zones/\(zone.id)")
                } else if current.hasPrefix("doc:"), let d = res.document(String(current.dropFirst(4))) {
                    DocumentView(spec: d)
                } else if let s = res.spec(current) {
                    ResourceListView(spec: s)
                }
            }
            .id(current)
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(L("Rules", "规则"))
        .inlineTitle()
        .toolbar { ZoneToolbar() }
    }
}

/// Recent firewall events of a zone.
private struct SecurityEventsView: View {
    let zoneId: String
    @State private var hours = 24
    @State private var query = ""
    @State private var json: JSONItem?

    var body: some View {
        QueryView(
            "fw-events:\(zoneId):\(hours)",
            fetch: { (c: CFClient) async throws -> [JSON] in
                let now = Date()
                let data = try await c.graphql(
                    GraphQLTemplate.securityEvents,
                    variables: [
                        "zoneTag": .string(zoneId), "since": .string(ISODate.format(now.addingTimeInterval(-Double(hours) * 3600))),
                        "until": .string(ISODate.format(now)),
                    ])
                return data["viewer"]["zones"][0]["firewallEventsAdaptive"].items
            }
        ) { events, h in
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let shown = q.isEmpty ? events : events.filter { $0.compactString.lowercased().contains(q) }
            let byAction = Dictionary(grouping: events, by: { $0["action"].text ?? "" }).mapValues(\.count)
            List {
                if !byAction.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(byAction.keys.sorted(), id: \.self) { a in
                                    StatusBadge("\(a): \(byAction[a] ?? 0)", tone: a == "block" ? .bad : .warn)
                                }
                            }
                        }
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            StatusBadge(e["action"].text ?? "", tone: e["action"].string == "block" ? .bad : .warn)
                            Text("\(e["clientRequestHTTPMethodName"].text ?? "") \(e["clientRequestHTTPHost"].text ?? "")\(e["clientRequestPath"].text ?? "")")
                                .font(.caption.monospaced()).lineLimit(1)
                        }
                        Text(
                            "\(Format.date(e["datetime"])) · \(e["clientIP"].text ?? "") · \(e["clientCountryName"].text ?? "") · AS\(e["clientAsn"].text ?? "") · \(e["source"].text ?? "")"
                        )
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(.rect)
                    .onTapGesture { json = JSONItem(title: e["rayName"].text ?? "Event", json: e) }
                }
            }
            .overlay { if shown.isEmpty { EmptyState(title: L("No security events", "没有安全事件"), symbol: "checkmark.shield") } }
            .searchable(text: $query)
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker(L("Period", "时间段"), selection: $hours) {
                        Text("1h").tag(1)
                        Text("6h").tag(6)
                        Text("24h").tag(24)
                        Text("3d").tag(72)
                    }
                }
            }
        }
        .id(hours)
        .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

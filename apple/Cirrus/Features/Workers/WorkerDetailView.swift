import Charts
import CirrusKit
import SwiftUI

struct WorkerDetailView: View {
    let accountId: String
    let script: String
    let subdomain: String?

    enum Part: String, CaseIterable, Identifiable {
        case overview, code, bindings, secrets, triggers, deployments, logs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return L("Overview", "概览")
            case .code: return L("Code", "代码")
            case .bindings: return L("Bindings & variables", "绑定与变量")
            case .secrets: return "Secrets"
            case .triggers: return L("Triggers", "触发器")
            case .deployments: return L("Deployments", "部署")
            case .logs: return L("Live logs", "实时日志")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var part = Part.overview
    @State private var prompt: TextPrompt?

    var body: some View {
        VStack(spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
            Group {
                switch part {
                case .overview: WorkerOverview(accountId: accountId, script: script, subdomain: subdomain)
                case .code: WorkerCode(accountId: accountId, script: script)
                case .bindings: WorkerBindings(accountId: accountId, script: script)
                case .secrets: WorkerSecrets(accountId: accountId, script: script)
                case .triggers: WorkerTriggers(accountId: accountId, script: script)
                case .deployments: WorkerDeployments(accountId: accountId, script: script)
                case .logs: WorkerTail(accountId: accountId, script: script)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(script)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Delete Worker", "删除 Worker"), systemImage: "trash", role: .destructive) {
                        prompt = typedDelete(
                            L("Delete Worker?", "删除 Worker？"), name: script,
                            message: L("The script, its routes and settings will be deleted.", "脚本及其路由和设置都将被删除。"),
                            feedback: model.feedback
                        ) {
                            let r = await model.run(L("Deleted", "已删除")) {
                                try await model.client?.send("DELETE", Workers.scriptPath(accountId, script), query: ["force": "true"])
                            }
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
        .textPrompt($prompt)
    }
}

// MARK: Overview

private struct WorkerOverview: View {
    let accountId: String
    let script: String
    let subdomain: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    struct Stats {
        var metrics: [WorkerMetricsPoint]
        var sub: JSON?
    }

    var body: some View {
        QueryView(
            "worker-overview:\(accountId):\(script)",
            fetch: { (c: CFClient) async throws -> Stats in
                async let metrics = try? c.workerMetrics(accountId, script)
                async let sub = try? c.get(Workers.scriptPath(accountId, script) + "/subdomain")
                return Stats(metrics: await metrics ?? [], sub: await sub)
            }
        ) { d, h in
            let req = d.metrics.reduce(0) { $0 + $1.requests }
            let err = d.metrics.reduce(0) { $0 + $1.errors }
            let sr = d.metrics.reduce(0) { $0 + $1.subrequests }
            let p99 = d.metrics.map(\.cpuP99).max() ?? 0
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatGrid(minWidth: 150) {
                        StatTile(label: L("Requests (24h)", "请求数（24h）"), value: Format.count(req), symbol: "arrow.up.arrow.down")
                        StatTile(
                            label: L("Errors (24h)", "错误数（24h）"), value: Format.count(err), symbol: "exclamationmark.triangle",
                            sub: req == 0 ? nil : String(format: "%.2f%%", err / req * 100))
                        StatTile(label: L("Subrequests", "子请求"), value: Format.count(sr), symbol: "arrow.triangle.branch")
                        StatTile(label: "CPU P99", value: String(format: "%.1f µs", p99), symbol: "cpu")
                    }
                    if !d.metrics.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("Requests per hour", "每小时请求")).font(.headline)
                            Chart {
                                ForEach(d.metrics) { p in
                                    BarMark(x: .value("Hour", p.at, unit: .hour), y: .value(L("Requests", "请求"), p.requests))
                                        .foregroundStyle(Color.accentColor.gradient)
                                    if p.errors > 0 {
                                        BarMark(x: .value("Hour", p.at, unit: .hour), y: .value(L("Errors", "错误"), p.errors))
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                            .frame(height: 200)
                        }
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                    if let sub = d.sub {
                        let url = subdomain.map { "https://\(script).\($0).workers.dev" }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("workers.dev").font(.headline)
                            Toggle(
                                L("Route on workers.dev", "在 workers.dev 上提供访问"),
                                isOn: Binding(get: { sub["enabled"].isTrue }, set: { v in
                                    Task { await setSubdomain(enabled: v, previews: sub["previews_enabled"].bool ?? v, h) }
                                }))
                            if let url, sub["enabled"].isTrue, let u = URL(string: url) {
                                Button(url) { openURL(u) }.font(.callout.monospaced()).buttonStyle(.borderless)
                            }
                            Toggle(
                                L("Preview URLs", "预览 URL"),
                                isOn: Binding(get: { sub["previews_enabled"].isTrue }, set: { v in
                                    Task { await setSubdomain(enabled: sub["enabled"].isTrue, previews: v, h) }
                                }))
                        }
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                }
                .padding()
            }
            .background(AmbientBackground())
            .refreshable { await h.reload() }
        }
    }

    private func setSubdomain(enabled: Bool, previews: Bool, _ h: QueryHandle<Stats>) async {
        await model.run {
            try await model.client?.post(
                Workers.scriptPath(accountId, script) + "/subdomain", ["enabled": .bool(enabled), "previews_enabled": .bool(previews)])
        }
        await h.reload()
    }
}

// MARK: Code

private struct WorkerCode: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var content: WorkerContent?
    @State private var texts: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var current: String?
    @State private var error: Error?
    @State private var deploying = false

    private var dirty: Bool { texts != original }

    var body: some View {
        Group {
            if let content {
                VStack(spacing: 10) {
                    HStack {
                        Picker(L("Module", "模块"), selection: Binding(get: { current ?? "" }, set: { current = $0 })) {
                            ForEach(content.modules) { m in
                                Text(m.name + (m.name == content.mainModule ? " ★" : "")).tag(m.name)
                            }
                        }
                        .labelsHidden()
                        Spacer()
                        Button(L("Reload", "重新加载"), systemImage: "arrow.clockwise") { Task { await load() } }
                            .labelStyle(.iconOnly)
                        Button {
                            Task { await deploy() }
                        } label: {
                            Label(L("Save & deploy", "保存并部署"), systemImage: "paperplane")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!dirty || deploying)
                    }
                    if !content.moduleSyntax {
                        Text(L("Service Worker syntax detected.", "检测到 Service Worker 语法。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let current, texts[current] != nil {
                        CodeEditor(text: Binding(get: { texts[current] ?? "" }, set: { texts[current] = $0 }))
                    } else {
                        EmptyState(title: L("No editable text module", "没有可编辑的文本模块"), symbol: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .padding()
            } else if let error {
                ErrorState(error: error) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if content == nil { await load() } }
    }

    private func load() async {
        guard let client = model.client else { return }
        error = nil
        do {
            let c = try await client.workerContent(accountId, script)
            var t: [String: String] = [:]
            for m in c.modules where m.isText { t[m.name] = m.text }
            content = c
            texts = t
            original = t
            current = c.main.flatMap { $0.isText ? $0.name : nil } ?? t.keys.sorted().first
        } catch {
            self.error = error
        }
    }

    private func deploy() async {
        guard var c = content else { return }
        for i in c.modules.indices {
            if let t = texts[c.modules[i].name] { c.modules[i].text = t }
        }
        deploying = true
        defer { deploying = false }
        let r: Void?? = await model.run(L("Deployed", "已部署")) { try await model.client?.uploadWorkerContent(accountId, script, c) }
        if r != nil {
            content = c
            original = texts
        }
    }
}

// MARK: Bindings and settings

private struct WorkerBindings: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var editingVar: VarDraft?
    @State private var jsonEditor: String?
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    struct VarDraft: Identifiable {
        let id = UUID()
        var name: String
        var value: String
        var isNew: Bool
    }

    private var path: String { Workers.scriptPath(accountId, script) }

    var body: some View {
        QueryView("worker-settings:\(accountId):\(script)", fetch: { c in try await c.get(path + "/settings") }) { s, h in
            let bindings = s["bindings"].items
            let vars = bindings.filter { ["plain_text", "json"].contains($0["type"].string ?? "") }
            let others = bindings.filter { !["plain_text", "json"].contains($0["type"].string ?? "") }
            Form {
                Section {
                    if vars.isEmpty { Text(L("No variables", "没有变量")).foregroundStyle(.secondary) }
                    ForEach(vars, id: \.self) { b in
                        let name = b["name"].string ?? ""
                        Button {
                            if b["type"].string == "plain_text" {
                                editingVar = VarDraft(name: name, value: b["text"].string ?? "", isNew: false)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.body.monospaced().weight(.semibold))
                                Text(Workers.bindingTarget(b)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(title: L("Remove \(name)?", "移除 \(name)？"), button: L("Remove", "移除")) {
                                    _ = await save(Workers.rebuildBindings(s, remove: name), h)
                                }
                            }
                        }
                        .contextMenu {
                            Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(title: L("Remove \(name)?", "移除 \(name)？"), button: L("Remove", "移除")) {
                                    _ = await save(Workers.rebuildBindings(s, remove: name), h)
                                }
                            }
                        }
                    }
                    Button(L("Add variable", "添加变量"), systemImage: "plus") {
                        editingVar = VarDraft(name: "", value: "", isNew: true)
                    }
                } header: {
                    Text(L("Environment variables", "环境变量"))
                }

                Section {
                    if others.isEmpty { Text(L("No bindings", "没有绑定")).foregroundStyle(.secondary) }
                    ForEach(others, id: \.self) { b in
                        HStack {
                            Image(systemName: "link").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b["name"].string ?? "").font(.body.monospaced().weight(.semibold))
                                Text(Workers.bindingLabel(b["type"].string ?? "") + " · " + Workers.bindingTarget(b))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Button(L("Edit as JSON", "以 JSON 编辑"), systemImage: "curlybraces") {
                        jsonEditor = JSON.array(Workers.rebuildBindings(s)).prettyString
                    }
                } header: {
                    Text(L("Bindings", "绑定"))
                }

                Section(L("Runtime", "运行时")) {
                    Button {
                        prompt = TextPrompt(
                            title: L("Compatibility date", "兼容日期"), placeholder: "YYYY-MM-DD",
                            text: s["compatibility_date"].string ?? ""
                        ) { v in
                            await model.run(L("Saved", "已保存")) {
                                try await model.client?.patchWorkerSettings(
                                    accountId, script, ["compatibility_date": .string(v.trimmingCharacters(in: .whitespaces))])
                            }
                            await h.reload()
                        }
                    } label: {
                        LabeledContent(L("Compatibility date", "兼容日期"), value: s["compatibility_date"].string ?? "—")
                    }
                    .buttonStyle(.plain)
                    InfoRow(
                        L("Compatibility flags", "兼容标志"),
                        s["compatibility_flags"].strings.isEmpty ? "—" : s["compatibility_flags"].strings.joined(separator: ", "))
                    InfoRow(L("Usage model", "计费模式"), s["usage_model"].text)
                    InfoRow(L("Placement", "放置"), s["placement"]["mode"].string ?? s["placement_mode"].string)
                    Toggle(
                        L("Workers Logs (observability)", "Workers 日志（可观测性）"),
                        isOn: Binding(get: { s["observability"]["enabled"].isTrue }, set: { v in
                            Task { await patch(["observability": ["enabled": .bool(v)]], h) }
                        }))
                    Toggle(
                        "Logpush",
                        isOn: Binding(get: { s["logpush"].isTrue }, set: { v in Task { await patch(["logpush": .bool(v)], h) } }))
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(item: $editingVar) { draft in
                VariableSheet(draft: draft) { name, value in
                    await save(Workers.rebuildBindings(s, replace: ["name": .string(name), "type": "plain_text", "text": .string(value)]), h)
                }
            }
            .sheet(
                isPresented: Binding(get: { jsonEditor != nil }, set: { if !$0 { jsonEditor = nil } })
            ) {
                JSONEditorSheet(title: L("Edit bindings (JSON)", "编辑绑定（JSON）"), text: jsonEditor ?? "[]") { text in
                    guard let parsed = try? JSON.parse(text), let list = parsed.array else {
                        model.feedback.show(L("Expected a JSON array", "需要 JSON 数组"), error: true)
                        return false
                    }
                    return await save(list, h)
                }
            }
        }
        .textPrompt($prompt)
        .confirm($confirm)
    }

    @discardableResult
    private func save(_ bindings: [JSON], _ h: QueryHandle<JSON>) async -> Bool {
        let r: Void?? = await model.run(L("Saved and deployed", "已保存并部署")) {
            try await model.client?.patchWorkerSettings(accountId, script, ["bindings": .array(bindings)])
        }
        await h.reload()
        return r != nil
    }

    private func patch(_ settings: JSON, _ h: QueryHandle<JSON>) async {
        await model.run { try await model.client?.patchWorkerSettings(accountId, script, settings) }
        await h.reload()
    }
}

private struct VariableSheet: View {
    let draft: WorkerBindings.VarDraft
    let save: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Name", "名称"), text: $name).plainInput().font(.body.monospaced()).disabled(!draft.isNew)
                TextField(L("Value", "值"), text: $value, axis: .vertical).plainInput().lineLimit(1...8)
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? L("Add variable", "添加变量") : L("Edit variable", "编辑变量"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) {
                        Task { if await save(name.trimmingCharacters(in: .whitespaces), value) { dismiss() } }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = draft.name
                value = draft.value
            }
        }
        .frame(minWidth: 440, minHeight: 300)
    }
}

// MARK: Secrets

private struct WorkerSecrets: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var editing: SecretDraft?
    @State private var confirm: ConfirmItem?

    struct SecretDraft: Identifiable {
        let id = UUID()
        var name: String
        var isNew: Bool
    }

    private var base: String { Workers.scriptPath(accountId, script) + "/secrets" }

    var body: some View {
        QueryView("worker-secrets:\(accountId):\(script)", fetch: { c in try await c.list(base, paginate: false) }) { secrets, h in
            List {
                Section {
                    ForEach(secrets, id: \.self) { s in
                        let name = s["name"].string ?? ""
                        Button {
                            editing = SecretDraft(name: name, isNew: false)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(name).font(.body.monospaced())
                                    Text(s["type"].string ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "key.fill")
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                                confirm = ConfirmItem(title: L("Delete secret?", "删除密钥？"), message: name, button: L("Delete", "删除")) {
                                    await model.run(L("Deleted", "已删除")) { try await model.client?.delete(base + "/" + name.pathEncoded) }
                                    await h.reload()
                                }
                            }
                        }
                    }
                    Button(L("Add secret", "添加密钥"), systemImage: "plus") { editing = SecretDraft(name: "", isNew: true) }
                } footer: {
                    Text(L("Secret values are write-only.", "密钥值只能写入，无法读取。"))
                }
            }
            .refreshable { await h.reload() }
            .sheet(item: $editing) { d in
                SecretSheet(draft: d) { name, value in
                    let r = await model.run(L("Secret saved", "密钥已保存")) {
                        try await model.client?.put(base, ["name": .string(name), "text": .string(value), "type": "secret_text"])
                    }
                    await h.reload()
                    return r != nil
                }
            }
        }
        .confirm($confirm)
    }
}

private struct SecretSheet: View {
    let draft: WorkerSecrets.SecretDraft
    let save: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Name", "名称"), text: $name).plainInput().font(.body.monospaced()).disabled(!draft.isNew)
                SecureField(L("Value", "值"), text: $value)
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? L("Add secret", "添加密钥") : L("Update secret", "更新密钥"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) {
                        Task { if await save(name.trimmingCharacters(in: .whitespaces), value) { dismiss() } }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
                }
            }
            .onAppear { name = draft.name }
        }
        .frame(minWidth: 440, minHeight: 260)
    }
}

// MARK: Triggers

private struct WorkerTriggers: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?
    @State private var cronText: String?

    struct Triggers {
        var domains: [JSON]
        var schedules: [JSON]
        var routes: [JSON]
    }

    private var path: String { Workers.scriptPath(accountId, script) }

    var body: some View {
        let zoneId = model.zoneId
        let zoneName = model.zoneName
        QueryView(
            "worker-triggers:\(accountId):\(script):\(zoneId ?? "-")",
            fetch: { (c: CFClient) async throws -> Triggers in
                async let domains = try? c.list("/accounts/\(accountId)/workers/domains", query: ["service": script], paginate: false)
                async let sched = try? c.get(path + "/schedules")
                var routes: [JSON] = []
                if let zoneId {
                    routes = ((try? await c.list("/zones/\(zoneId)/workers/routes", paginate: false)) ?? [])
                        .filter { $0["script"].string == script }
                }
                return Triggers(domains: await domains ?? [], schedules: (await sched)?["schedules"].items ?? [], routes: routes)
            }
        ) { t, h in
            Form {
                Section {
                    if t.domains.isEmpty { Text(L("No custom domains", "没有自定义域")).foregroundStyle(.secondary) }
                    ForEach(t.domains, id: \.self) { d in
                        let host = d["hostname"].string ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host)
                            Text("\(d["zone_name"].string ?? "") · \(d["environment"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(L("Detach", "解绑"), systemImage: "link", role: .destructive) {
                                confirm = ConfirmItem(title: L("Detach \(host)?", "解绑 \(host)？"), button: L("Detach", "解绑")) {
                                    await model.run { try await model.client?.delete("/accounts/\(accountId)/workers/domains/\(d["id"].text ?? "")") }
                                    await h.reload()
                                }
                            }
                        }
                    }
                    if let zoneId {
                        Button(L("Add custom domain", "添加自定义域"), systemImage: "plus") {
                            prompt = TextPrompt(title: L("Custom domain", "自定义域"), placeholder: "api.\(zoneName)", confirm: L("Add", "添加")) { host in
                                await model.run(L("Domain attached", "已绑定域名")) {
                                    try await model.client?.put(
                                        "/accounts/\(accountId)/workers/domains",
                                        [
                                            "hostname": .string(host.trimmingCharacters(in: .whitespaces)), "service": .string(script),
                                            "zone_id": .string(zoneId), "environment": "production",
                                        ])
                                }
                                await h.reload()
                            }
                        }
                    }
                } header: {
                    Text(L("Custom domains", "自定义域"))
                }

                Section {
                    if t.routes.isEmpty { Text(L("No routes in this zone", "该域名下没有路由")).foregroundStyle(.secondary) }
                    ForEach(t.routes, id: \.self) { r in
                        Text(r["pattern"].string ?? "").font(.body.monospaced())
                            .swipeActions {
                                Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                                    Task {
                                        await model.run { try await model.client?.delete("/zones/\(zoneId ?? "")/workers/routes/\(r["id"].text ?? "")") }
                                        await h.reload()
                                    }
                                }
                            }
                    }
                    if let zoneId {
                        Button(L("Add route", "添加路由"), systemImage: "plus") {
                            prompt = TextPrompt(title: L("Route pattern", "路由规则"), placeholder: "\(zoneName)/api/*", confirm: L("Add", "添加")) { pattern in
                                await model.run {
                                    try await model.client?.post(
                                        "/zones/\(zoneId)/workers/routes",
                                        ["pattern": .string(pattern.trimmingCharacters(in: .whitespaces)), "script": .string(script)])
                                }
                                await h.reload()
                            }
                        }
                    }
                } header: {
                    Text(L("Routes in \(zoneName.isEmpty ? "current zone" : zoneName)", "\(zoneName.isEmpty ? "当前域名" : zoneName) 中的路由"))
                }

                Section {
                    if t.schedules.isEmpty { Text(L("No cron triggers", "没有 Cron 触发器")).foregroundStyle(.secondary) }
                    ForEach(t.schedules, id: \.self) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s["cron"].string ?? "").font(.body.monospaced())
                            if !s["modified_on"].isNull { Text(Format.date(s["modified_on"])).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button(L("Edit cron triggers", "编辑 Cron 触发器"), systemImage: "pencil") {
                        cronText = t.schedules.compactMap { $0["cron"].string }.joined(separator: "\n")
                    }
                } header: {
                    Text(L("Cron triggers", "Cron 触发器"))
                } footer: {
                    Text(L("One expression per line, in UTC.", "每行一个表达式，按 UTC 时间。"))
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(isPresented: Binding(get: { cronText != nil }, set: { if !$0 { cronText = nil } })) {
                JSONEditorSheet(title: L("Cron triggers", "Cron 触发器"), text: cronText ?? "") { text in
                    let crons = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let r = await model.run(L("Saved", "已保存")) {
                        try await model.client?.put(path + "/schedules", .array(crons.map { ["cron": .string($0)] }))
                    }
                    await h.reload()
                    return r != nil
                }
            }
        }
        .textPrompt($prompt)
        .confirm($confirm)
    }
}

// MARK: Deployments

private struct WorkerDeployments: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var jsonItem: JSONItem?

    struct Info {
        var deployments: [JSON]
        var versions: [JSON]
    }

    private var path: String { Workers.scriptPath(accountId, script) }

    var body: some View {
        QueryView(
            "worker-deployments:\(accountId):\(script)",
            fetch: { (c: CFClient) async throws -> Info in
                async let d = c.get(path + "/deployments")
                async let v = c.get(path + "/versions")
                let dj = try await d
                let vj = try await v
                return Info(
                    deployments: dj.array ?? dj["deployments"].items,
                    versions: vj.array ?? (vj["items"].array ?? vj["versions"].items))
            }
        ) { info, h in
            let active = info.deployments.first
            let activeIds = Set((active?["versions"].items ?? []).compactMap { $0["version_id"].string })
            Form {
                if let active {
                    Section(L("Active deployment", "当前部署")) {
                        ForEach(active["versions"].items, id: \.self) { v in
                            InfoRow("\(v["percentage"].text ?? "")%", v["version_id"].string, mono: true, copy: true)
                        }
                        InfoRow(L("Deployed", "部署时间"), Format.date(active["created_on"]))
                        if let a = active["author_email"].string { InfoRow(L("Author", "作者"), a) }
                        if let m = active["annotations"]["workers/message"].string { InfoRow(L("Message", "说明"), m) }
                    }
                }
                Section(L("Versions", "版本")) {
                    ForEach(info.versions, id: \.self) { v in
                        let id = v["id"].string ?? ""
                        HStack(spacing: 12) {
                            Text(v["number"].text ?? "?")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.15), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id).font(.caption.monospaced()).lineLimit(1)
                                Text(
                                    [
                                        v["metadata"]["created_on"].isNull ? nil : Format.date(v["metadata"]["created_on"]),
                                        v["metadata"]["author_email"].string, v["metadata"]["source"].string,
                                        v["annotations"]["workers/message"].string,
                                    ].compactMap { $0 }.joined(separator: " · ")
                                )
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if activeIds.contains(id) {
                                StatusBadge("active")
                            } else {
                                Button(L("Deploy", "部署")) {
                                    prompt = TextPrompt(
                                        title: L("Deploy version \(v["number"].text ?? "") (100%)", "部署版本 \(v["number"].text ?? "")（100%）"),
                                        message: L("Message (optional)", "说明（可选）"), confirm: L("Deploy", "部署")
                                    ) { msg in
                                        var body: JSON = [
                                            "strategy": "percentage", "versions": [["version_id": .string(id), "percentage": 100]],
                                        ]
                                        let m = msg.trimmingCharacters(in: .whitespaces)
                                        if !m.isEmpty { body = body.setting("annotations", to: ["workers/message": .string(m)]) }
                                        await model.run(L("Deployed", "已部署")) { try await model.client?.post(path + "/deployments", body) }
                                        await h.reload()
                                    }
                                }
                                .buttonStyle(.glass)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { jsonItem = JSONItem(title: id, json: v) }
                    }
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
        }
        .textPrompt($prompt)
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

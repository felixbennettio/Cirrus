import CirrusKit
import SwiftUI

/// Shows [content] once the spec's scope (account or zone) is available.
struct ScopeRequired<Content: View>: View {
    let scope: SpecScope
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch scope {
        case .zone: ZoneRequired { _ in content() }
        case .account: AccountRequired { _ in content() }
        case .user: content()
        }
    }
}

/// Values shown once: newly created secrets and tokens.
struct SecretItem: Identifiable {
    let id = UUID()
    var title: String
    var values: [(key: String, value: String)]
    var note: String?
}

struct SecretsSheet: View {
    let item: SecretItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let note = item.note { Section { Text(note).foregroundStyle(.secondary) } }
                Section {
                    ForEach(item.values.indices, id: \.self) { i in
                        let v = item.values[i]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(v.key).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .top) {
                                Text(v.value).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(v.value) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } footer: {
                    Text(L("Copy these now: some of them are shown only once.", "请立即复制：部分值只会显示这一次。"))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(item.title)
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } } }
        }
        .frame(minWidth: 520, minHeight: 360)
        .interactiveDismissDisabled()
    }
}

/// A body editor request for the schema sheet.
struct SchemaRequest: Identifiable {
    let id = UUID()
    var title: String
    var schema: JSON
    var initial: JSON = [:]
    var hidden: Set<String> = []
    var submitLabel = L("Save", "保存")
    var submit: (JSON) async -> Bool
}

extension View {
    /// Presents the shared sheets of the generic resource pages.
    func resourceSheets(schema: Binding<SchemaRequest?>, secrets: Binding<SecretItem?>, json: Binding<JSONItem?>) -> some View {
        modifier(ResourceSheets(schema: schema, secrets: secrets, json: json))
    }
}

private struct ResourceSheets: ViewModifier {
    @Binding var schema: SchemaRequest?
    @Binding var secrets: SecretItem?
    @Binding var json: JSONItem?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: $schema) { r in
                SchemaEditorSheet(
                    title: r.title, catalog: model.catalog.catalog, schema: r.schema, initial: r.initial, hidden: r.hidden,
                    submitLabel: r.submitLabel, submit: r.submit)
            }
            .sheet(item: $secrets) { SecretsSheet(item: $0) }
            .sheet(item: $json) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

/// Runs create, edit, delete and custom actions of a spec, with the sheets they need.
@MainActor
struct ResourceActions {
    let model: AppModel
    let spec: ResourceSpec
    let parent: String?
    let schema: Binding<SchemaRequest?>
    let secrets: Binding<SecretItem?>
    let json: Binding<JSONItem?>
    let prompt: Binding<TextPrompt?>
    let confirm: Binding<ConfirmItem?>
    let reload: () async -> Void

    private func path(_ template: String, id: String? = nil) -> String {
        ResourceSpec.fill(template, ids: model.scopeIds, id: id, parent: parent)
    }

    func create() async {
        let p = path(spec.createPath ?? spec.listPath)
        let op = await model.catalog.load()?.find("POST", p)
        schema.wrappedValue = SchemaRequest(
            title: L("Create · \(spec.title.en)", "新建 · \(spec.title.zh)"), schema: op?.body?.schema ?? .null,
            hidden: spec.hiddenCreateFields, submitLabel: L("Create", "创建")
        ) { body in
            let r = await model.run(L("Created", "已创建")) { try await model.client?.send("POST", p, body: .json(body)) }
            guard let response = r, let res = response else { return false }
            await reload()
            let found = secretsIn(res.result)
            if !found.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                secrets.wrappedValue = SecretItem(title: L("Created", "已创建"), values: found)
            }
            return true
        }
    }

    func edit(_ item: JSON) async {
        guard let method = spec.updateMethod, let id = spec.itemId(item) else { return }
        let p = path(spec.resolvedItemPath, id: id)
        let catalog = await model.catalog.load()
        let op = catalog?.find(method, p)
        let initial = op?.body.map { catalog!.filter(item, for: $0.schema) } ?? item
        schema.wrappedValue = SchemaRequest(
            title: L("Edit · \(spec.title(of: item))", "编辑 · \(spec.title(of: item))"), schema: op?.body?.schema ?? .null,
            initial: initial
        ) { body in
            let r = await model.run(L("Saved", "已保存")) { try await model.client?.send(method, p, body: .json(body)) }
            if r != nil { await reload() }
            return r != nil
        }
    }

    func delete(_ item: JSON, then: (() -> Void)? = nil) {
        let title = spec.title(of: item)
        let p = path(spec.resolvedItemPath, id: spec.itemId(item))
        let run: () async -> Void = {
            let r = await model.run(L("Deleted", "已删除")) { try await model.client?.send("DELETE", p) }
            if r != nil {
                await reload()
                then?()
            }
        }
        if let field = spec.dangerNameField, let name = item.pick(field).text {
            prompt.wrappedValue = typedDelete(
                L("Delete \(spec.title.en)?", "删除\(spec.title.zh)？"), name: name,
                message: L("\"\(title)\" will be permanently deleted.", "“\(title)” 将被永久删除。"), feedback: model.feedback, action: run)
        } else {
            confirm.wrappedValue = ConfirmItem(
                title: L("Delete \(spec.title.en)?", "删除\(spec.title.zh)？"),
                message: L("\"\(title)\" will be permanently deleted.", "“\(title)” 将被永久删除。"), button: L("Delete", "删除"), action: run)
        }
    }

    func run(_ action: ItemAction, item: JSON? = nil) {
        let id = item.flatMap { spec.itemId($0) }
        let p = path(action.path, id: id)
        let send: (JSON?) async -> Bool = { body in
            let r = await model.run { try await model.client?.send(action.method, p, body: body.map { .json($0) }) }
            guard let response = r, let res = response else { return false }
            await reload()
            if action.showResult {
                let found = secretsIn(res.result)
                if !found.isEmpty {
                    secrets.wrappedValue = SecretItem(title: action.label.text, values: found)
                } else if !res.result.isNull {
                    json.wrappedValue = JSONItem(title: action.label.text, json: res.result)
                } else {
                    model.feedback.show(L("Done", "完成"))
                }
            } else {
                model.feedback.show(L("Done", "完成"))
            }
            return true
        }
        let start: () async -> Void = {
            if action.withBody {
                let op = await model.catalog.load()?.find(action.method, p)
                schema.wrappedValue = SchemaRequest(
                    title: action.label.text, schema: op?.body?.schema ?? .null, submitLabel: L("Run", "执行"), submit: send)
            } else {
                _ = await send(action.body(for: id))
            }
        }
        if action.confirm {
            confirm.wrappedValue = ConfirmItem(
                title: action.label.text, message: item.map { spec.title(of: $0) }, button: action.label.text,
                destructive: action.danger, action: start)
        } else {
            Task { await start() }
        }
    }
}

/// The items of a spec: search, create, open, edit, delete, actions.
struct ResourceListView: View {
    let spec: ResourceSpec
    var parentId: String?
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var schema: SchemaRequest?
    @State private var secrets: SecretItem?
    @State private var json: JSONItem?
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    var body: some View {
        ScopeRequired(scope: spec.scope) {
            let path = ResourceSpec.fill(spec.listPath, ids: model.scopeIds, parent: parentId)
            QueryView(
                "list:" + path,
                fetch: { c in
                    try await c.list(path, query: spec.listQuery, perPage: spec.perPage, maxItems: 5000, paginate: spec.paginate)
                }
            ) { items, h in
                let actions = ResourceActions(
                    model: model, spec: spec, parent: parentId, schema: $schema, secrets: $secrets, json: $json, prompt: $prompt,
                    confirm: $confirm, reload: h.reload)
                let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = q.isEmpty ? items : items.filter { $0.compactString.lowercased().contains(q) }
                List {
                    Section {
                        ForEach(shown, id: \.self) { item in
                            row(item, actions)
                        }
                    } header: {
                        if let d = spec.description?.text { Text(d) }
                    }
                }
                .overlay {
                    if shown.isEmpty {
                        EmptyState(
                            title: items.isEmpty ? L("Nothing here yet", "暂无数据") : L("No matches", "没有匹配项"),
                            symbol: Icons.symbol(spec.icon),
                            message: items.isEmpty && spec.canCreate ? L("Use \"Create\" to add one.", "点击“新建”添加。") : nil)
                    }
                }
                .searchable(text: $query)
                .refreshable { await h.reload() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ForEach(spec.listActions) { a in
                            Button(a.label.text, systemImage: Icons.symbol(a.icon)) { actions.run(a) }
                        }
                        if spec.canCreate {
                            Button(L("Create", "新建"), systemImage: "plus") { Task { await actions.create() } }
                        }
                    }
                }
            }
        }
        .resourceSheets(schema: $schema, secrets: $secrets, json: $json)
        .textPrompt($prompt)
        .confirm($confirm)
    }

    @ViewBuilder private func row(_ item: JSON, _ actions: ResourceActions) -> some View {
        let id = spec.itemId(item)
        let canOpen = id != nil && parentId == nil && (!spec.children.isEmpty || spec.hasItemPath)
        let label = ResourceRow(spec: spec, item: item)
            .contextMenu { menu(item, actions) }
            .swipeActions {
                if spec.canDelete {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { actions.delete(item) }
                }
            }
        if canOpen, let id {
            NavigationLink {
                ResourceDetailView(spec: spec, id: id, initial: item)
            } label: {
                label
            }
        } else {
            label.contentShape(.rect).onTapGesture { json = JSONItem(title: spec.title(of: item), json: item) }
        }
    }

    @ViewBuilder private func menu(_ item: JSON, _ actions: ResourceActions) -> some View {
        Button(L("View JSON", "查看 JSON"), systemImage: "curlybraces") { json = JSONItem(title: spec.title(of: item), json: item) }
        if let id = spec.itemId(item) {
            Button(L("Copy ID", "复制 ID"), systemImage: "doc.on.doc") { Clipboard.copy(id) }
        }
        if spec.updateMethod != nil {
            Button(L("Edit", "编辑"), systemImage: "pencil") { Task { await actions.edit(item) } }
        }
        ForEach(spec.actions) { a in
            Button(a.label.text, systemImage: Icons.symbol(a.icon), role: a.danger ? ButtonRole.destructive : nil) { actions.run(a, item: item) }
        }
        if spec.canDelete {
            Divider()
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { actions.delete(item) }
        }
    }
}

struct ResourceRow: View {
    let spec: ResourceSpec
    let item: JSON

    var body: some View {
        let subtitle = spec.subtitle(of: item)
        HStack(spacing: 12) {
            Image(systemName: Icons.symbol(spec.icon)).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title(of: item)).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if let s = spec.status(of: item) { StatusBadge(s.text, tone: s.tone) }
        }
    }
}

/// One item: its properties, actions and child collections.
struct ResourceDetailView: View {
    let spec: ResourceSpec
    let id: String
    let initial: JSON?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var part = "overview"
    @State private var schema: SchemaRequest?
    @State private var secrets: SecretItem?
    @State private var json: JSONItem?
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    struct Part: Identifiable, Hashable {
        var id: String
        var title: String
    }

    var body: some View {
        let parts = [Part(id: "overview", title: L("Overview", "概览"))] + spec.children.map { Part(id: $0.id, title: $0.title.text) }
        VStack(spacing: 0) {
            if parts.count > 1 {
                SectionTabs(tabs: parts, selection: Binding(get: { parts.first { $0.id == part } ?? parts[0] }, set: { part = $0.id })) { $0.title }
            }
            if part == "overview" {
                overview
            } else if let child = spec.children.first(where: { $0.id == part }) {
                ResourceListView(spec: child, parentId: id)
            }
        }
        .navigationTitle(initial.map { spec.title(of: $0) } ?? id)
        .inlineTitle()
        .resourceSheets(schema: $schema, secrets: $secrets, json: $json)
        .textPrompt($prompt)
        .confirm($confirm)
    }

    private var overview: some View {
        let path = ResourceSpec.fill(spec.resolvedItemPath, ids: model.scopeIds, id: id)
        let initial = initial
        let hasItemPath = spec.hasItemPath
        return QueryView(
            "detail:\(spec.id):\(id)",
            fetch: { (c: CFClient) async throws -> JSON in
                if hasItemPath {
                    do {
                        let r = try await c.get(path)
                        if r.object != nil { return r }
                    } catch {
                        if initial == nil { throw error }
                    }
                }
                return initial ?? ["id": .string(id)]
            }
        ) { item, h in
            let actions = ResourceActions(
                model: model, spec: spec, parent: nil, schema: $schema, secrets: $secrets, json: $json, prompt: $prompt,
                confirm: $confirm, reload: h.reload)
            Form {
                Section {
                    if let s = spec.status(of: item) { LabeledContent(L("Status", "状态")) { StatusBadge(s.text, tone: s.tone) } }
                    if spec.updateMethod != nil {
                        Button(L("Edit", "编辑"), systemImage: "pencil") { Task { await actions.edit(item) } }
                    }
                    ForEach(spec.actions) { a in
                        Button(a.label.text, systemImage: Icons.symbol(a.icon), role: a.danger ? ButtonRole.destructive : nil) {
                            actions.run(a, item: item)
                        }
                    }
                    if spec.canDelete {
                        Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                            actions.delete(item) { dismiss() }
                        }
                    }
                }
                let scalars = (item.object ?? [:]).filter { $0.value.array == nil && $0.value.object == nil && !$0.value.isNull }
                if !scalars.isEmpty {
                    Section(L("Properties", "属性")) {
                        ForEach(scalars.keys.sorted(), id: \.self) { k in
                            let v = scalars[k]!
                            let shown = ResourceSpec.display(v)
                            InfoRow(k, shown.isEmpty ? v.text : shown, copy: k.contains("id"))
                        }
                    }
                }
                Section("JSON") {
                    Text(item.prettyString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(40)
                    Button(L("Open", "打开"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        json = JSONItem(title: spec.title(of: item), json: item)
                    }
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
        }
    }
}

/// A settings document: view, and edit when the API allows it.
struct DocumentView: View {
    let spec: DocumentSpec
    @Environment(AppModel.self) private var model
    @State private var schema: SchemaRequest?
    @State private var secrets: SecretItem?
    @State private var json: JSONItem?

    var body: some View {
        ScopeRequired(scope: spec.scope) {
            let path = expandPath(spec.path, ids: model.scopeIds)
            QueryView("doc:" + path, fetch: { c in try await c.get(path) }) { data, h in
                Form {
                    if let d = spec.description?.text { Section { Text(d).foregroundStyle(.secondary) } }
                    if let method = spec.method {
                        Section {
                            Button(L("Edit", "编辑"), systemImage: "pencil") { Task { await edit(method, path, data, h) } }
                        }
                    }
                    Section {
                        if data.isNull {
                            Text(L("Empty", "空")).foregroundStyle(.secondary)
                        } else {
                            Text(data.prettyString).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
                .refreshable { await h.reload() }
            }
        }
        .resourceSheets(schema: $schema, secrets: $secrets, json: $json)
    }

    private func edit(_ method: String, _ path: String, _ data: JSON, _ h: QueryHandle<JSON>) async {
        let catalog = await model.catalog.load()
        let op = catalog?.find(method, path)
        // List documents (e.g. split tunnels) are edited as JSON.
        let initial: JSON = data.array != nil ? data : (op?.body.map { catalog!.filter(data, for: $0.schema) } ?? data)
        schema = SchemaRequest(title: spec.title.text, schema: data.array != nil ? .null : (op?.body?.schema ?? .null), initial: initial) { body in
            let r = await model.run(L("Saved", "已保存")) { try await model.client?.send(method, path, body: .json(body)) }
            if r != nil { await h.reload() }
            return r != nil
        }
    }
}

/// A list of specs and documents (the "More …" pages).
struct ResourceHubView: View {
    let title: String
    let specs: [ResourceSpec]
    var documents: [DocumentSpec] = []

    var body: some View {
        List {
            if !specs.isEmpty {
                Section {
                    ForEach(specs) { s in
                        NavigationLink {
                            ResourceListView(spec: s).navigationTitle(s.title.text)
                        } label: {
                            hubLabel(s.title.text, s.group.text, s.icon)
                        }
                    }
                }
            }
            if !documents.isEmpty {
                Section(L("Settings", "设置")) {
                    ForEach(documents) { d in
                        NavigationLink {
                            DocumentView(spec: d).navigationTitle(d.title.text)
                        } label: {
                            hubLabel(d.title.text, d.group.text, d.icon)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private func hubLabel(_ title: String, _ group: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Icons.symbol(icon))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(group).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One tab of a tabbed page.
enum ResourceTab: Identifiable, Hashable {
    case spec(ResourceSpec)
    case document(DocumentSpec)

    var id: String {
        switch self {
        case .spec(let s): return "s:" + s.id
        case .document(let d): return "d:" + d.id
        }
    }

    var title: String {
        switch self {
        case .spec(let s): return s.title.text
        case .document(let d): return d.title.text
        }
    }
}

/// Several specs and documents as tabs (Access, Gateway, Devices, …).
struct TabbedResourcesView: View {
    let title: String
    let tabs: [ResourceTab]
    @State private var selected: ResourceTab?

    var body: some View {
        VStack(spacing: 0) {
            if let first = tabs.first {
                SectionTabs(tabs: tabs, selection: Binding(get: { selected ?? first }, set: { selected = $0 })) { $0.title }
                Group {
                    switch selected ?? first {
                    case .spec(let s): ResourceListView(spec: s)
                    case .document(let d): DocumentView(spec: d)
                    }
                }
                .id((selected ?? first).id)
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .inlineTitle()
    }
}

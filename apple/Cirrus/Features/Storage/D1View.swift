import CirrusKit
import SwiftUI

struct D1View: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?

    var body: some View {
        QueryView("d1:" + accountId, fetch: { c in try await c.list(D1.databases(accountId), perPage: 100) }) { dbs, h in
            List(dbs, id: \.self) { d in
                let id = d["uuid"].string ?? ""
                let name = d["name"].string ?? id
                NavigationLink {
                    D1Console(accountId: accountId, databaseId: id, name: name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cylinder.split.1x2.fill").foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).fontWeight(.semibold)
                            Text(
                                [
                                    d["num_tables"].int.map { L("\($0) tables", "\($0) 张表") },
                                    d["file_size"].double.map { Format.bytes($0) }, d["version"].string,
                                    Format.date(d["created_at"], withTime: false),
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button(L("Copy ID", "复制 ID"), systemImage: "doc.on.doc") { Clipboard.copy(id) }
                    Divider()
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { prompt = deletePrompt(id, name, h) }
                }
                .swipeActions {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { prompt = deletePrompt(id, name, h) }
                }
            }
            .overlay { if dbs.isEmpty { EmptyState(title: L("No databases", "没有数据库"), symbol: "cylinder.split.1x2") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create database", "创建数据库"), systemImage: "plus") {
                        prompt = TextPrompt(title: L("Database name", "数据库名称"), placeholder: "prod-db", confirm: L("Create", "创建")) { n in
                            await model.run(L("Created", "已创建")) {
                                try await model.client?.post(D1.databases(accountId), ["name": .string(n.trimmingCharacters(in: .whitespaces))])
                            }
                            await h.reload()
                        }
                    }
                }
            }
        }
        .textPrompt($prompt)
    }

    private func deletePrompt(_ id: String, _ name: String, _ h: QueryHandle<[JSON]>) -> TextPrompt {
        typedDelete(
            L("Delete database?", "删除数据库？"), name: name,
            message: L("All data will be permanently lost.", "所有数据将永久丢失。"), feedback: model.feedback
        ) {
            await model.run(L("Deleted", "已删除")) { try await model.client?.delete(D1.database(accountId, id)) }
            await h.reload()
        }
    }
}

/// An SQL console for one database.
private struct D1Console: View {
    let accountId: String
    let databaseId: String
    let name: String
    @Environment(AppModel.self) private var model
    @State private var sql = "SELECT name, type FROM sqlite_master ORDER BY name;"
    @State private var results: [D1.Result] = []
    @State private var tables: [String] = []
    @State private var history: [String] = []
    @State private var running = false
    @State private var error: Error?
    @State private var confirm: ConfirmItem?
    @State private var jsonItem: JSONItem?

    private var base: String { D1.database(accountId, databaseId) }

    var body: some View {
        VStack(spacing: 10) {
            CodeEditor(text: $sql).frame(height: 150)
            HStack {
                Menu {
                    Section(L("Tables", "表")) {
                        ForEach(tables, id: \.self) { t in
                            Menu(t) {
                                Button(L("First 100 rows", "前 100 行"), systemImage: "tablecells") {
                                    sql = "SELECT * FROM \(D1.quote(t)) LIMIT 100;"
                                    Task { await run() }
                                }
                                Button(L("Schema", "结构"), systemImage: "list.bullet.rectangle") {
                                    sql = "PRAGMA table_info(\(D1.quote(t)));"
                                    Task { await run() }
                                }
                            }
                        }
                    }
                    if !history.isEmpty {
                        Section(L("History", "历史")) {
                            ForEach(history, id: \.self) { q in
                                Button(String(q.prefix(80))) { sql = q }
                            }
                        }
                    }
                } label: {
                    Label(L("Tables", "表"), systemImage: "tablecells")
                }
                .buttonStyle(.glass)
                Spacer()
                Button {
                    Task { await runChecked() }
                } label: {
                    HStack {
                        if running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                        Text(L("Run", "执行"))
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(running)
            }
            if let error {
                Text(describe(error)).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if results.isEmpty {
                EmptyState(title: L("Run a query to see results", "执行查询以查看结果"), symbol: "tablecells").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(results) { r in
                            Text(r.summary).font(.caption).foregroundStyle(.secondary)
                            if !r.columns.isEmpty { ResultGrid(result: r) }
                        }
                    }
                }
            }
        }
        .padding()
        .navigationTitle(name)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Database info", "数据库信息"), systemImage: "info.circle") {
                    Task {
                        let r = await model.run { try await model.client?.get(base) }
                        if let o = r, let info = o { jsonItem = JSONItem(title: name, json: info) }
                    }
                }
            }
        }
        .task { await loadTables() }
        .confirm($confirm)
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func exec(_ q: String) async throws -> [D1.Result] {
        guard let client = model.client else { return [] }
        return D1.parseRaw(try await client.post(base + "/raw", ["sql": .string(q)]))
    }

    private func loadTables() async {
        if let r = try? await exec(D1.tablesQuery) {
            tables = r.first?.rows.compactMap { $0.first?.text } ?? []
        }
    }

    private func runChecked() async {
        let q = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if D1.isDestructive(q) {
            confirm = ConfirmItem(
                title: L("Run a destructive statement?", "执行破坏性语句？"), message: q.count > 400 ? String(q.prefix(400)) + "…" : q,
                button: L("Run", "执行")
            ) { await run() }
        } else {
            await run()
        }
    }

    private func run() async {
        let q = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            results = try await exec(q)
            history.removeAll { $0 == q }
            history.insert(q, at: 0)
            if history.count > 30 { history.removeLast() }
            if D1.changesSchema(q) { await loadTables() }
        } catch {
            self.error = error
        }
    }
}

/// A scrollable grid of query results; tap a cell to copy it.
private struct ResultGrid: View {
    let result: D1.Result

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(result.columns.indices, id: \.self) { i in
                        Text(result.columns[i]).font(.caption.monospaced().weight(.bold))
                    }
                }
                Divider()
                ForEach(Array(result.rows.prefix(2000).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(result.columns.indices, id: \.self) { i in
                            let v = i < row.count ? row[i] : .null
                            Text(D1.cell(v))
                                .font(.caption.monospaced())
                                .foregroundStyle(v.isNull ? Color.secondary : Color.primary)
                                .lineLimit(3)
                                .frame(maxWidth: 320, alignment: .leading)
                                .onTapGesture { Clipboard.copy(D1.cell(v)) }
                        }
                    }
                }
            }
            .padding(12)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

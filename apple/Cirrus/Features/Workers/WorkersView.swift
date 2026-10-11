import CirrusKit
import SwiftUI

/// The account's Worker scripts with their last-24h requests.
struct WorkersView: View {
    let accountId: String

    struct Overview {
        var scripts: [JSON]
        var metrics: [String: (requests: Double, errors: Double)]
        var subdomain: String?
    }

    var body: some View {
        QueryView(
            "workers:" + accountId,
            fetch: { (c: CFClient) async throws -> Overview in
                async let scripts = c.list("/accounts/\(accountId)/workers/scripts", paginate: false)
                async let metrics = try? c.workersSummary(accountId)
                async let sub = try? c.get("/accounts/\(accountId)/workers/subdomain")
                return Overview(scripts: try await scripts, metrics: await metrics ?? [:], subdomain: await sub?["subdomain"].string)
            }
        ) { o, h in
            WorkersList(accountId: accountId, overview: o, handle: h)
        }
        .navigationTitle("Workers")
    }
}

private struct WorkersList: View {
    let accountId: String
    let overview: WorkersView.Overview
    let handle: QueryHandle<WorkersView.Overview>
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var creating = false

    private var list: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return overview.scripts
            .filter { q.isEmpty || ($0["id"].string ?? "").lowercased().contains(q) }
            .sorted { ($0["modified_on"].string ?? "") > ($1["modified_on"].string ?? "") }
    }

    var body: some View {
        List {
            Section {
                ForEach(list, id: \.self) { s in
                    let name = s["id"].string ?? ""
                    NavigationLink {
                        WorkerDetailView(accountId: accountId, script: name, subdomain: overview.subdomain)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill").foregroundStyle(.tint).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).fontWeight(.semibold)
                                Text(
                                    ([L("modified", "修改于") + " " + Format.relative(s["modified_on"])]
                                        + (s["handlers"].strings.isEmpty ? [] : [s["handlers"].strings.joined(separator: ", ")]))
                                        .joined(separator: " · ")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let m = overview.metrics[name] {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Format.count(m.requests)) req").font(.callout.weight(.semibold)).monospacedDigit()
                                    if m.errors > 0 {
                                        Text("\(Format.count(m.errors)) err").font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                if let sub = overview.subdomain { Text(sub + ".workers.dev") }
            }
        }
        .overlay {
            if overview.scripts.isEmpty {
                EmptyState(title: L("No Workers yet", "还没有 Worker"), symbol: "bolt")
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query)
        .refreshable { await handle.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Create", "创建"), systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            CreateWorkerSheet(accountId: accountId) { await handle.reload() }
        }
    }
}

private struct CreateWorkerSheet: View {
    let accountId: String
    let done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = 0
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name", "名称"), text: $name, prompt: Text("my-worker")).plainInput()
                } footer: {
                    Text(L("Lowercase letters, numbers and dashes", "小写字母、数字和短横线"))
                }
                Section {
                    Picker(L("Template", "模板"), selection: $template) {
                        ForEach(Workers.templates.indices, id: \.self) { i in Text(Workers.templates[i].name).tag(i) }
                    }
                    Text(Workers.templates[template].code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Create Worker", "创建 Worker"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Deploy", "部署")) { Task { await create() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 460)
    }

    private func create() async {
        guard let client = model.client else { return }
        let script = name.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        defer { busy = false }
        let code = Workers.templates[template].code
        let ok = await model.run(L("Worker deployed", "Worker 已部署")) { () -> Bool in
            try await client.createWorker(accountId, script, code: code)
            // Expose it on workers.dev so it is reachable right away.
            _ = try? await client.post(Workers.scriptPath(accountId, script) + "/subdomain", ["enabled": true])
            return true
        }
        if ok == true {
            await done()
            dismiss()
        }
    }
}

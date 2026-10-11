import CirrusKit
import SwiftUI

struct KVView: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?

    var body: some View {
        QueryView("kv-ns:" + accountId, fetch: { c in try await c.list(KV.namespaces(accountId), perPage: 100) }) { list, h in
            List(list, id: \.self) { ns in
                let id = ns["id"].string ?? ""
                let title = ns["title"].string ?? id
                NavigationLink {
                    KVBrowser(accountId: accountId, namespaceId: id, title: title)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).fontWeight(.semibold)
                            Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button(L("Rename", "重命名"), systemImage: "pencil") {
                        prompt = TextPrompt(title: L("Rename", "重命名"), text: title) { t in
                            await model.run { try await model.client?.put(KV.namespace(accountId, id), ["title": .string(t.trimmingCharacters(in: .whitespaces))]) }
                            await h.reload()
                        }
                    }
                    Button(L("Copy ID", "复制 ID"), systemImage: "doc.on.doc") { Clipboard.copy(id) }
                    Divider()
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { prompt = deletePrompt(id, title, h) }
                }
                .swipeActions {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { prompt = deletePrompt(id, title, h) }
                }
            }
            .overlay { if list.isEmpty { EmptyState(title: L("No namespaces", "没有命名空间"), symbol: "key") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create namespace", "创建命名空间"), systemImage: "plus") {
                        prompt = TextPrompt(title: L("Namespace name", "命名空间名称"), placeholder: "MY_KV", confirm: L("Create", "创建")) { t in
                            await model.run(L("Created", "已创建")) {
                                try await model.client?.post(KV.namespaces(accountId), ["title": .string(t.trimmingCharacters(in: .whitespaces))])
                            }
                            await h.reload()
                        }
                    }
                }
            }
        }
        .textPrompt($prompt)
    }

    private func deletePrompt(_ id: String, _ title: String, _ h: QueryHandle<[JSON]>) -> TextPrompt {
        typedDelete(
            L("Delete namespace?", "删除命名空间？"), name: title,
            message: L("All keys in it will be deleted.", "其中所有键都会被删除。"), feedback: model.feedback
        ) {
            await model.run(L("Deleted", "已删除")) { try await model.client?.delete(KV.namespace(accountId, id)) }
            await h.reload()
        }
    }
}

/// The keys of one namespace, with paging by cursor.
private struct KVBrowser: View {
    let accountId: String
    let namespaceId: String
    let title: String
    @Environment(AppModel.self) private var model
    @State private var keys: [JSON] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: Error?
    @State private var prefix = ""
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var editing: ValueItem?
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?
    @State private var importing = false
    @State private var export: DataExport?

    struct ValueItem: Identifiable {
        let id = UUID()
        var key: String
        var text: String?
        var data: Data?
        var meta: JSON
    }

    private var base: String { KV.namespace(accountId, namespaceId) }

    var body: some View {
        List {
            if let error {
                Label(describe(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(keys, id: \.self) { k in
                let name = k["name"].string ?? ""
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(name) ? Color.accentColor : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.callout.monospaced()).lineLimit(2)
                        if !k["expiration"].isNull || !k["metadata"].isNull {
                            Text(
                                [
                                    k["expiration"].isNull ? nil : L("expires", "过期") + " " + Format.date(k["expiration"]),
                                    k["metadata"].isNull ? nil : "metadata: " + k["metadata"].compactString,
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture {
                    if selecting {
                        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
                    } else {
                        Task { await open(k) }
                    }
                }
                .swipeActions {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete([name]) }
                }
            }
            if cursor != nil {
                Button(L("Load more", "加载更多")) { Task { await load() } }.disabled(loading)
            }
        }
        .overlay {
            if keys.isEmpty && error == nil {
                if loading { ProgressView() } else { EmptyState(title: L("No keys", "没有键"), symbol: "key.slash") }
            }
        }
        .searchable(text: $prefix, prompt: L("Key prefix", "键前缀"))
        .onSubmit(of: .search) { Task { await load(reset: true) } }
        .refreshable { await load(reset: true) }
        .navigationTitle(title)
        .inlineTitle()
        .toolbar { toolbar }
        .task { if keys.isEmpty { await load(reset: true) } }
        .sheet(item: $editing) { item in
            KVValueSheet(item: item) { text, ttl in await put(item.key, Data(text.utf8), ttl: ttl) } download: { data in
                export = DataExport(data: data, name: item.key.split(separator: "/").last.map(String.init) ?? item.key)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            prompt = TextPrompt(title: L("Key name", "键名"), text: url.lastPathComponent, confirm: L("Upload", "上传")) { key in
                _ = await put(key, data, ttl: nil)
            }
        }
        .textPrompt($prompt)
        .confirm($confirm)
        .dataExporter($export)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("Done", "完成")) {
                    selecting = false
                    selected = []
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete(Array(selected)) }
                    .disabled(selected.isEmpty)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Add key", "添加键"), systemImage: "plus") {
                        prompt = TextPrompt(title: L("Key name", "键名"), confirm: L("Next", "下一步")) { key in
                            guard !key.isEmpty else { return }
                            editing = ValueItem(key: key, text: "", data: nil, meta: .null)
                        }
                    }
                    Button(L("Upload file as value", "上传文件作为值"), systemImage: "square.and.arrow.up") { importing = true }
                    Button(L("Select keys", "选择键"), systemImage: "checkmark.circle") { selecting = true }
                } label: {
                    Label(L("Add", "添加"), systemImage: "plus")
                }
            }
        }
    }

    private func load(reset: Bool = false) async {
        guard let client = model.client, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if reset {
            cursor = nil
            selected = []
        }
        let p = prefix.trimmingCharacters(in: .whitespaces)
        do {
            let res = try await client.send(
                "GET", base + "/keys", query: ["limit": "1000", "prefix": p.isEmpty ? nil : p, "cursor": reset ? nil : cursor])
            let items = res.result.items
            keys = reset ? items : keys + items
            let c = res.resultInfo?["cursor"].string
            cursor = (c ?? "").isEmpty ? nil : c
        } catch {
            self.error = error
        }
    }

    private func open(_ k: JSON) async {
        let name = k["name"].string ?? ""
        let result = await model.run { try await model.client?.rawOK("GET", base + "/values/" + name.pathEncoded) }
        guard let o = result, let r = o else { return }
        editing = ValueItem(key: name, text: KV.looksText(r.data) ? r.text : nil, data: r.data, meta: k["metadata"])
    }

    private func put(_ key: String, _ data: Data, ttl: Int?) async -> Bool {
        let r = await model.run(L("Saved", "已保存")) {
            try await model.client?.send(
                "PUT", base + "/values/" + key.pathEncoded, query: ["expiration_ttl": ttl.map(String.init)],
                body: .data(data, contentType: "application/octet-stream"))
        }
        if r != nil { await load(reset: true) }
        return r != nil
    }

    private func askDelete(_ names: [String]) {
        confirm = ConfirmItem(
            title: L("Delete \(names.count) key(s)?", "删除 \(names.count) 个键？"),
            message: names.prefix(10).joined(separator: "\n") + (names.count > 10 ? "\n…" : ""), button: L("Delete", "删除")
        ) {
            let r = await model.run(L("Deleted", "已删除")) { () -> Bool in
                var i = 0
                while i < names.count {
                    let chunk = Array(names[i..<min(i + 10000, names.count)])
                    _ = try await model.client?.post(base + "/bulk/delete", .array(chunk.map(JSON.string)))
                    i += 10000
                }
                return true
            }
            if r == true {
                selecting = false
                await load(reset: true)
            }
        }
    }
}

private struct KVValueSheet: View {
    let item: KVBrowser.ValueItem
    let save: (String, Int?) async -> Bool
    let download: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var ttl = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if item.text == nil {
                    ContentUnavailableView(
                        L("Binary value", "二进制值"), systemImage: "doc.zipper",
                        description: Text(Format.bytes(Double(item.data?.count ?? 0))))
                } else {
                    CodeEditor(text: $text)
                    TextField(L("Expiration TTL in seconds (optional, ≥ 60)", "过期 TTL 秒数（可选，≥ 60）"), text: $ttl)
                        .numberInput()
                        .textFieldStyle(.roundedBorder)
                }
                if !item.meta.isNull {
                    Text("metadata: " + item.meta.compactString).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(item.key)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close", "关闭")) { dismiss() } }
                if let data = item.data {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("Download", "下载"), systemImage: "square.and.arrow.down") {
                            dismiss()
                            download(data)
                        }
                    }
                }
                if item.text != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Save", "保存")) {
                            Task { if await save(text, Int(ttl.trimmingCharacters(in: .whitespaces))) { dismiss() } }
                        }
                    }
                }
            }
            .onAppear { text = item.text ?? "" }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

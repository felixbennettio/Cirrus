import CirrusKit
import SwiftUI

struct R2View: View {
    let accountId: String
    @State private var creating = false

    var body: some View {
        QueryView(
            "r2-buckets:" + accountId,
            fetch: { c in R2.parseBuckets(try await c.send("GET", R2.buckets(accountId), query: ["per_page": "1000"]).result) }
        ) { buckets, h in
            List(buckets, id: \.self) { b in
                let name = b["name"].string ?? ""
                NavigationLink {
                    R2BucketView(accountId: accountId, bucket: name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).fontWeight(.semibold)
                            Text(
                                [
                                    b["location"].string, b["storage_class"].string,
                                    b["jurisdiction"].string.flatMap { $0 == "default" ? nil : $0 },
                                    Format.date(b["creation_date"], withTime: false),
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay { if buckets.isEmpty { EmptyState(title: L("No buckets", "没有存储桶"), symbol: "shippingbox") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create bucket", "创建存储桶"), systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) { CreateBucketSheet(accountId: accountId) { await h.reload() } }
        }
    }
}

private struct CreateBucketSheet: View {
    let accountId: String
    let done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = ""
    @State private var storageClass = "Standard"

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Bucket name", "存储桶名称"), text: $name).plainInput()
                Picker(L("Location hint", "位置提示"), selection: $location) {
                    Text(L("Automatic", "自动")).tag("")
                    ForEach(R2.locations, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker(L("Default storage class", "默认存储类型"), selection: $storageClass) {
                    Text("Standard").tag("Standard")
                    Text("Infrequent Access").tag("InfrequentAccess")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Create bucket", "创建存储桶"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Create", "创建")) { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }

    private func create() async {
        var body: JSON = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "storageClass": .string(storageClass)]
        if !location.isEmpty { body = body.setting("locationHint", to: .string(location)) }
        let r = await model.run(L("Bucket created", "存储桶已创建")) { try await model.client?.post(R2.buckets(accountId), body) }
        if r != nil {
            await done()
            dismiss()
        }
    }
}

struct R2BucketView: View {
    let accountId: String
    let bucket: String

    enum Part: String, CaseIterable, Identifiable {
        case objects, settings, domains
        var id: String { rawValue }
        var title: String {
            switch self {
            case .objects: return L("Objects", "对象")
            case .settings: return L("Settings", "设置")
            case .domains: return L("Custom domains", "自定义域")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var part = Part.objects
    @State private var prompt: TextPrompt?

    var body: some View {
        VStack(spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
            Group {
                switch part {
                case .objects: R2Objects(accountId: accountId, bucket: bucket)
                case .settings: R2Settings(base: R2.bucket(accountId, bucket))
                case .domains: R2Domains(base: R2.bucket(accountId, bucket))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(bucket)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Delete bucket", "删除存储桶"), systemImage: "trash", role: .destructive) {
                        prompt = typedDelete(
                            L("Delete bucket?", "删除存储桶？"), name: bucket, message: L("The bucket must be empty.", "存储桶必须为空。"),
                            feedback: model.feedback
                        ) {
                            let r = await model.run(L("Deleted", "已删除")) { try await model.client?.send("DELETE", R2.bucket(accountId, bucket)) }
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

/// Browses objects folder by folder (`/` as the delimiter).
private struct R2Objects: View {
    let accountId: String
    let bucket: String
    @Environment(AppModel.self) private var model
    @State private var prefix = ""
    @State private var objects: [JSON] = []
    @State private var folders: [String] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: Error?
    @State private var uploading: String?
    @State private var importing = false
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?
    @State private var export: DataExport?
    @State private var preview: Preview?
    @State private var jsonItem: JSONItem?

    struct Preview: Identifiable {
        let id = UUID()
        var key: String
        var contentType: String
        var data: Data
    }

    private var crumbs: [String] { prefix.isEmpty ? [] : prefix.dropLast().split(separator: "/").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { cd("") } label: { Label(bucket, systemImage: "house") }
                    ForEach(crumbs.indices, id: \.self) { i in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        Button(crumbs[i]) { cd(crumbs[0...i].joined(separator: "/") + "/") }
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            if let uploading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Uploading \(uploading)…", "正在上传 \(uploading)…")).font(.caption)
                }
                .padding(.horizontal)
            }
            List {
                if let error { Label(describe(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if !prefix.isEmpty {
                    Button {
                        let parts = crumbs.dropLast()
                        cd(parts.isEmpty ? "" : parts.joined(separator: "/") + "/")
                    } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(folders, id: \.self) { f in
                    Button { cd(f) } label: {
                        Label(String(f.dropFirst(prefix.count)), systemImage: "folder.fill").foregroundStyle(Color.primary)
                    }
                }
                ForEach(objects, id: \.self) { o in
                    objectRow(o)
                }
                if cursor != nil {
                    Button(L("Load more", "加载更多")) { Task { await load() } }.disabled(loading)
                }
            }
            .overlay {
                if objects.isEmpty && folders.isEmpty && error == nil {
                    if loading { ProgressView() } else { EmptyState(title: L("Empty", "空"), symbol: "folder") }
                }
            }
            .refreshable { await load(reset: true) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Upload files", "上传文件"), systemImage: "square.and.arrow.up") { importing = true }
                    Button(L("New folder", "新建文件夹"), systemImage: "folder.badge.plus") {
                        prompt = TextPrompt(title: L("Folder name", "文件夹名称"), confirm: L("Open", "打开")) { name in
                            // Folders are implicit in R2: open the prefix; it stays once a file is uploaded.
                            let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "")
                            if !n.isEmpty { cd(prefix + n + "/") }
                        }
                    }
                } label: {
                    Label(L("Upload", "上传"), systemImage: "plus")
                }
                .disabled(uploading != nil)
            }
        }
        .task { if objects.isEmpty && folders.isEmpty { await load(reset: true) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await upload(urls) }
        }
        .textPrompt($prompt)
        .confirm($confirm)
        .dataExporter($export)
        .sheet(item: $preview) { p in R2PreviewSheet(preview: p) }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }

    private func objectRow(_ o: JSON) -> some View {
        let key = o["key"].string ?? ""
        return HStack(spacing: 12) {
            Image(systemName: R2.symbol(for: key)).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(key.dropFirst(prefix.count))).lineLimit(2)
                Text(
                    [Format.bytes(o["size"].double), Format.date(o["last_modified"]), o["storage_class"].string]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { Task { await open(o) } }
        .contextMenu {
            Button(L("Download", "下载"), systemImage: "square.and.arrow.down") { Task { await download(key) } }
            Button(L("Details", "详情"), systemImage: "info.circle") { jsonItem = JSONItem(title: key, json: o) }
            Button(L("Copy key", "复制键名"), systemImage: "doc.on.doc") { Clipboard.copy(key) }
            Divider()
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete(key) }
        }
        .swipeActions {
            Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { askDelete(key) }
            Button(L("Download", "下载"), systemImage: "square.and.arrow.down") { Task { await download(key) } }
        }
    }

    private func cd(_ p: String) {
        prefix = p
        Task { await load(reset: true) }
    }

    private func load(reset: Bool = false) async {
        guard let client = model.client else { return }
        if reset {
            cursor = nil
        } else if loading {
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        let p = prefix
        do {
            let res = try await client.send(
                "GET", R2.bucket(accountId, bucket) + "/objects",
                query: ["prefix": p, "delimiter": "/", "per_page": "1000", "cursor": reset ? nil : cursor])
            guard p == prefix else { return }
            let l = R2.parseListing(res, prefix: p)
            objects = reset ? l.objects : objects + l.objects
            folders = reset ? l.folders : folders + l.folders.filter { !folders.contains($0) }
            cursor = l.cursor
        } catch {
            if p == prefix { self.error = error }
        }
    }

    private func open(_ o: JSON) async {
        let key = o["key"].string ?? ""
        let size = o["size"].double ?? 0
        let ct = o["http_metadata"]["contentType"].string ?? R2.mimeType(for: key)
        guard R2.previewKind(contentType: ct) != nil, size <= 5 * 1024 * 1024 else {
            jsonItem = JSONItem(title: key, json: o)
            return
        }
        let result = await model.run { try await model.client?.rawOK("GET", R2.object(accountId, bucket, key)) }
        guard let r = result, let res = r else { return }
        preview = Preview(key: key, contentType: ct, data: res.data)
    }

    private func download(_ key: String) async {
        let result = await model.run { try await model.client?.rawOK("GET", R2.object(accountId, bucket, key)) }
        guard let r = result, let res = r else { return }
        export = DataExport(data: res.data, name: key.split(separator: "/").last.map(String.init) ?? key)
    }

    private func upload(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            uploading = name
            let r = await model.run {
                try await model.client?.rawOK(
                    "PUT", R2.object(accountId, bucket, prefix + name), body: .data(data, contentType: R2.mimeType(for: name)))
            }
            if r == nil { break }
        }
        uploading = nil
        model.feedback.show(L("Upload complete", "上传完成"))
        await load(reset: true)
    }

    private func askDelete(_ key: String) {
        confirm = ConfirmItem(title: L("Delete object?", "删除对象？"), message: key, button: L("Delete", "删除")) {
            await model.run(L("Deleted", "已删除")) { try await model.client?.send("DELETE", R2.object(accountId, bucket, key)) }
            await load(reset: true)
        }
    }
}

private struct R2PreviewSheet: View {
    let preview: R2Objects.Preview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if R2.previewKind(contentType: preview.contentType) == .image, let img = platformImage(preview.data) {
                    ScrollView([.horizontal, .vertical]) { img.resizable().scaledToFit().frame(maxWidth: 1200) }
                } else {
                    ScrollView {
                        Text(String(decoding: preview.data, as: UTF8.self))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle(preview.key)
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } } }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct R2Settings: View {
    let base: String
    @Environment(AppModel.self) private var model
    @State private var editor: (title: String, path: String, text: String)?

    struct Info {
        var info: JSON?
        var cors: JSON?
        var lifecycle: JSON?
        var managed: JSON?
    }

    var body: some View {
        QueryView(
            "r2-settings:" + base,
            fetch: { (c: CFClient) async throws -> Info in
                async let info = try? c.get(base)
                async let cors = try? c.get(base + "/cors")
                async let lifecycle = try? c.get(base + "/lifecycle")
                async let managed = try? c.get(base + "/domains/managed")
                return Info(info: await info, cors: await cors, lifecycle: await lifecycle, managed: await managed)
            }
        ) { d, h in
            Form {
                if let info = d.info?.object {
                    Section(L("Bucket", "存储桶")) {
                        ForEach(info.keys.sorted(), id: \.self) { k in
                            if let v = info[k], v.array == nil, v.object == nil { InfoRow(k, v.text) }
                        }
                    }
                }
                Section(L("Public access (r2.dev)", "公共访问（r2.dev）")) {
                    Toggle(
                        L("Allow access via r2.dev subdomain", "允许通过 r2.dev 子域名访问"),
                        isOn: Binding(get: { d.managed?["enabled"].isTrue ?? false }, set: { v in
                            Task {
                                await model.run { try await model.client?.put(base + "/domains/managed", ["enabled": .bool(v)]) }
                                await h.reload()
                            }
                        })
                    )
                    .disabled(d.managed == nil)
                    if let domain = d.managed?["domain"].string { InfoRow("URL", "https://" + domain, mono: true, copy: true) }
                }
                jsonSection("CORS", path: base + "/cors", value: d.cors ?? ["rules": []])
                jsonSection(L("Lifecycle rules", "生命周期规则"), path: base + "/lifecycle", value: d.lifecycle ?? ["rules": []])
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
                if let e = editor {
                    JSONEditorSheet(title: e.title, text: e.text) { text in
                        guard let parsed = try? JSON.parse(text) else {
                            model.feedback.show(L("Invalid JSON", "JSON 格式错误"), error: true)
                            return false
                        }
                        let r = await model.run(L("Saved", "已保存")) { try await model.client?.put(e.path, parsed) }
                        await h.reload()
                        return r != nil
                    }
                }
            }
        }
    }

    private func jsonSection(_ title: String, path: String, value: JSON) -> some View {
        Section(title) {
            Text(value.prettyString).font(.caption.monospaced()).lineLimit(12).textSelection(.enabled)
            Button(L("Edit", "编辑"), systemImage: "pencil") { editor = (title, path, value.prettyString) }
        }
    }
}

private struct R2Domains: View {
    let base: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    var body: some View {
        QueryView("r2-domains:" + base, fetch: { (c: CFClient) async throws -> [JSON] in
            let r = try await c.get(base + "/domains/custom")
            return r.array ?? r["domains"].items
        }) { domains, h in
            List {
                ForEach(domains, id: \.self) { d in
                    let domain = d["domain"].string ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain)
                        Text("\(d["status"]["ssl"].string ?? "") · \(d["status"]["ownership"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(L("Disconnect", "断开"), systemImage: "link", role: .destructive) {
                            confirm = ConfirmItem(title: L("Disconnect \(domain)?", "断开 \(domain)？"), button: L("Disconnect", "断开")) {
                                await model.run { try await model.client?.delete(base + "/domains/custom/" + domain) }
                                await h.reload()
                            }
                        }
                    }
                }
                Button(L("Connect domain", "连接域名"), systemImage: "plus") {
                    let zoneId = model.zoneId
                    prompt = TextPrompt(
                        title: L("Domain", "域名"), placeholder: "files." + (model.zoneName.isEmpty ? "example.com" : model.zoneName),
                        confirm: L("Connect", "连接")
                    ) { domain in
                        var body: JSON = ["domain": .string(domain.trimmingCharacters(in: .whitespaces)), "enabled": true]
                        if let zoneId { body = body.setting("zoneId", to: .string(zoneId)) }
                        await model.run(L("Domain connected", "域名已连接")) { try await model.client?.post(base + "/domains/custom", body) }
                        await h.reload()
                    }
                }
            }
            .overlay { if domains.isEmpty { EmptyState(title: L("No custom domains", "没有自定义域"), symbol: "globe") } }
            .refreshable { await h.reload() }
        }
        .textPrompt($prompt)
        .confirm($confirm)
    }
}

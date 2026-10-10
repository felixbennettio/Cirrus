import CirrusKit
import SwiftUI
import UniformTypeIdentifiers

struct DNSView: View {
    let zone: ZoneRef

    var body: some View {
        QueryView(
            "dns:" + zone.id,
            fetch: { c in
                try await c.list("/zones/\(zone.id)/dns_records", query: ["order": "type"], perPage: 1000, maxItems: 100_000)
            }
        ) { records, h in
            DNSList(zone: zone, all: records, handle: h)
        }
        .navigationTitle("DNS")
        .toolbar { ZoneToolbar() }
    }
}

private struct DNSList: View {
    let zone: ZoneRef
    let all: [JSON]
    let handle: QueryHandle<[JSON]>

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var type = "ALL"
    @State private var proxied: Bool?
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var editing: JSONItem?
    @State private var adding = false
    @State private var deleting: [JSON] = []
    @State private var jsonItem: JSONItem?
    @State private var export: ExportItem?
    @State private var importing = false
    @State private var importFile: (name: String, data: Data)?
    @State private var importProxied = false
    @State private var showDNSSEC = false
    @State private var showSettings = false

    private var base: String { "/zones/\(zone.id)/dns_records" }

    private var types: [String] { Array(Set(all.compactMap { $0["type"].string })).sorted() }

    private var list: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { r in
            if type != "ALL" && r["type"].string != type { return false }
            if let proxied, r["proxied"].isTrue != proxied { return false }
            if q.isEmpty { return true }
            let text = [r["name"].string, r["content"].text, r["comment"].string, r["tags"].strings.joined(separator: " ")]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return text.contains(q)
        }
        .sorted {
            let a = $0["name"].string ?? "", b = $1["name"].string ?? ""
            return a != b ? a < b : ($0["type"].string ?? "") < ($1["type"].string ?? "")
        }
    }

    var body: some View {
        let list = self.list
        List {
            Section {
                ForEach(list, id: \.self) { r in
                    let id = r["id"].string ?? ""
                    DNSRecordRow(
                        record: r, relName: DNSCatalog.relativeName(r["name"].string ?? "", zone: zone.name),
                        selecting: selecting, selected: selected.contains(id),
                        toggleProxy: { Task { await toggleProxy(r) } }
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        if selecting {
                            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                        } else {
                            editing = JSONItem(title: "", json: r)
                        }
                    }
                    .contextMenu {
                        Button(L("Edit", "编辑"), systemImage: "pencil") { editing = JSONItem(title: "", json: r) }
                        Button(L("Copy content", "复制内容"), systemImage: "doc.on.doc") { Clipboard.copy(r["content"].text ?? "") }
                        Button(L("View JSON", "查看 JSON"), systemImage: "curlybraces") {
                            jsonItem = JSONItem(title: "\(r["type"].string ?? "") \(r["name"].string ?? "")", json: r)
                        }
                        Divider()
                        Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { deleting = [r] }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) { deleting = [r] }
                    }
                    .swipeActions(edge: .leading) {
                        if DNSCatalog.proxiable.contains(r["type"].string ?? "") {
                            Button(r["proxied"].isTrue ? L("DNS only", "仅 DNS") : L("Proxy", "代理"), systemImage: "cloud") {
                                Task { await toggleProxy(r) }
                            }
                            .tint(.orange)
                        }
                    }
                }
            } header: {
                Text(L("\(list.count) of \(all.count) records", "\(list.count) / \(all.count) 条记录"))
            }
        }
        .overlay {
            if all.isEmpty {
                EmptyState(title: L("No records", "没有记录"), symbol: "server.rack")
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: L("Search name, content, comment, tag", "搜索名称、内容、备注、标签"))
        .refreshable { await handle.reload() }
        .toolbar { toolbar }
        .sheet(isPresented: $adding) {
            DNSRecordEditor(zoneName: zone.name) { body in
                let r = await model.run(L("Record added", "记录已添加")) { try await model.client?.post(base, body) }
                return await reloaded(r != nil)
            }
        }
        .sheet(item: $editing) { item in
            let id = item.json["id"].string ?? ""
            DNSRecordEditor(zoneName: zone.name, record: item.json) { body in
                let r = await model.run(L("Record updated", "记录已更新")) { try await model.client?.patch("\(base)/\(id)", body) }
                return await reloaded(r != nil)
            }
        }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
        .sheet(isPresented: $showDNSSEC) { DNSSECSheet(zoneId: zone.id) }
        .sheet(isPresented: $showSettings) { DNSSettingsSheet(zoneId: zone.id) }
        .confirmationDialog(
            deleting.count == 1 ? L("Delete record?", "删除记录？") : L("Delete \(deleting.count) records?", "删除 \(deleting.count) 条记录？"),
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            let recs = deleting
            Button(L("Delete", "删除"), role: .destructive) { Task { await delete(recs) } }
        } message: {
            Text(
                deleting.prefix(8).map { "\($0["type"].string ?? "")  \($0["name"].string ?? "")  →  \($0["content"].text ?? "")" }
                    .joined(separator: "\n") + (deleting.count > 8 ? "\n…" : ""))
        }
        .exporter($export)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                importFile = (url.lastPathComponent, data)
            } else {
                model.feedback.show(L("Couldn't read the file.", "无法读取文件。"), error: true)
            }
        }
        .alert(
            L("Import BIND file", "导入 BIND 文件"),
            isPresented: Binding(get: { importFile != nil }, set: { if !$0 { importFile = nil } })
        ) {
            Button(L("Import (DNS only)", "导入（仅 DNS）")) { Task { await runImport(proxied: false) } }
            Button(L("Import and proxy A/AAAA/CNAME", "导入并代理 A/AAAA/CNAME")) { Task { await runImport(proxied: true) } }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            if let f = importFile { Text("\(f.name) · \(Format.bytes(Double(f.data.count)))") }
        }
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
                Button(L("Select all", "全选"), systemImage: "checklist") {
                    selected = Set(list.compactMap { $0["id"].string })
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                    deleting = all.filter { selected.contains($0["id"].string ?? "") }
                }
                .disabled(selected.isEmpty)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Add record", "添加记录"), systemImage: "plus") { adding = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("Type", "类型"), selection: $type) {
                        Text(L("All types", "全部类型")).tag("ALL")
                        ForEach(types, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(L("Proxy status", "代理状态"), selection: $proxied) {
                        Text(L("All", "全部")).tag(Bool?.none)
                        Text(L("Proxied", "已代理")).tag(Bool?.some(true))
                        Text(L("DNS only", "仅 DNS")).tag(Bool?.some(false))
                    }
                    Divider()
                    Button(L("Select records", "选择记录"), systemImage: "checkmark.circle") { selecting = true }
                    Divider()
                    Button(L("Import BIND file…", "导入 BIND 文件…"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(L("Export BIND file", "导出 BIND 文件"), systemImage: "square.and.arrow.up") { Task { await exportZone() } }
                    Divider()
                    Button("DNSSEC", systemImage: "checkmark.shield") { showDNSSEC = true }
                    Button(L("DNS settings", "DNS 设置"), systemImage: "gearshape") { showSettings = true }
                } label: {
                    Label(L("More", "更多"), systemImage: type == "ALL" && proxied == nil ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }

    /// Reloads after a successful write; returns whether it succeeded.
    private func reloaded(_ ok: Bool) async -> Bool {
        if ok { await handle.reload() }
        return ok
    }

    private func toggleProxy(_ r: JSON) async {
        guard let id = r["id"].string else { return }
        let v = !r["proxied"].isTrue
        handle.set(all.map { $0["id"].string == id ? $0.setting("proxied", to: .bool(v)) : $0 })
        let r = await model.run { try await model.client?.patch("\(base)/\(id)", ["proxied": .bool(v)]) }
        if r == nil { await handle.reload() }
    }

    private func delete(_ recs: [JSON]) async {
        let ids = recs.compactMap { $0["id"].string }
        let ok = await model.run(L("Deleted", "已删除")) { () -> Bool in
            guard let client = model.client else { return false }
            if ids.count == 1 {
                try await client.delete("\(base)/\(ids[0])")
            } else {
                // The batch API takes up to 200 operations per call.
                var i = 0
                while i < ids.count {
                    let chunk = ids[i..<min(i + 200, ids.count)]
                    try await client.post("\(base)/batch", ["deletes": .array(chunk.map { ["id": .string($0)] })])
                    i += 200
                }
            }
            return true
        }
        if ok == true {
            selected = []
            selecting = false
            await handle.reload()
        }
    }

    private func exportZone() async {
        let result = await model.run { try await model.client?.rawOK("GET", "\(base)/export") }
        guard let response = result, let r = response else { return }
        export = ExportItem(file: TextFile(r.text), name: zone.name + ".txt")
    }

    private func runImport(proxied: Bool) async {
        guard let f = importFile else { return }
        importFile = nil
        var form = MultipartForm()
        form.addFile("file", filename: f.name, contentType: "text/plain", data: f.data)
        form.add("proxied", proxied ? "true" : "false")
        let result = await model.run { try await model.client?.send("POST", "\(base)/import", body: .multipart(form)) }
        guard let response = result, let res = response else { return }
        let added = res.result["recs_added"].text ?? "?"
        let total = res.result["total_records_parsed"].text ?? "?"
        model.feedback.show(L("Imported \(added) of \(total) records", "已导入 \(added) / \(total) 条记录"))
        await handle.reload()
    }
}

private struct DNSRecordRow: View {
    let record: JSON
    let relName: String
    let selecting: Bool
    let selected: Bool
    let toggleProxy: () -> Void

    private var notes: String {
        var parts: [String] = []
        if let c = record["comment"].string, !c.isEmpty { parts.append("💬 " + c) }
        parts += record["tags"].strings.map { "#" + $0 }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        let type = record["type"].string ?? ""
        let proxiable = DNSCatalog.proxiable.contains(type)
        let proxied = record["proxied"].isTrue
        let content = [record["priority"].text, record["content"].text].compactMap { $0 }.joined(separator: " ")
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.title3)
            }
            Text(type)
                .font(.caption.weight(.bold))
                .frame(width: 58)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(relName).fontWeight(.semibold).lineLimit(1)
                Text(content).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                if !notes.isEmpty { Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Text(Format.ttl(record["ttl"])).font(.caption).foregroundStyle(.secondary)
            if proxiable {
                Button(action: toggleProxy) {
                    Image(systemName: proxied ? "cloud.fill" : "cloud")
                        .foregroundStyle(proxied ? Color.orange : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(selecting)
                .help(proxied ? L("Proxied — click to make DNS only", "已代理——点击切换为仅 DNS") : L("DNS only — click to proxy", "仅 DNS——点击开启代理"))
            } else {
                Color.clear.frame(width: 24, height: 1)
            }
        }
    }
}

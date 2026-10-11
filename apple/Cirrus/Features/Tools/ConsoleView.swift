import CirrusKit
import SwiftUI
import UniformTypeIdentifiers

/// Waits for the API catalog, then shows [content].
struct CatalogRequired<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: (APICatalog) -> Content

    var body: some View {
        Group {
            if let c = model.catalog.catalog {
                content(c)
            } else if let e = model.catalog.error {
                ErrorState(error: SimpleError(e)) { Task { _ = await model.catalog.load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { _ = await model.catalog.load() }
    }
}

struct MethodBadge: View {
    let method: String

    var body: some View {
        let color: Color =
            switch method {
            case "GET": .blue
            case "POST": .green
            case "PUT", "PATCH": .orange
            case "DELETE": .red
            default: .secondary
            }
        Text(method)
            .font(.caption2.weight(.bold).monospaced())
            .frame(width: 52)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 5))
    }
}

/// Every API endpoint: browse by product, search, starred and history.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var mode = 0

    var body: some View {
        CatalogRequired { catalog in
            List {
                Section {
                    Picker("", selection: $mode) {
                        Text(L("Browse", "浏览")).tag(0)
                        Text(L("Starred", "收藏")).tag(1)
                        Text(L("History", "历史")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                content(catalog)
            }
            .searchable(text: $query, prompt: L("Search endpoints (e.g. \"dns create\")", "搜索接口（如 \"dns create\"）"))
            .navigationTitle(L("API console", "API 控制台"))
        }
    }

    @ViewBuilder private func content(_ catalog: APICatalog) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count >= 2 {
            Section(L("Results", "结果")) {
                ForEach(catalog.search(q, limit: 300)) { op in OperationLink(op: op, catalog: catalog) }
            }
        } else if mode == 1 {
            let ops = model.settings.favoriteOps.compactMap { catalog.operation($0) }
            if ops.isEmpty {
                Text(L("No favorites yet", "还没有收藏")).foregroundStyle(.secondary)
            }
            ForEach(ops) { op in OperationLink(op: op, catalog: catalog) }
        } else if mode == 2 {
            if model.consoleHistory.isEmpty {
                Text(L("No requests yet", "还没有请求")).foregroundStyle(.secondary)
            }
            ForEach(model.consoleHistory) { h in
                if let op = catalog.operation(h.opId) {
                    OperationLink(op: op, catalog: catalog, detail: "\(h.status) · \(Format.relative(h.at)) · \(h.path)")
                }
            }
        } else {
            Section {
                ForEach(catalog.byProduct, id: \.product) { group in
                    DisclosureGroup {
                        ForEach(group.operations) { op in OperationLink(op: op, catalog: catalog) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(group.product).fontWeight(.semibold)
                            Text(L("\(group.operations.count) endpoints", "\(group.operations.count) 个接口")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L("\(catalog.operations.count) endpoints", "\(catalog.operations.count) 个接口"))
            }
        }
    }
}

struct OperationLink: View {
    let op: APIOperation
    let catalog: APICatalog
    var detail: String?

    var body: some View {
        NavigationLink {
            OperationRunnerView(op: op, catalog: catalog)
        } label: {
            HStack(spacing: 10) {
                MethodBadge(method: op.method)
                VStack(alignment: .leading, spacing: 2) {
                    Text(op.summary.isEmpty ? op.path : op.summary).lineLimit(1)
                    Text(detail ?? op.path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if op.deprecated { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }
}

/// Sends one API request with parameters and a body.
struct OperationRunnerView: View {
    let op: APIOperation
    let catalog: APICatalog
    @Environment(AppModel.self) private var model
    @State private var params: [String: String] = [:]
    @State private var bodyText = ""
    @State private var multipart: [String: String] = [:]
    @State private var files: [String: (name: String, data: Data)] = [:]
    @State private var rawFile: (name: String, data: Data)?
    @State private var response: CFRawResponse?
    @State private var error: String?
    @State private var sending = false
    @State private var loaded = false
    @State private var paywall = false
    @State private var confirmSend = false
    @State private var schemaEditor: SchemaRequest?
    @State private var secrets: SecretItem?
    @State private var json: JSONItem?
    @State private var importingFor: String?
    @State private var export: DataExport?

    var body: some View {
        Form {
            Section {
                HStack {
                    MethodBadge(method: op.method)
                    Text(op.path).font(.callout.monospaced()).textSelection(.enabled)
                }
                Text(op.summary).font(.headline)
                if let d = op.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                Text(tagsLine).font(.caption2).foregroundStyle(.secondary)
            }
            if !op.pathParams.isEmpty {
                Section(L("Path parameters", "路径参数")) { ForEach(op.pathParams, id: \.name) { paramField($0) } }
            }
            if !op.queryParams.isEmpty {
                Section(L("Query parameters (\(op.queryParams.count))", "查询参数（\(op.queryParams.count)）")) {
                    ForEach(op.queryParams, id: \.name) { paramField($0) }
                }
            }
            if !op.headerParams.isEmpty {
                Section(L("Headers (\(op.headerParams.count))", "请求头（\(op.headerParams.count)）")) {
                    ForEach(op.headerParams, id: \.name) { paramField($0) }
                }
            }
            if let body = op.body { bodySection(body) }
            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if sending { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
                        Text(L("Send", "发送")).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .disabled(sending)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Button(L("Copy as cURL (secrets masked)", "复制为 cURL（已隐藏密钥）"), systemImage: "terminal") {
                    let body = op.body?.isJSON == true ? try? JSON.parse(bodyText) : nil
                    if let c = model.client { Clipboard.copy(c.curl(op.method, path, query: query, body: body)) }
                    model.feedback.show(L("cURL copied", "已复制 cURL"))
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if let response { responseSection(response) }
        }
        .formStyle(.grouped)
        .navigationTitle(op.summary.isEmpty ? op.id : op.summary)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let starred = model.settings.favoriteOps.contains(op.id)
                Button(starred ? L("Unstar", "取消收藏") : L("Star", "收藏"), systemImage: starred ? "star.fill" : "star") {
                    model.toggleFavorite(op.id)
                }
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $paywall) { PaywallSheet(feature: .consoleWrites) }
        .confirmationDialog(L("Send \(op.method) request?", "发送 \(op.method) 请求？"), isPresented: $confirmSend, titleVisibility: .visible) {
            Button(L("Send", "发送"), role: op.method == "DELETE" ? ButtonRole.destructive : nil) { Task { await perform() } }
        } message: {
            Text(path)
        }
        .resourceSheets(schema: $schemaEditor, secrets: $secrets, json: $json)
        .fileImporter(isPresented: Binding(get: { importingFor != nil }, set: { if !$0 { importingFor = nil } }), allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result, let key = importingFor else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            if key == "__raw__" { rawFile = (url.lastPathComponent, data) } else { files[key] = (url.lastPathComponent, data) }
        }
        .dataExporter($export)
    }

    private var tagsLine: String {
        var tags = [op.group]
        if op.deprecated { tags.append(L("Deprecated", "已弃用")) }
        if let a = op.availability { tags.append(a) }
        tags.append(contentsOf: op.permissions)
        return tags.joined(separator: " · ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        for p in op.params where p.location == "path" {
            if let outer = model.scopeIds[p.name], let v = outer { params["path:" + p.name] = v }
        }
        if let body = op.body, body.isJSON {
            let sk = catalog.skeleton(body.schema)
            bodyText = sk.isNull ? "{}" : sk.prettyString
        }
    }

    private func paramField(_ p: APIParam) -> some View {
        let s = catalog.resolve(p.schema)
        let key = p.location + ":" + p.name
        let binding = Binding(get: { params[key] ?? "" }, set: { params[key] = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            if let options = s["enum"].array, !options.isEmpty {
                Picker(p.name + (p.required ? " *" : ""), selection: binding) {
                    Text("—").tag("")
                    ForEach(options.compactMap(\.text), id: \.self) { Text($0).tag($0) }
                }
            } else {
                LabeledContent(p.name + (p.required ? " *" : "")) {
                    TextField(s["example"].text ?? s["type"].text ?? "", text: binding)
                        .plainInput()
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospaced())
                }
            }
            if let d = p.description { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
        }
    }

    @ViewBuilder private func bodySection(_ body: APIBody) -> some View {
        if body.isMultipart {
            Section("multipart/form-data") {
                let props = (catalog.resolve(body.schema)["properties"].object ?? [:]).keys.sorted()
                ForEach(props, id: \.self) { name in
                    HStack {
                        TextField(name, text: Binding(get: { multipart[name] ?? "" }, set: { multipart[name] = $0 })).plainInput()
                        if let f = files[name] { Text("📎 " + f.name).font(.caption).lineLimit(1) }
                        Button(L("Attach file", "附加文件"), systemImage: "paperclip") { importingFor = name }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
        } else {
            Section {
                CodeEditor(text: $bodyText).frame(minHeight: 200)
                if body.isJSON {
                    HStack {
                        Button(L("Form", "表单"), systemImage: "list.bullet.rectangle") {
                            let initial = (try? JSON.parse(bodyText)).flatMap { $0.object != nil ? $0 : nil } ?? [:]
                            schemaEditor = SchemaRequest(title: op.summary, schema: body.schema, initial: initial, submitLabel: L("Apply", "应用")) { v in
                                bodyText = v.prettyString
                                return true
                            }
                        }
                        Spacer()
                        Button(L("Format", "格式化")) {
                            if let v = try? JSON.parse(bodyText) { bodyText = v.prettyString } else { model.feedback.show(L("Invalid JSON", "JSON 格式错误"), error: true) }
                        }
                        Button(L("Required only", "仅必填")) { bodyText = catalog.skeleton(body.schema, requiredOnly: true).prettyString }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(rawFile?.name ?? L("Use file", "使用文件"), systemImage: "paperclip") { importingFor = "__raw__" }
                }
            } header: {
                Text(L("Request body", "请求体") + " · " + body.contentType)
            }
        }
    }

    private func responseSection(_ r: CFRawResponse) -> some View {
        let ok = r.ok
        let ct = r.header("content-type") ?? ""
        let looksJSON = ct.contains("json") || r.data.first == UInt8(ascii: "{") || r.data.first == UInt8(ascii: "[")
        var parsed: JSON?
        if looksJSON { parsed = try? JSON.parse(r.data) }
        let text = parsed?.prettyString ?? (KV.looksText(r.data) ? r.text : L("Binary response", "二进制响应") + " · " + Format.bytes(Double(r.data.count)))
        return Section {
            HStack {
                StatusBadge("\(r.statusCode)", tone: ok ? .good : .bad)
                Text(String(format: "%.0f ms", r.duration * 1000)).font(.caption).foregroundStyle(.secondary)
                Text(Format.bytes(Double(r.data.count))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(text) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                Button(L("Save", "保存"), systemImage: "square.and.arrow.down") { export = DataExport(data: r.data, name: op.id + (parsed != nil ? ".json" : ".bin")) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            ScrollView(.horizontal) {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).lineLimit(400)
            }
        } header: {
            Text(L("Response", "响应"))
        }
    }

    private var path: String {
        var p = op.path
        for param in op.pathParams {
            let v = (params["path:" + param.name] ?? "").trimmingCharacters(in: .whitespaces)
            p = p.replacingOccurrences(of: "{\(param.name)}", with: param.name == "model_name" ? v : v.pathEncoded)
        }
        return p
    }

    private var query: [String: String?] {
        var q: [String: String?] = [:]
        for p in op.queryParams {
            let v = (params["query:" + p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { q[p.name] = v }
        }
        return q
    }

    private func send() async {
        if op.isMutation && !model.pro.hasPro {
            paywall = true
            return
        }
        let missing = op.params.filter { $0.required && (params[$0.location + ":" + $0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if !missing.isEmpty {
            error = L("Missing required: \(missing.map(\.name).joined(separator: ", "))", "缺少必填参数：\(missing.map(\.name).joined(separator: "、"))")
            return
        }
        if op.isMutation && model.settings.confirmMutations {
            confirmSend = true
        } else {
            await perform()
        }
    }

    private func perform() async {
        guard let client = model.client else { return }
        var requestBody: RequestBody?
        if let body = op.body {
            if body.isJSON {
                let t = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    guard let v = try? JSON.parse(t) else {
                        error = L("Body is not valid JSON", "请求体不是合法的 JSON")
                        return
                    }
                    requestBody = .json(v)
                }
            } else if body.isMultipart {
                var form = MultipartForm()
                for (k, f) in files { form.addFile(k, filename: f.name, data: f.data) }
                for (k, v) in multipart where files[k] == nil && !v.isEmpty { form.add(k, v) }
                requestBody = .multipart(form)
            } else {
                requestBody = .data(rawFile?.data ?? Data(bodyText.utf8), contentType: body.contentType)
            }
        }
        var headers: [String: String] = [:]
        for p in op.headerParams {
            let v = (params["header:" + p.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { headers[p.name] = v }
        }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let r = try await client.raw(op.method, path, query: query, body: requestBody, headers: headers)
            response = r
            model.consoleHistory.insert(ConsoleHistoryEntry(opId: op.id, method: op.method, path: path, status: r.statusCode, at: Date()), at: 0)
            if model.consoleHistory.count > 100 { model.consoleHistory.removeLast() }
        } catch {
            self.error = describe(error)
        }
    }
}

/// Runs queries against the GraphQL Analytics API.
struct GraphQLView: View {
    @Environment(AppModel.self) private var model
    @State private var template = 0
    @State private var query = GraphQLTemplate.all[0].query
    @State private var variables = ""
    @State private var result: JSON?
    @State private var error: String?
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Picker(L("Template", "模板"), selection: Binding(get: { template }, set: { i in
                    template = i
                    query = GraphQLTemplate.all[i].query
                    variables = GraphQLTemplate.all[i].filledVariables(zoneId: model.zoneId, accountId: model.accountId).prettyString
                })) {
                    ForEach(GraphQLTemplate.all.indices, id: \.self) { Text(GraphQLTemplate.all[$0].title.text).tag($0) }
                }
            }
            Section(L("Query", "查询")) { CodeEditor(text: $query).frame(minHeight: 220) }
            Section(L("Variables", "变量")) { CodeEditor(text: $variables).frame(minHeight: 100) }
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                        Text(L("Run", "执行")).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(running)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if let result {
                Section(L("Result", "结果")) {
                    ScrollView(.horizontal) { Text(result.prettyString).font(.caption.monospaced()).textSelection(.enabled) }
                    Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(result.prettyString) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("GraphQL explorer", "GraphQL 查询"))
        .onAppear {
            if variables.isEmpty {
                variables = GraphQLTemplate.all[0].filledVariables(zoneId: model.zoneId, accountId: model.accountId).prettyString
            }
        }
    }

    private func run() async {
        guard let client = model.client else { return }
        let vars: JSON
        if variables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars = [:]
        } else if let v = try? JSON.parse(variables), v.object != nil {
            vars = v
        } else {
            error = L("Variables must be a JSON object", "变量必须是 JSON 对象")
            return
        }
        running = true
        error = nil
        defer { running = false }
        do {
            result = try await client.graphql(query, variables: vars)
        } catch {
            self.error = describe(error)
        }
    }
}

/// Recent API calls made by the app.
struct RequestLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.requests) { r in
            let ok = (r.statusCode ?? 999) < 400
            HStack(spacing: 10) {
                MethodBadge(method: r.method)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.url.replacingOccurrences(of: cfAPIBase.absoluteString, with: "")).font(.caption.monospaced()).lineLimit(2)
                    Text("\(Format.relative(r.at)) · \(Int(r.duration * 1000)) ms" + (r.error.map { " · " + $0 } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusBadge(r.statusCode.map(String.init) ?? "ERR", tone: ok ? .good : .bad)
            }
        }
        .overlay { if model.requests.isEmpty { EmptyState(title: L("No requests yet", "还没有请求"), symbol: "list.bullet.rectangle.portrait") } }
        .navigationTitle(L("Request log", "请求日志"))
    }
}

import CirrusKit
import SwiftUI

struct AIView: View {
    let accountId: String

    enum Part: String, CaseIterable, Identifiable {
        case chat, image, models
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chat: return L("Chat", "对话")
            case .image: return L("Image", "图像生成")
            case .models: return L("Models", "模型")
            }
        }
    }

    @State private var part = Part.chat

    var body: some View {
        VStack(spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
            QueryView(
                "ai-models:" + accountId,
                fetch: { c in try await c.list(WorkersAI.models(accountId), perPage: 100, maxItems: 1000) }
            ) { models, h in
                switch part {
                case .chat: AIChat(accountId: accountId, models: models)
                case .image: AIImage(accountId: accountId, models: models)
                case .models: AIModels(accountId: accountId, models: models, reload: h.reload)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("Workers AI")
        .inlineTitle()
    }
}

private func modelNames(_ models: [JSON], task: String) -> [String] {
    models.filter { WorkersAI.task($0) == task }.compactMap { $0["name"].string }.sorted()
}

private struct AIChat: View {
    let accountId: String
    let models: [JSON]
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var system = "You are a helpful assistant."
    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var busy = false
    @State private var editingSystem = false

    struct Message: Identifiable {
        let id = UUID()
        var role: String
        var content: String
    }

    private var names: [String] { modelNames(models, task: "Text Generation") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("Model", "模型"), selection: Binding(get: { current ?? "" }, set: { selected = $0 })) {
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Button(L("System prompt", "系统提示词"), systemImage: "slider.horizontal.3") { editingSystem = true }
                    .labelStyle(.iconOnly)
                Button(L("New chat", "新对话"), systemImage: "square.and.pencil") { messages = [] }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if busy { ProgressView().padding() }
                    }
                    .padding()
                }
                .overlay {
                    if messages.isEmpty {
                        EmptyState(title: L("Chat with models running on Cloudflare", "与运行在 Cloudflare 上的模型对话"), symbol: "sparkles")
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 10) {
                TextField(L("Message", "输入消息"), text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 32, height: 32)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == nil)
            }
            .padding()
        }
        .sheet(isPresented: $editingSystem) {
            JSONEditorSheet(title: L("System prompt", "系统提示词"), text: system) { t in
                system = t
                return true
            }
        }
    }

    private var current: String? {
        if let selected, names.contains(selected) { return selected }
        return names.first { $0.contains("llama-3.3-70b") } ?? names.first
    }

    private func bubble(_ m: Message) -> some View {
        let user = m.role == "user"
        let error = m.role == "error"
        return HStack {
            if user { Spacer(minLength: 40) }
            Text(m.content)
                .textSelection(.enabled)
                .padding(12)
                .foregroundStyle(error ? Color.red : Color.primary)
                .glassEffect(user ? .regular.tint(.accentColor.opacity(0.35)) : .regular, in: .rect(cornerRadius: 18))
            if !user { Spacer(minLength: 40) }
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let m = current, !busy, let client = model.client else { return }
        messages.append(Message(role: "user", content: text))
        input = ""
        busy = true
        defer { busy = false }
        var payload: [JSON] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { payload.append(["role": "system", "content": .string(sys)]) }
        for msg in messages where msg.role == "user" || msg.role == "assistant" {
            payload.append(["role": .string(msg.role), "content": .string(msg.content)])
        }
        do {
            let r = try await client.post(WorkersAI.run(accountId, m), ["messages": .array(payload), "max_tokens": 2048])
            messages.append(Message(role: "assistant", content: WorkersAI.reply(r)))
        } catch {
            messages.append(Message(role: "error", content: describe(error)))
        }
    }
}

private struct AIImage: View {
    let accountId: String
    let models: [JSON]
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var prompt = "A cirrus cloud over a mountain lake at sunrise, watercolor"
    @State private var image: Data?
    @State private var busy = false
    @State private var export: DataExport?

    private var names: [String] { modelNames(models, task: "Text-to-Image") }

    private var current: String? {
        if let selected, names.contains(selected) { return selected }
        return names.first { $0.contains("flux") } ?? names.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("Model", "模型"), selection: Binding(get: { current ?? "" }, set: { selected = $0 })) {
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                TextField(L("Prompt", "提示词"), text: $prompt, axis: .vertical)
                    .lineLimit(2...6)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                HStack {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "paintbrush") }
                            Text(L("Generate", "生成"))
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || current == nil)
                    if let image {
                        Button(L("Save", "保存"), systemImage: "square.and.arrow.down") {
                            export = DataExport(data: image, name: "cirrus-ai.png")
                        }
                        .buttonStyle(.glass)
                    }
                }
                if let image, let img = platformImage(image) {
                    img.resizable().scaledToFit().clipShape(.rect(cornerRadius: 16))
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .dataExporter($export)
    }

    private func generate() async {
        guard let m = current, let client = model.client else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await client.raw(
                "POST", WorkersAI.run(accountId, m), body: .json(["prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines))]))
            if !r.ok && !(r.header("content-type") ?? "").contains("json") {
                throw SimpleError("HTTP \(r.statusCode)")
            }
            let bytes = try WorkersAI.image(data: r.data, contentType: r.header("content-type"))
            image = bytes
            if bytes == nil { model.feedback.show(L("Model returned no image", "模型未返回图像"), error: true) }
        } catch {
            model.feedback.error(error)
        }
    }
}

private struct AIModels: View {
    let accountId: String
    let models: [JSON]
    let reload: () async -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var task = "all"
    @State private var jsonItem: JSONItem?
    @State private var running: JSON?

    private var tasks: [String] { Array(Set(models.map(WorkersAI.task).filter { !$0.isEmpty })).sorted() }

    private var list: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return models.filter { m in
            if task != "all" && WorkersAI.task(m) != task { return false }
            return q.isEmpty || "\(m["name"].string ?? "") \(m["description"].string ?? "")".lowercased().contains(q)
        }
        .sorted { ($0["name"].string ?? "") < ($1["name"].string ?? "") }
    }

    var body: some View {
        List(list, id: \.self) { m in
            let name = m["name"].string ?? ""
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.monospaced())
                    Text("\(WorkersAI.task(m)) · \(m["description"].string ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(L("Run", "运行"), systemImage: "play.fill") { running = m }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .contentShape(.rect)
            .onTapGesture { jsonItem = JSONItem(title: name, json: m) }
        }
        .searchable(text: $query)
        .refreshable { await reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("Task", "任务"), selection: $task) {
                        Text(L("All tasks", "全部任务")).tag("all")
                        ForEach(tasks, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(L("Filter", "筛选"), systemImage: task == "all" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
        .sheet(isPresented: Binding(get: { running != nil }, set: { if !$0 { running = nil } })) {
            if let m = running {
                let name = m["name"].string ?? ""
                JSONEditorSheet(title: name, text: WorkersAI.example(task: WorkersAI.task(m)).prettyString) { text in
                    guard let body = try? JSON.parse(text) else {
                        model.feedback.show(L("Invalid JSON", "JSON 格式错误"), error: true)
                        return false
                    }
                    let r = await model.run { try await model.client?.post(WorkersAI.run(accountId, name), body) }
                    if let o = r, let result = o {
                        running = nil
                        try? await Task.sleep(for: .milliseconds(400))
                        jsonItem = JSONItem(title: name, json: result)
                    }
                    return false
                }
            }
        }
    }
}

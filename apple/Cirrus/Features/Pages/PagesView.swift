import CirrusKit
import SwiftUI

struct PagesView: View {
    let accountId: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?

    var body: some View {
        QueryView("pages:" + accountId, fetch: { c in try await c.list(Pages.projects(accountId), perPage: 10, maxItems: 1000) }) { projects, h in
            List(projects, id: \.self) { p in
                let name = p["name"].string ?? ""
                let latest = p["latest_deployment"]
                let stage = latest["latest_stage"]
                NavigationLink {
                    PagesProjectView(accountId: accountId, name: name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "macwindow").foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).fontWeight(.semibold)
                            Text(subtitle(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if let s = stage["status"].string { StatusBadge(s) }
                    }
                }
            }
            .overlay { if projects.isEmpty { EmptyState(title: L("No Pages projects", "没有 Pages 项目"), symbol: "macwindow") } }
            .refreshable { await h.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Create project", "创建项目"), systemImage: "plus") {
                        prompt = TextPrompt(
                            title: L("New Pages project (direct upload)", "新建 Pages 项目（直接上传）"), placeholder: "my-site",
                            confirm: L("Create", "创建")
                        ) { name in
                            await model.run(L("Project created", "项目已创建")) {
                                try await model.client?.post(
                                    Pages.projects(accountId),
                                    ["name": .string(name.trimmingCharacters(in: .whitespaces)), "production_branch": "main"])
                            }
                            await h.reload()
                        }
                    }
                }
            }
        }
        .textPrompt($prompt)
    }

    private func subtitle(_ p: JSON) -> String {
        let latest = p["latest_deployment"]
        let trigger = latest["deployment_trigger"]["metadata"]
        let source = p["source"]["config"]
        var parts: [String] = []
        if let s = p["subdomain"].string { parts.append(s) }
        if let owner = source["owner"].string { parts.append("\(owner)/\(source["repo_name"].string ?? "")") }
        if let b = trigger["branch"].string { parts.append("⎇ " + b) }
        if !latest["created_on"].isNull { parts.append(Format.relative(latest["created_on"])) }
        return parts.joined(separator: " · ")
    }
}

struct PagesProjectView: View {
    let accountId: String
    let name: String

    enum Part: String, CaseIterable, Identifiable {
        case deployments, domains, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .deployments: return L("Deployments", "部署")
            case .domains: return L("Custom domains", "自定义域")
            case .settings: return L("Settings", "设置")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var part = Part.deployments
    @State private var prompt: TextPrompt?
    @State private var jsonItem: JSONItem?

    private var base: String { Pages.project(accountId, name) }

    var body: some View {
        VStack(spacing: 0) {
            SectionTabs(tabs: Part.allCases, selection: $part) { $0.title }
            Group {
                switch part {
                case .deployments: PagesDeployments(base: base)
                case .domains: PagesDomains(base: base)
                case .settings: PagesSettings(base: base)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(name)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L("Project details (JSON)", "项目详情（JSON）"), systemImage: "curlybraces") {
                        Task {
                            let r = await model.run { try await model.client?.get(base) }
                            if let o = r, let p = o { jsonItem = JSONItem(title: name, json: p) }
                        }
                    }
                    Button(L("Purge build cache", "清除构建缓存"), systemImage: "trash.slash") {
                        Task { await model.run(L("Build cache purged", "构建缓存已清除")) { try await model.client?.post(base + "/purge_build_cache") } }
                    }
                    Divider()
                    Button(L("Delete project", "删除项目"), systemImage: "trash", role: .destructive) {
                        prompt = typedDelete(
                            L("Delete project?", "删除项目？"), name: name,
                            message: L("All deployments and domains of \(name) will be removed.", "\(name) 的所有部署和域名都将被删除。"),
                            feedback: model.feedback
                        ) {
                            let r = await model.run(L("Deleted", "已删除")) { try await model.client?.send("DELETE", base) }
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
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

private struct PagesDeployments: View {
    let base: String
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirm: ConfirmItem?
    @State private var jsonItem: JSONItem?
    @State private var logsPath: String?

    var body: some View {
        let path = base + "/deployments"
        QueryView("pages-deployments:" + base, fetch: { c in try await c.list(path, perPage: 25, maxItems: 100) }) { deps, h in
            List(deps, id: \.self) { d in
                let id = d["id"].string ?? ""
                let stage = d["latest_stage"]
                let meta = d["deployment_trigger"]["metadata"]
                HStack(spacing: 12) {
                    Image(systemName: d["environment"].string == "production" ? "globe" : "eye").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta["commit_message"].string.map { String($0.split(separator: "\n").first ?? "") } ?? id).lineLimit(1)
                        Text(
                            [
                                d["environment"].string, meta["branch"].string.map { "⎇ " + $0 },
                                meta["commit_hash"].string.map { String($0.prefix(7)) }, Format.relative(d["created_on"]),
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge([stage["name"].string, stage["status"].string].compactMap { $0 }.joined(separator: " "), tone: StatusTone.of(stage["status"].string))
                    Menu {
                        if let u = Pages.url(d["url"].string) { Button(L("Open", "打开"), systemImage: "safari") { openURL(u) } }
                        Button(L("Build logs", "构建日志"), systemImage: "text.alignleft") { logsPath = "\(path)/\(id)/history/logs" }
                        Button(L("Retry", "重试"), systemImage: "arrow.clockwise") {
                            Task {
                                await model.run(L("Retry started", "已开始重试")) { try await model.client?.post("\(path)/\(id)/retry") }
                                await h.reload()
                            }
                        }
                        if d["environment"].string == "production" {
                            Button(L("Rollback to this", "回滚到此版本"), systemImage: "arrow.uturn.backward") {
                                confirm = ConfirmItem(
                                    title: L("Roll back production to this deployment?", "将生产环境回滚到此部署？"), button: L("Roll back", "回滚")
                                ) {
                                    await model.run(L("Rolled back", "已回滚")) { try await model.client?.post("\(path)/\(id)/rollback") }
                                    await h.reload()
                                }
                            }
                        }
                        Button(L("Details", "详情"), systemImage: "curlybraces") { jsonItem = JSONItem(title: id, json: d) }
                        Divider()
                        Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                            confirm = ConfirmItem(title: L("Delete deployment?", "删除部署？"), message: id, button: L("Delete", "删除")) {
                                await model.run { try await model.client?.send("DELETE", "\(path)/\(id)", query: ["force": "true"]) }
                                await h.reload()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .overlay { if deps.isEmpty { EmptyState(title: L("No deployments", "没有部署"), symbol: "shippingbox") } }
            .refreshable { await h.reload() }
        }
        .confirm($confirm)
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
        .sheet(isPresented: Binding(get: { logsPath != nil }, set: { if !$0 { logsPath = nil } })) {
            BuildLogsSheet(path: logsPath ?? "")
        }
    }
}

private struct BuildLogsSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QueryView("logs:" + path, fetch: { c in try await c.get(path) }) { data, _ in
                ScrollView([.vertical, .horizontal]) {
                    Text(data["data"].items.map { $0["line"].text ?? "" }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
            }
            .navigationTitle(L("Build logs", "构建日志"))
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } } }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

private struct PagesDomains: View {
    let base: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var confirm: ConfirmItem?

    var body: some View {
        let path = base + "/domains"
        QueryView("pages-domains:" + base, fetch: { c in try await c.list(path, paginate: false) }) { domains, h in
            List {
                ForEach(domains, id: \.self) { d in
                    let name = d["name"].string ?? ""
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                            Text("\(d["validation_data"]["status"].string ?? "") · \(d["verification_data"]["status"].string ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(d["status"].string ?? "")
                    }
                    .swipeActions {
                        Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) {
                            confirm = ConfirmItem(title: L("Remove domain?", "移除域名？"), message: name, button: L("Remove", "移除")) {
                                await model.run { try await model.client?.delete(path + "/" + name) }
                                await h.reload()
                            }
                        }
                        Button(L("Retry validation", "重新验证"), systemImage: "arrow.clockwise") {
                            Task {
                                await model.run { try await model.client?.patch(path + "/" + name) }
                                await h.reload()
                            }
                        }
                    }
                }
                Button(L("Add domain", "添加域名"), systemImage: "plus") {
                    prompt = TextPrompt(title: L("Custom domain", "自定义域名"), placeholder: "www.example.com", confirm: L("Add", "添加")) { n in
                        await model.run(L("Domain added", "域名已添加")) {
                            try await model.client?.post(path, ["name": .string(n.trimmingCharacters(in: .whitespaces))])
                        }
                        await h.reload()
                    }
                }
            }
            .refreshable { await h.reload() }
        }
        .textPrompt($prompt)
        .confirm($confirm)
    }
}

private struct PagesSettings: View {
    let base: String
    @Environment(AppModel.self) private var model
    @State private var prompt: TextPrompt?
    @State private var build: (command: String, output: String)?

    var body: some View {
        QueryView("pages-project:" + base, fetch: { c in try await c.get(base) }) { p, h in
            let bc = p["build_config"]
            Form {
                Section(L("Build", "构建")) {
                    InfoRow(L("Production branch", "生产分支"), p["production_branch"].string)
                    InfoRow(L("Build command", "构建命令"), bc["build_command"].string, mono: true)
                    InfoRow(L("Output directory", "输出目录"), bc["destination_dir"].string, mono: true)
                    InfoRow(L("Root directory", "根目录"), bc["root_dir"].string, mono: true)
                    Button(L("Edit build settings", "编辑构建设置"), systemImage: "pencil") {
                        build = (bc["build_command"].string ?? "", bc["destination_dir"].string ?? "")
                    }
                }
                envSection("production", p, h)
                envSection("preview", p, h)
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(isPresented: Binding(get: { build != nil }, set: { if !$0 { build = nil } })) {
                BuildSettingsSheet(command: build?.command ?? "", output: build?.output ?? "") { cmd, out in
                    await patch(["build_config": ["build_command": .string(cmd), "destination_dir": .string(out)]], h)
                }
            }
        }
        .textPrompt($prompt)
    }

    private func envSection(_ env: String, _ p: JSON, _ h: QueryHandle<JSON>) -> some View {
        let vars = p["deployment_configs"][env]["env_vars"].object ?? [:]
        return Section(env == "production" ? L("Production variables", "生产环境变量") : L("Preview variables", "预览环境变量")) {
            if vars.isEmpty { Text(L("No variables", "没有变量")).foregroundStyle(.secondary) }
            ForEach(vars.keys.sorted(), id: \.self) { k in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k).font(.body.monospaced())
                    Text(vars[k]?["type"].string == "secret_text" ? "••••••" : (vars[k]?["value"].text ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(L("Delete", "删除"), systemImage: "trash", role: .destructive) {
                        Task { await patch(["deployment_configs": [env: ["env_vars": [k: nil]]]], h) }
                    }
                }
            }
            Button(L("Add variable", "添加变量"), systemImage: "plus") {
                prompt = TextPrompt(title: L("Variable name", "变量名"), confirm: L("Next", "下一步")) { name in
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    prompt = TextPrompt(title: n, message: L("Value", "值")) { value in
                        await patch(
                            ["deployment_configs": [env: ["env_vars": [n: ["type": "plain_text", "value": .string(value)]]]]], h)
                    }
                }
            }
        }
    }

    @discardableResult
    private func patch(_ body: JSON, _ h: QueryHandle<JSON>) async -> Bool {
        let r = await model.run(L("Saved", "已保存")) { try await model.client?.patch(base, body) }
        await h.reload()
        return r != nil
    }
}

private struct BuildSettingsSheet: View {
    @State var command: String
    @State var output: String
    let save: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Build command", "构建命令"), text: $command).plainInput().font(.body.monospaced())
                TextField(L("Output directory", "输出目录"), text: $output).plainInput().font(.body.monospaced())
            }
            .formStyle(.grouped)
            .navigationTitle(L("Build settings", "构建设置"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) { Task { if await save(command, output) { dismiss() } } }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 260)
    }
}

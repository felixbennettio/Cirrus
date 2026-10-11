import CirrusKit
import SwiftUI

/// Finds pages, resources, zones, accounts and API endpoints.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openScreen) private var openScreen
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var terms: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func hit(_ hay: [String]) -> Bool {
        let t = terms
        if t.isEmpty { return true }
        let h = hay.joined(separator: " ").lowercased()
        return t.allSatisfy { h.contains($0) }
    }

    private var screens: [Screen] {
        Screen.allCases.filter { s in
            if s.scope == .zone && model.currentZone == nil { return false }
            if s.scope == .account && model.accountId == nil { return false }
            return hit([s.title, s.rawValue] + s.keywords)
        }
    }

    private var specs: [ResourceSpec] {
        terms.isEmpty ? [] : model.resources.specs.filter { hit([$0.title.en, $0.title.zh, $0.id] + $0.keywords) }
    }

    var body: some View {
        List {
            if !screens.isEmpty {
                Section(L("Pages", "页面")) {
                    ForEach(screens) { s in
                        Button {
                            dismiss()
                            openScreen(s)
                        } label: {
                            Label(s.title, systemImage: s.symbol).foregroundStyle(Color.primary)
                        }
                    }
                }
            }
            if !specs.isEmpty {
                Section(L("Resources", "资源")) {
                    ForEach(specs) { spec in
                        NavigationLink {
                            ResourceListView(spec: spec).navigationTitle(spec.title.text)
                        } label: {
                            HStack {
                                Label(spec.title.text, systemImage: Icons.symbol(spec.icon))
                                Spacer()
                                Text(spec.group.text).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !terms.isEmpty {
                let zones = model.zones.filter { hit([$0["name"].string ?? ""]) }.prefix(8)
                if !zones.isEmpty {
                    Section(L("Zones", "域名")) {
                        ForEach(Array(zones), id: \.self) { z in
                            Button {
                                if let id = z["id"].string { model.setActiveZone(id) }
                                dismiss()
                                openScreen(.zoneOverview)
                            } label: {
                                Label(z["name"].string ?? "", systemImage: "globe").foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
                let accounts = model.accounts.filter { hit([$0["name"].string ?? ""]) }.prefix(5)
                if !accounts.isEmpty {
                    Section(L("Accounts", "账户")) {
                        ForEach(Array(accounts), id: \.self) { a in
                            Button {
                                if let id = a["id"].string { model.setActiveAccount(id) }
                                dismiss()
                            } label: {
                                Label(a["name"].string ?? "", systemImage: "person.crop.circle").foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
                if query.count >= 2, let catalog = model.catalog.catalog {
                    let ops = catalog.search(query, limit: 25)
                    if !ops.isEmpty {
                        Section(L("API endpoints", "API 接口")) {
                            ForEach(ops) { op in OperationLink(op: op, catalog: catalog) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: L("Pages, resources, domains, endpoints", "页面、资源、域名、接口"))
        .navigationTitle(L("Search", "搜索"))
        .task { _ = await model.catalog.load() }
    }
}

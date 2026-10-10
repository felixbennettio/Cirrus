import CirrusKit
import SwiftUI

/// Sidebar row: the current credential and account.
struct AccountSwitcherRow: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            SwitcherLabel(
                symbol: "person.crop.circle",
                title: model.currentAccount?["name"].string
                    ?? (model.accountsLoading ? L("Loading…", "加载中…") : L("No account", "无账户")),
                subtitle: model.activeProfile?.name)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $picking) { AccountPicker() }
    }
}

/// Sidebar row: the current zone.
struct ZoneSwitcherRow: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            SwitcherLabel(
                symbol: "globe",
                title: model.currentZone?["name"].string
                    ?? (model.zonesLoading ? L("Loading zones…", "加载域名中…") : L("No zones", "没有域名")),
                subtitle: model.currentZone.map { z in
                    [z["plan"]["name"].string, z["status"].string].compactMap { $0 }.joined(separator: " · ")
                })
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $picking) { ZonePicker() }
    }
}

struct SwitcherLabel: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

/// Credentials and accounts.
struct AccountPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section(L("Credentials", "凭据")) {
                    ForEach(model.profiles) { p in
                        Button {
                            model.setActiveProfile(p.id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: p.id == model.activeProfile?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(p.name)
                                    Text("\(p.kindLabel) · \(p.secretHint)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button(L("Add credential", "添加凭据"), systemImage: "plus") { adding = true }
                }
                Section {
                    if model.accounts.isEmpty {
                        if model.accountsLoading {
                            ProgressView()
                        } else {
                            Text(model.accountsError ?? L("No accounts visible to this credential", "当前凭据看不到任何账户"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.accounts, id: \.self) { a in
                        let id = a["id"].string ?? ""
                        Button {
                            model.setActiveAccount(id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: id == model.accountId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(a["name"].string ?? id)
                                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(L("Accounts", "账户"))
                        Spacer()
                        if model.accountsLoading && !model.accounts.isEmpty { ProgressView().controlSize(.small) }
                    }
                }
            }
            .navigationTitle(L("Switch account", "切换账户"))
            .inlineTitle()
            .refreshable { await model.loadAccounts(force: true) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Refresh", "刷新"), systemImage: "arrow.clockwise") {
                        Task { await model.loadAccounts(force: true) }
                    }
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack { AddProfileView() }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

/// Searchable list of the account's zones.
struct ZonePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openScreen) private var openScreen
    @State private var query = ""

    private var filtered: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return model.zones }
        return model.zones.filter { ($0["name"].string ?? "").lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.self) { z in
                    let id = z["id"].string ?? ""
                    Button {
                        model.setActiveZone(id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: id == model.zoneId ? "checkmark.circle.fill" : "globe")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(z["name"].string ?? id)
                                Text(z["plan"]["name"].string ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ZoneStatusBadge(zone: z)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if model.zones.isEmpty {
                    if model.zonesLoading {
                        ProgressView()
                    } else {
                        EmptyState(title: L("No zones", "没有域名"), symbol: "globe", message: model.zonesError)
                    }
                }
            }
            .searchable(text: $query, prompt: L("Search domains", "搜索域名"))
            .navigationTitle(L("Switch zone", "切换域名"))
            .inlineTitle()
            .refreshable { await model.loadZones(force: true) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(L("All domains", "全部域名"), systemImage: "list.bullet") {
                        dismiss()
                        openScreen(.domains)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
    }
}

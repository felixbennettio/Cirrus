import CirrusKit
import SwiftUI

/// `GET /zones/{id}/settings` as id → setting.
typealias ZoneSettingsMap = [String: JSON]

func loadZoneSettings(_ c: CFClient, _ zoneId: String) async throws -> ZoneSettingsMap {
    ZoneSettingsCatalog.index(try await c.get("/zones/\(zoneId)/settings"))
}

/// Every zone setting, grouped like the dashboard.
struct ZoneSettingsView: View {
    let zone: ZoneRef

    var body: some View {
        ZoneSettingsList(zoneId: zone.id, groups: SettingGroup.allCases)
            .navigationTitle(L("Zone settings", "域名设置"))
            .toolbar { ZoneToolbar() }
    }
}

/// The settings of [groups] as a form, with optional [header] sections.
struct ZoneSettingsList<Header: View>: View {
    let zoneId: String
    let groups: [SettingGroup]
    @ViewBuilder var header: () -> Header

    init(zoneId: String, groups: [SettingGroup], @ViewBuilder header: @escaping () -> Header) {
        self.zoneId = zoneId
        self.groups = groups
        self.header = header
    }

    var body: some View {
        QueryView("zone-settings:" + zoneId, fetch: { c in try await loadZoneSettings(c, zoneId) }) { settings, h in
            Form {
                header()
                ForEach(groups, id: \.self) { g in
                    let ids = ZoneSettingsCatalog.ids(in: g, of: settings.keys)
                    if !ids.isEmpty {
                        Section(g.label.text) {
                            ForEach(ids, id: \.self) { id in
                                if let s = settings[id] {
                                    ZoneSettingRow(zoneId: zoneId, setting: s) { updated in
                                        var next = settings
                                        if let key = updated["id"].string { next[key] = updated }
                                        h.set(next)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
        }
    }
}

extension ZoneSettingsList where Header == EmptyView {
    init(zoneId: String, groups: [SettingGroup]) {
        self.init(zoneId: zoneId, groups: groups) { EmptyView() }
    }
}

/// One zone setting with the control that suits its value.
struct ZoneSettingRow: View {
    let zoneId: String
    let setting: JSON
    let changed: (JSON) -> Void

    @Environment(AppModel.self) private var model
    @State private var editingJSON = false
    @State private var editingNumber = false
    @State private var text = ""
    @State private var busy = false

    private var id: String { setting["id"].string ?? "" }
    private var meta: SettingMeta? { ZoneSettingsCatalog.byId[id] }
    private var editable: Bool { setting["editable"].bool != false }

    private var subtitle: String {
        var parts: [String] = []
        if let d = meta?.description?.text { parts.append(d) }
        if !editable { parts.append(L("Not available on this plan", "当前套餐不可用")) }
        if !setting["modified_on"].isNull { parts.append(Format.relative(setting["modified_on"])) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let title = meta?.label.text ?? id
        let value = setting["value"]
        let onOff = value.string == "on" || value.string == "off"
        Group {
            if let options = meta?.options ?? (value.string != nil && !onOff ? [value.string!] : nil) {
                Picker(selection: Binding(get: { value.string ?? "" }, set: { v in Task { await set(.string(v)) } })) {
                    ForEach(options, id: \.self) { o in Text(ZoneSettingsCatalog.valueLabel(id, .string(o))).tag(o) }
                    if let v = value.string, !options.contains(v) { Text(v).tag(v) }
                } label: {
                    label(title)
                }
            } else if onOff {
                Toggle(isOn: Binding(get: { value.string == "on" }, set: { v in Task { await set(.string(v ? "on" : "off")) } })) {
                    label(title)
                }
            } else if let n = value.int {
                if let opts = meta?.numberOptions {
                    Picker(selection: Binding(get: { n }, set: { v in Task { await set(.int(v)) } })) {
                        ForEach(Array(Set(opts + [n])).sorted(), id: \.self) { o in
                            Text(ZoneSettingsCatalog.valueLabel(id, .int(o))).tag(o)
                        }
                    } label: {
                        label(title)
                    }
                } else {
                    Button {
                        text = String(n)
                        editingNumber = true
                    } label: {
                        LabeledContent { Text(String(n)).monospacedDigit() } label: { label(title) }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    text = value.prettyString
                    editingJSON = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        label(title)
                        Text(value.compactString).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!editable || busy)
        .alert(title, isPresented: $editingNumber) {
            TextField(title, text: $text).numberInput()
            Button(L("Save", "保存")) {
                if let n = Double(text.trimmingCharacters(in: .whitespaces)) {
                    Task { await set(n.rounded() == n ? .int(Int(n)) : .double(n)) }
                }
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        }
        .sheet(isPresented: $editingJSON) {
            JSONEditorSheet(title: title, text: text) { t in
                guard let parsed = try? JSON.parse(t) else {
                    model.feedback.show(L("Invalid JSON", "JSON 格式错误"), error: true)
                    return false
                }
                return await set(parsed)
            }
        }
    }

    private func label(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @discardableResult
    private func set(_ value: JSON) async -> Bool {
        busy = true
        defer { busy = false }
        let result = await model.run { try await model.client?.patch("/zones/\(zoneId)/settings/\(id)", ["value": value]) }
        if let response = result, let r = response, r["id"].string != nil {
            changed(r)
            return true
        }
        return result != nil
    }
}

/// Edits a JSON value as text.
struct JSONEditorSheet: View {
    let title: String
    @State var text: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .plainInput()
                .padding(8)
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Save", "保存")) { Task { if await save(text) { dismiss() } } }
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

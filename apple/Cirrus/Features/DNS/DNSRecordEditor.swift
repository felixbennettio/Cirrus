import CirrusKit
import SwiftUI

/// Adds or edits one DNS record. [save] gets the request body.
struct DNSRecordEditor: View {
    let zoneName: String
    var record: JSON?
    let save: (JSON) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: DNSRecordDraft
    @State private var saving = false
    @State private var error: String?

    init(zoneName: String, record: JSON? = nil, save: @escaping (JSON) async -> Bool) {
        self.zoneName = zoneName
        self.record = record
        self.save = save
        _draft = State(initialValue: record.map { DNSRecordDraft(record: $0, zone: zoneName) } ?? DNSRecordDraft())
    }

    private var editing: Bool { record != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Type", "类型"), selection: $draft.type) {
                        ForEach(DNSCatalog.types, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(editing)
                    LabeledContent(L("Name", "名称")) {
                        TextField(L("Name", "名称"), text: $draft.name, prompt: Text("@ / www"))
                            .plainInput()
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(L("Use @ for \(zoneName).", "用 @ 表示 \(zoneName)。"))
                }

                if let fields = DNSCatalog.dataFields[draft.type] {
                    Section(L("Data", "数据")) {
                        ForEach(fields, id: \.key) { f in dataField(f) }
                    }
                } else {
                    Section {
                        if draft.type == "TXT" {
                            TextField(DNSCatalog.contentLabel(draft.type), text: $draft.content, prompt: hint, axis: .vertical)
                                .plainInput()
                                .lineLimit(3...8)
                                .font(.body.monospaced())
                        } else {
                            TextField(DNSCatalog.contentLabel(draft.type), text: $draft.content, prompt: hint)
                                .plainInput()
                                .font(.body.monospaced())
                        }
                        if DNSCatalog.hasPriority(draft.type) {
                            LabeledContent(L("Priority", "优先级")) {
                                TextField("10", text: $draft.priority).multilineTextAlignment(.trailing).numberInput()
                            }
                        }
                    } header: {
                        Text(DNSCatalog.contentLabel(draft.type))
                    }
                }

                Section {
                    Picker("TTL", selection: $draft.ttl) {
                        ForEach(DNSCatalog.ttls, id: \.self) { t in Text(Format.ttl(.int(t))).tag(t) }
                        Text(L("Custom", "自定义")).tag(-1)
                    }
                    if draft.ttl == -1 {
                        LabeledContent(L("Seconds", "秒")) {
                            TextField("300", text: $draft.customTTL).multilineTextAlignment(.trailing).numberInput()
                        }
                    }
                    if draft.isProxiable {
                        Toggle(isOn: $draft.proxied) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(L("Proxied", "代理"))
                                    Text(
                                        draft.proxied
                                            ? L("Traffic goes through Cloudflare", "流量经过 Cloudflare")
                                            : L("DNS only", "仅 DNS"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: draft.proxied ? "cloud.fill" : "cloud")
                                    .foregroundStyle(draft.proxied ? Color.orange : .secondary)
                            }
                        }
                        if draft.proxied && draft.ttl != 1 {
                            Text(L("Proxied records always use automatic TTL.", "已代理的记录始终使用自动 TTL。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if draft.type == "CNAME" {
                        Toggle(L("Flatten CNAME", "CNAME 展平"), isOn: $draft.flattenCNAME)
                    }
                }

                Section(L("Notes", "备注")) {
                    TextField(L("Comment", "备注"), text: $draft.comment, axis: .vertical).lineLimit(1...4)
                    TextField(L("Tags (comma separated, name:value)", "标签（逗号分隔，name:value）"), text: $draft.tags)
                        .plainInput()
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing ? L("Edit record", "编辑记录") : L("Add record", "添加记录"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save", "保存")) { Task { await submit() } }
                        .disabled(saving)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var hint: Text? { DNSCatalog.contentHint(draft.type).map { Text($0) } }

    @ViewBuilder private func dataField(_ f: DNSCatalog.Field) -> some View {
        let binding = Binding(
            get: { draft.data[f.key] ?? "" },
            set: { draft.data[f.key] = $0 })
        if let options = f.options {
            Picker(f.label.text, selection: Binding(get: { binding.wrappedValue.isEmpty ? options[0] : binding.wrappedValue }, set: { binding.wrappedValue = $0 })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } else if f.numeric {
            LabeledContent(f.label.text) {
                TextField(f.hint ?? "", text: binding).multilineTextAlignment(.trailing).numberInput()
            }
        } else {
            TextField(f.label.text, text: binding, prompt: f.hint.map { Text($0) }, axis: .vertical)
                .plainInput()
                .font(.body.monospaced())
        }
    }

    private func submit() async {
        error = nil
        if !draft.usesData, let problem = DNSCatalog.validate(type: draft.type, content: draft.content) {
            error = problem
            return
        }
        saving = true
        defer { saving = false }
        if await save(draft.body(zone: zoneName)) { dismiss() }
    }
}

extension View {
    func numberInput() -> some View {
        #if os(iOS)
            return keyboardType(.numbersAndPunctuation)
        #else
            return self
        #endif
    }
}

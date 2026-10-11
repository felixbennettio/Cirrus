import CirrusKit
import SwiftUI

/// Sets [key] of an object, removing it for empty values (so the API keeps its defaults).
private func updated(_ object: JSON, _ key: String, _ value: JSON) -> JSON {
    var o = object.object ?? [:]
    switch value {
    case .null: o[key] = nil
    case .string(let s) where s.isEmpty: o[key] = nil
    case .array(let a) where a.isEmpty: o[key] = nil
    case .object(let x) where x.isEmpty: o[key] = nil
    default: o[key] = value
    }
    return .object(o)
}

private func describeSchema(_ s: JSON) -> String? { s["description"].string ?? s["title"].string }

/// A form for a JSON body, generated from a schema in the API catalog. Only
/// fields the user sets are sent.
struct SchemaForm: View {
    let catalog: APICatalog
    let schema: JSON
    @Binding var value: JSON
    var hidden: Set<String> = []

    var body: some View {
        let s = catalog.resolve(schema)
        if (s.object ?? [:]).isEmpty {
            Text(L("This request has no documented body schema.", "此请求没有文档化的请求体结构。")).foregroundStyle(.secondary)
        } else {
            SchemaObjectFields(catalog: catalog, schema: s, value: $value, depth: 0, hidden: hidden)
        }
    }
}

struct SchemaObjectFields: View {
    let catalog: APICatalog
    let schema: JSON
    @Binding var value: JSON
    let depth: Int
    var hidden: Set<String> = []

    var body: some View {
        let variants = schema["oneOf"].array ?? schema["anyOf"].array
        let props = schema["properties"].object ?? [:]
        if let variants, !variants.isEmpty, schema["properties"].isNull {
            SchemaVariantPicker(catalog: catalog, variants: variants, value: $value, depth: depth)
        } else if props.isEmpty {
            JSONTextField(label: L("Value (JSON)", "值（JSON）"), description: describeSchema(schema), value: $value)
        } else {
            let required = Set(schema["required"].strings)
            let keys = props.keys.filter { !hidden.contains($0) }.sorted { a, b in
                let ra = required.contains(a), rb = required.contains(b)
                return ra != rb ? ra : a < b
            }
            ForEach(keys, id: \.self) { k in
                let ps = catalog.resolve(props[k] ?? .null)
                if !ps["readOnly"].isTrue {
                    SchemaField(catalog: catalog, name: k, schema: ps, required: required.contains(k), object: $value, depth: depth)
                }
            }
        }
    }
}

private struct SchemaVariantPicker: View {
    let catalog: APICatalog
    let variants: [JSON]
    @Binding var value: JSON
    let depth: Int
    @State private var index = 0

    private func label(_ i: Int) -> String {
        let s = catalog.resolve(variants[i])
        if let t = s["title"].string { return t }
        for k in ["type", "kind", "action", "mode", "name"] {
            let p = catalog.resolve(s["properties"][k])
            if let e = p["enum"].array, e.count == 1 { return "\(k) = \(e[0].text ?? "")" }
        }
        let keys = (s["properties"].object ?? [:]).keys.sorted()
        if !keys.isEmpty { return keys.prefix(3).joined(separator: ", ") }
        if let d = s["description"].string { return String(d.prefix(50)) }
        return L("Variant \(i + 1)", "类型 \(i + 1)")
    }

    var body: some View {
        Picker(L("Variant", "类型"), selection: Binding(get: { index }, set: { i in
            index = i
            value = [:]
        })) {
            ForEach(variants.indices, id: \.self) { Text(label($0)).tag($0) }
        }
        AnyView(SchemaObjectFields(catalog: catalog, schema: catalog.resolve(variants[index]), value: $value, depth: depth + 1))
            .id(index)
    }
}

/// One property of an object.
private struct SchemaField: View {
    let catalog: APICatalog
    let name: String
    let schema: JSON
    let required: Bool
    @Binding var object: JSON
    let depth: Int

    private var label: String { required ? name + " *" : name }
    private var current: JSON { object[name] }
    private func set(_ v: JSON) { object = updated(object, name, v) }
    private var child: Binding<JSON> {
        Binding(get: { object[name].object == nil ? [:] : object[name] }, set: { set($0) })
    }

    var body: some View { field() }

    private func numberCommit(_ t: String, integer: Bool) {
        let v = t.trimmingCharacters(in: .whitespaces)
        if v.isEmpty {
            set(.null)
        } else if integer, let i = Int(v) {
            set(.int(i))
        } else if let d = Double(v) {
            set(.double(d))
        }
    }

    private func listCommit(_ t: String, strings: Bool) {
        let parts = t.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [JSON] = []
        for p in parts {
            if strings {
                out.append(.string(p))
            } else if let i = Int(p) {
                out.append(.int(i))
            } else if let d = Double(p) {
                out.append(.double(d))
            }
        }
        set(.array(out))
    }

    private func nested() -> AnyView {
        AnyView(
            DisclosureGroup {
                AnyView(SchemaObjectFields(catalog: catalog, schema: schema, value: child, depth: depth + 1))
            } label: {
                FieldLabel(label: label, description: describeSchema(schema))
            })
    }

    private func jsonField() -> AnyView {
        AnyView(JSONTextField(label: label, description: describeSchema(schema), value: Binding(get: { current }, set: { set($0) })))
    }

    private func field() -> AnyView {
        let type = APICatalog.type(of: schema)
        let desc = describeSchema(schema)
        if let options = schema["enum"].array, !options.isEmpty {
            let texts = options.compactMap(\.text)
            return AnyView(
                Picker(selection: Binding(get: { current.text ?? "" }, set: { t in set(options.first { $0.text == t } ?? .null) })) {
                    if !required { Text(L("— not set —", "— 未设置 —")).tag("") }
                    ForEach(texts, id: \.self) { Text($0).tag($0) }
                } label: {
                    FieldLabel(label: label, description: desc)
                })
        }
        switch type {
        case "boolean":
            return AnyView(
                Picker(selection: Binding(get: { current.bool.map { $0 ? "true" : "false" } ?? "" }, set: { t in
                    set(t.isEmpty ? .null : .bool(t == "true"))
                })) {
                    Text(L("— not set —", "— 未设置 —")).tag("")
                    Text("true").tag("true")
                    Text("false").tag("false")
                } label: {
                    FieldLabel(label: label, description: desc)
                })
        case "integer", "number":
            let integer = type == "integer"
            return AnyView(
                CommitTextField(label: label, description: desc, prompt: schema["example"].text ?? "", initial: current.text ?? "") { t in
                    numberCommit(t, integer: integer)
                }
                .numberInput())
        case "string":
            let longNames: Set<String> = [
                "content", "script", "body", "certificate", "private_key", "expression", "query", "sql", "description", "html", "value",
            ]
            let long = (schema["maxLength"].int ?? 0) > 300 || longNames.contains(name)
            let prompt = schema["example"].text ?? (schema["format"].string == "date-time" ? "2026-01-01T00:00:00Z" : "")
            return AnyView(
                CommitTextField(label: label, description: desc, prompt: prompt, initial: current.string ?? current.text ?? "", multiline: long) { t in
                    set(t.isEmpty ? .null : .string(t))
                })
        case "array":
            let items = catalog.resolve(schema["items"])
            let itemType = APICatalog.type(of: items)
            if ["string", "integer", "number"].contains(itemType) && items["properties"].isNull {
                let hint = L("One value per line (or comma separated)", "每行一个值（或用逗号分隔）")
                let initial = current.items.compactMap(\.text).joined(separator: "\n")
                return AnyView(
                    CommitTextField(label: label, description: desc.map { hint + "\n" + $0 } ?? hint, prompt: "", initial: initial, multiline: true) { t in
                        listCommit(t, strings: itemType == "string")
                    })
            }
            if depth < 3 && (itemType == "object" || !items["oneOf"].isNull || !items["anyOf"].isNull) {
                return AnyView(
                    ObjectArrayField(
                        catalog: catalog, label: label, description: desc, itemSchema: items,
                        value: Binding(get: { current }, set: { set($0) }), depth: depth))
            }
            return jsonField()
        case "object":
            if depth < 3 && !(schema["properties"].object ?? [:]).isEmpty { return nested() }
            return jsonField()
        default:
            if depth < 3 && (!schema["oneOf"].isNull || !schema["anyOf"].isNull) { return nested() }
            return jsonField()
        }
    }
}

private struct FieldLabel: View {
    let label: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout.monospaced())
            if let description { Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
        }
    }
}

/// A text field that keeps its own text and reports every change.
private struct CommitTextField: View {
    let label: String
    let description: String?
    let prompt: String
    let initial: String
    var multiline = false
    let commit: (String) -> Void
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label, description: description)
            TextField(prompt, text: Binding(get: { text ?? initial }, set: { t in
                text = t
                commit(t)
            }), axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 2...8 : 1...1)
            .plainInput()
            .textFieldStyle(.roundedBorder)
        }
    }
}

/// Any JSON value as text; it is applied while it parses.
struct JSONTextField: View {
    let label: String
    let description: String?
    @Binding var value: JSON
    @State private var text: String?
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: label, description: description)
            TextField("JSON", text: Binding(get: { text ?? (value.isNull ? "" : value.compactString) }, set: { t in
                text = t
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    value = .null
                    invalid = false
                } else if let v = try? JSON.parse(t) {
                    value = v
                    invalid = false
                } else {
                    invalid = true
                }
            }), axis: .vertical)
            .lineLimit(1...8)
            .font(.callout.monospaced())
            .plainInput()
            .textFieldStyle(.roundedBorder)
            if invalid { Text(L("Not valid JSON yet", "JSON 格式还不正确")).font(.caption2).foregroundStyle(.red) }
        }
    }
}

private struct ObjectArrayField: View {
    let catalog: APICatalog
    let label: String
    let description: String?
    let itemSchema: JSON
    @Binding var value: JSON
    let depth: Int

    var body: some View {
        DisclosureGroup {
            ForEach(value.items.indices, id: \.self) { i in
                VStack(alignment: .leading) {
                    HStack {
                        Text("#\(i + 1)").font(.caption.weight(.semibold))
                        Spacer()
                        Button(L("Remove", "移除"), systemImage: "minus.circle", role: .destructive) {
                            var a = value.items
                            a.remove(at: i)
                            value = .array(a)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    AnyView(
                        SchemaObjectFields(
                            catalog: catalog, schema: itemSchema,
                            value: Binding(get: { i < value.items.count ? value.items[i] : [:] }, set: { v in
                                var a = value.items
                                if i < a.count { a[i] = v }
                                value = .array(a)
                            }), depth: depth + 1))
                }
            }
            Button(L("Add item", "添加一项"), systemImage: "plus") { value = .array(value.items + [[:]]) }
        } label: {
            FieldLabel(label: "\(label) (\(value.items.count))", description: description)
        }
    }
}

/// A sheet that edits a request body as a form or as JSON.
struct SchemaEditorSheet: View {
    let title: String
    let catalog: APICatalog?
    let schema: JSON
    var hidden: Set<String> = []
    var submitLabel = L("Save", "保存")
    let submit: (JSON) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var value: JSON
    @State private var asJSON: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    init(
        title: String, catalog: APICatalog?, schema: JSON, initial: JSON = [:], hidden: Set<String> = [],
        submitLabel: String = L("Save", "保存"), submit: @escaping (JSON) async -> Bool
    ) {
        self.title = title
        self.catalog = catalog
        self.schema = schema
        self.hidden = hidden
        self.submitLabel = submitLabel
        self.submit = submit
        _value = State(initialValue: initial.isNull ? [:] : initial)
        let noSchema = catalog.map { ($0.resolve(schema).object ?? [:]).isEmpty } ?? true
        _asJSON = State(initialValue: noSchema || initial.array != nil)
        _text = State(initialValue: (initial.isNull ? JSON.object([:]) : initial).prettyString)
    }

    var body: some View {
        NavigationStack {
            Group {
                if asJSON {
                    CodeEditor(text: $text).padding()
                } else if let catalog {
                    Form {
                        SchemaForm(catalog: catalog, schema: schema, value: $value, hidden: hidden)
                    }
                    .formStyle(.grouped)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error { Text(error).font(.callout).foregroundStyle(.red).padding() }
            }
            .navigationTitle(title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if catalog != nil {
                        Picker(L("Editor", "编辑方式"), selection: Binding(get: { asJSON }, set: { switchMode(json: $0) })) {
                            Text(L("Form", "表单")).tag(false)
                            Text("JSON").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel) { Task { await save() } }.disabled(busy)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    private func switchMode(json: Bool) {
        if json {
            text = value.prettyString
        } else if let v = try? JSON.parse(text) {
            value = v
        } else {
            error = L("Fix the JSON first", "请先修正 JSON")
            return
        }
        error = nil
        asJSON = json
    }

    private func save() async {
        var body = value
        if asJSON {
            guard let v = try? JSON.parse(text) else {
                error = L("Invalid JSON", "JSON 格式错误")
                return
            }
            body = v
        }
        error = nil
        busy = true
        defer { busy = false }
        if await submit(body) { dismiss() }
    }
}

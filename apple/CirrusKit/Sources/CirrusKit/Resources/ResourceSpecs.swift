import Foundation

/// Where `{account_id}` / `{zone_id}` of a spec come from.
public enum SpecScope: String, Sendable {
    case account, zone, user
}

/// An extra operation on an item (or on a whole list), e.g. "purge queue".
public struct ItemAction: Sendable, Hashable, Identifiable {
    public var label: LocalizedText
    public var icon: String
    public var method: String
    /// Template: `{id}` is the item id, `{parent}` the parent's.
    public var path: String
    public var confirm: Bool
    public var danger: Bool
    public var showResult: Bool
    /// Ask for a body using the operation's schema.
    public var withBody: Bool
    /// A fixed body; the string `__ID__` stands for the item's id.
    public var body: JSON?

    public var id: String { method + " " + path + " " + label.en }

    init(_ j: JSON) {
        label = LocalizedText(j["label"]["en"].string ?? "", j["label"]["zh"].string ?? "")
        icon = j["icon"].string ?? ""
        method = j["method"].string ?? "POST"
        path = j["path"].string ?? ""
        confirm = j["confirm"].isTrue
        danger = j["danger"].isTrue
        showResult = j["showResult"].bool ?? true
        withBody = j["withBody"].isTrue
        body = j["body"].isNull ? nil : j["body"]
    }

    /// The fixed body for an item.
    public func body(for itemId: String?) -> JSON? {
        guard let body else { return nil }
        func fill(_ v: JSON) -> JSON {
            switch v {
            case .string("__ID__"): return itemId.map(JSON.string) ?? .null
            case .array(let a): return .array(a.map(fill))
            case .object(let o): return .object(o.mapValues(fill))
            default: return v
            }
        }
        return fill(body)
    }
}

/// A REST collection the generic pages list, show, create, edit and delete.
public struct ResourceSpec: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: LocalizedText
    public var group: LocalizedText
    public var icon: String
    public var scope: SpecScope
    /// e.g. `/accounts/{account_id}/queues`; children use `{parent}`.
    public var listPath: String
    public var itemPath: String?
    public var idField: String
    public var titleFields: [String]
    public var subtitleFields: [String]
    public var statusField: String?
    public var canCreate: Bool
    public var createPath: String?
    /// `PUT`, `PATCH`, or nil when items can't be edited.
    public var updateMethod: String?
    public var canDelete: Bool
    public var paginate: Bool
    public var perPage: Int
    public var listQuery: [String: String?]
    public var keywords: [String]
    public var description: LocalizedText?
    public var children: [ResourceSpec]
    public var actions: [ItemAction]
    public var listActions: [ItemAction]
    /// The field to type to confirm a deletion.
    public var dangerNameField: String?
    public var hiddenCreateFields: Set<String>

    public init(json j: JSON) {
        id = j["id"].string ?? ""
        title = LocalizedText(j["title"]["en"].string ?? "", j["title"]["zh"].string ?? "")
        group = LocalizedText(j["group"]["en"].string ?? "", j["group"]["zh"].string ?? "")
        icon = j["icon"].string ?? ""
        scope = SpecScope(rawValue: j["scope"].string ?? "") ?? .account
        listPath = j["listPath"].string ?? ""
        itemPath = j["itemPath"].string
        idField = j["idField"].string ?? "id"
        titleFields = j["titleFields"].strings
        subtitleFields = j["subtitleFields"].strings
        statusField = j["statusField"].string
        canCreate = j["canCreate"].bool ?? true
        createPath = j["createPath"].string
        updateMethod = j["updateMethod"].string
        canDelete = j["canDelete"].bool ?? true
        paginate = j["paginate"].bool ?? true
        perPage = j["perPage"].int ?? 50
        var q: [String: String?] = [:]
        for (k, v) in j["listQuery"].object ?? [:] { q[k] = v.text }
        listQuery = q
        keywords = j["keywords"].strings
        description = j["description"].isNull
            ? nil : LocalizedText(j["description"]["en"].string ?? "", j["description"]["zh"].string ?? "")
        children = j["children"].items.map { ResourceSpec(json: $0) }
        actions = j["actions"].items.map(ItemAction.init)
        listActions = j["listActions"].items.map(ItemAction.init)
        dangerNameField = j["dangerNameField"].string
        hiddenCreateFields = Set(j["hiddenCreateFields"].strings)
    }

    public var resolvedItemPath: String { itemPath ?? listPath + "/{id}" }
    public var hasItemPath: Bool { itemPath != nil || canDelete || updateMethod != nil }

    public func itemId(_ item: JSON) -> String? {
        let v = item.pick(idField)
        return (v.isNull ? item["id"] : v).text
    }

    public func title(of item: JSON) -> String {
        for f in titleFields {
            let v = item.pick(f)
            if let t = v.text, !t.isEmpty, v.array == nil, v.object == nil { return t }
            if let a = v.array, !a.isEmpty { return Self.display(v) }
        }
        return itemId(item) ?? "—"
    }

    public func subtitle(of item: JSON) -> String {
        subtitleFields.map { Self.display(item.pick($0)) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The status badge of an item: its text and tone.
    public func status(of item: JSON) -> (text: String, tone: StatusTone)? {
        guard let f = statusField else { return nil }
        let v = item.pick(f)
        if v.isNull { return nil }
        if let b = v.bool {
            let positive = f == "suspended" || f == "paused" ? !b : b
            let text: String
            switch f {
            case "enabled": text = b ? "enabled" : "disabled"
            case "suspended": text = b ? "suspended" : "active"
            case "paused": text = b ? "paused" : "active"
            case "allowed": text = b ? "allowed" : "blocked"
            case "success": text = b ? "success" : "failed"
            case "in_use": text = b ? "in use" : "unused"
            default: text = b ? "true" : "false"
            }
            return (text, positive ? .good : .warn)
        }
        let t = v.text ?? ""
        return (t, StatusTone.of(t))
    }

    /// A field value for a subtitle.
    public static func display(_ v: JSON) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "✓" : "✗"
        case .array(let a):
            if a.isEmpty { return "" }
            if a.allSatisfy({ $0.string != nil || $0.double != nil }) { return a.compactMap(\.text).joined(separator: ", ") }
            return L("\(a.count) items", "\(a.count) 项")
        case .object: return "{…}"
        case .string(let s):
            if s.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil, ISODate.parse(s) != nil {
                return Format.date(v)
            }
            return s
        default: return v.text ?? ""
        }
    }

    /// Fills `{id}`, `{parent}` and the scope ids of a path template.
    public static func fill(_ template: String, ids: [String: String?], id: String? = nil, parent: String? = nil) -> String {
        var t = template
        if let id { t = t.replacingOccurrences(of: "{id}", with: id.pathEncoded) }
        if let parent { t = t.replacingOccurrences(of: "{parent}", with: parent.pathEncoded) }
        return expandPath(t, ids: ids)
    }
}

/// A single settings document that can be viewed and replaced or patched.
public struct DocumentSpec: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: LocalizedText
    public var group: LocalizedText
    public var icon: String
    public var path: String
    public var scope: SpecScope
    /// `PUT` / `PATCH`, or nil when read-only.
    public var method: String?
    public var description: LocalizedText?
    public var keywords: [String]

    public init(json j: JSON) {
        id = j["id"].string ?? ""
        title = LocalizedText(j["title"]["en"].string ?? "", j["title"]["zh"].string ?? "")
        group = LocalizedText(j["group"]["en"].string ?? "", j["group"]["zh"].string ?? "")
        icon = j["icon"].string ?? ""
        path = j["path"].string ?? ""
        scope = SpecScope(rawValue: j["scope"].string ?? "") ?? .account
        method = j["method"].string
        description = j["description"].isNull
            ? nil : LocalizedText(j["description"]["en"].string ?? "", j["description"]["zh"].string ?? "")
        keywords = j["keywords"].strings
    }
}

/// Every spec and document, loaded from the bundled `resources.json`.
public final class ResourceCatalog: @unchecked Sendable {
    public let specs: [ResourceSpec]
    public let documents: [DocumentSpec]
    /// Named groups of spec ids (`zone`, `compute`, `access`, …).
    public let lists: [String: [String]]
    private let byId: [String: ResourceSpec]
    private let documentById: [String: DocumentSpec]

    public init(json: JSON) {
        specs = json["specs"].items.map { ResourceSpec(json: $0) }
        documents = json["documents"].items.map { DocumentSpec(json: $0) }
        var l: [String: [String]] = [:]
        for (k, v) in json["lists"].object ?? [:] { l[k] = v.strings }
        lists = l
        var ids: [String: ResourceSpec] = [:]
        func add(_ s: ResourceSpec) {
            ids[s.id] = s
            s.children.forEach(add)
        }
        specs.forEach(add)
        byId = ids
        documentById = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func spec(_ id: String) -> ResourceSpec? { byId[id] }
    public func document(_ id: String) -> DocumentSpec? { documentById[id] }
    public func specs(in list: String) -> [ResourceSpec] { (lists[list] ?? []).compactMap { byId[$0] } }
    public func documents(scope: SpecScope? = nil, group: String? = nil) -> [DocumentSpec] {
        documents.filter { (scope == nil || $0.scope == scope) && (group == nil || $0.group.en == group) }
    }
}

/// Secret-looking values in a create or action result (shown once, to copy).
public func secretsIn(_ result: JSON) -> [(key: String, value: String)] {
    guard let o = result.object else { return [] }
    var out: [(key: String, value: String)] = []
    for k in ["client_secret", "secret", "token", "value", "tunnel_token", "key"] {
        if let v = o[k]?.string, v.count >= 16 { out.append((k, v)) }
    }
    if !out.isEmpty {
        for k in ["client_id", "sitekey", "id", "name"] {
            if let v = o[k]?.string { out.append((k, v)) }
        }
    }
    return out
}

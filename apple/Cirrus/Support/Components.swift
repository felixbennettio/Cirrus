import CirrusKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension StatusTone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}

/// A status as a small coloured capsule.
struct StatusBadge: View {
    let text: String
    var tone: StatusTone?

    init(_ text: String, tone: StatusTone? = nil) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        let c = (tone ?? StatusTone.of(text)).color
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(c)
            .background(c.opacity(0.14), in: .capsule)
    }
}

/// The status badge of a zone (paused zones read as paused).
struct ZoneStatusBadge: View {
    let zone: JSON

    var body: some View {
        if zone["paused"].isTrue {
            StatusBadge("paused", tone: .warn)
        } else {
            StatusBadge(zone["status"].string ?? "")
        }
    }
}

/// A label and a value; long-press (or right-click) copies the value.
struct InfoRow: View {
    let label: String
    let value: String
    var mono = false
    var copy = false

    init(_ label: String, _ value: String?, mono: Bool = false, copy: Bool = false) {
        self.label = label
        self.value = value ?? "—"
        self.mono = mono
        self.copy = copy
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(mono ? .callout.monospaced() : .callout)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if copy {
                    Button {
                        Clipboard.copy(value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Copy", "复制"))
                }
            }
        }
        .contextMenu {
            Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(value) }
        }
    }
}

/// A number with a caption, on a glass tile.
struct StatTile: View {
    let label: String
    let value: String
    var symbol: String?
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.tint) }
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// A grid of stat tiles that wraps to the available width.
struct StatGrid<Content: View>: View {
    var minWidth: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12)], spacing: 12) {
                content
            }
        }
    }
}

/// Pretty JSON in a sheet, selectable and copyable.
struct JSONSheet: View {
    let title: String
    let json: JSON
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(json.prettyString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Done", "完成")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L("Copy", "复制"), systemImage: "doc.on.doc") { Clipboard.copy(json.prettyString) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

/// A JSON value shown in a sheet (for `.sheet(item:)`).
struct JSONItem: Identifiable {
    let id = UUID()
    var title: String
    var json: JSON
}

/// Text to save with `.fileExporter`.
struct TextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(_ text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A file waiting to be saved.
struct ExportItem {
    var file: TextFile
    var name: String
}

extension View {
    /// Inline navigation titles on iOS (no effect on macOS).
    func inlineTitle() -> some View {
        #if os(iOS)
            return navigationBarTitleDisplayMode(.inline)
        #else
            return self
        #endif
    }

    /// For identifiers, keys and host names: no capitalisation or autocorrection.
    func plainInput() -> some View {
        #if os(iOS)
            return textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
            return autocorrectionDisabled()
        #endif
    }

    /// Saves [item] through the system file dialog.
    func exporter(_ item: Binding<ExportItem?>) -> some View {
        fileExporter(
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            document: item.wrappedValue?.file, contentType: .plainText,
            defaultFilename: item.wrappedValue?.name
        ) { _ in }
    }
}

/// A placeholder for empty lists.
struct EmptyState: View {
    let title: String
    let symbol: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        }
    }
}

import CirrusKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// A one-field text prompt (an alert with a text field).
struct TextPrompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var placeholder = ""
    var text = ""
    var confirm = L("Save", "保存")
    var destructive = false
    var action: (String) async -> Void
}

/// A confirmation before an action (a confirmation dialog).
struct ConfirmItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var button: String
    var destructive = true
    var action: () async -> Void
}

private struct TextPromptModifier: ViewModifier {
    @Binding var item: TextPrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(
                item?.title ?? "", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
                presenting: item
            ) { p in
                TextField(p.placeholder, text: $text).plainInput()
                Button(p.confirm, role: p.destructive ? ButtonRole.destructive : nil) {
                    let t = text
                    Task { await p.action(t) }
                }
                Button(L("Cancel", "取消"), role: .cancel) {}
            } message: { p in
                if let m = p.message { Text(m) }
            }
            .onChange(of: item?.id) { _, _ in text = item?.text ?? "" }
    }
}

private struct ConfirmModifier: ViewModifier {
    @Binding var item: ConfirmItem?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            item?.title ?? "", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible, presenting: item
        ) { c in
            Button(c.button, role: c.destructive ? ButtonRole.destructive : nil) { Task { await c.action() } }
        } message: { c in
            if let m = c.message { Text(m) }
        }
    }
}

extension View {
    func textPrompt(_ item: Binding<TextPrompt?>) -> some View { modifier(TextPromptModifier(item: item)) }
    func confirm(_ item: Binding<ConfirmItem?>) -> some View { modifier(ConfirmModifier(item: item)) }

    /// Saves binary data through the system file dialog.
    func dataExporter(_ item: Binding<DataExport?>) -> some View {
        fileExporter(
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            document: item.wrappedValue.map { DataFile($0.data) }, contentType: .data,
            defaultFilename: item.wrappedValue?.name
        ) { _ in }
    }
}

/// A prompt that only runs [action] when the typed text matches [name]
/// (for deleting things that can't be restored).
@MainActor
func typedDelete(
    _ title: String, name: String, message: String, feedback: Feedback, action: @escaping () async -> Void
) -> TextPrompt {
    TextPrompt(
        title: title, message: message + "\n" + L("Type \(name) to confirm.", "输入 \(name) 以确认。"), placeholder: name,
        confirm: L("Delete", "删除"), destructive: true
    ) { typed in
        if typed.trimmingCharacters(in: .whitespaces) == name {
            await action()
        } else {
            feedback.show(L("The name did not match; nothing was deleted.", "名称不匹配，未删除。"), error: true)
        }
    }
}

/// Bytes to save with `.dataExporter`.
struct DataExport {
    var data: Data
    var name: String
}

struct DataFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(_ data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// An image from encoded bytes.
func platformImage(_ data: Data) -> Image? {
    #if os(iOS)
        return UIImage(data: data).map { Image(uiImage: $0) }
    #else
        return NSImage(data: data).map { Image(nsImage: $0) }
    #endif
}

/// Sub-pages of a screen as a scrolling row of glass capsules.
struct SectionTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(tabs) { t in
                        Button {
                            withAnimation(.snappy) { selection = t }
                        } label: {
                            Text(title(t))
                                .font(.subheadline.weight(t == selection ? .semibold : .regular))
                                .foregroundStyle(t == selection ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            t == selection ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Shows [content] for the current account, or why there is none.
struct AccountRequired<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: (String) -> Content

    var body: some View {
        if let id = model.accountId {
            content(id).id(id)
        } else if model.accountsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(L("No account", "无账户"), systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text(model.accountsError ?? L("This credential can't see any account.", "当前凭据看不到任何账户。"))
            } actions: {
                Button(L("Try again", "重试")) { Task { await model.refresh() } }.buttonStyle(.glass)
            }
        }
    }
}

/// [content] when Cirrus Pro is available, else the paywall for [feature].
struct ProGate<Content: View>: View {
    let feature: ProFeature
    @ViewBuilder var content: () -> Content
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.pro.hasPro {
            content()
        } else {
            PaywallView(feature: feature)
        }
    }
}

/// A monospaced, plain text editor for code and JSON.
struct CodeEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .plainInput()
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

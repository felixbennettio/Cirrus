import Foundation

/// The app's languages. Strings are written in pairs next to each other
/// (`L("Delete", "删除")`), like the Flutter app does, so the large UI stays
/// in sync without a separate key catalogue and the language can change
/// inside the app.
public enum AppLanguage: String, Sendable, CaseIterable {
    case en
    case zh

    /// The language chosen in the settings (nil follows the system).
    public static func resolve(_ code: String?) -> AppLanguage {
        if let code = code?.lowercased(), !code.isEmpty { return code.hasPrefix("zh") ? .zh : .en }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    /// The language strings are currently shown in.
    public static var current: AppLanguage {
        get { box.value }
        set { box.value = newValue }
    }

    private static let box = LanguageBox()

    /// A locale for number and date formatting in this language.
    public var locale: Locale { Locale(identifier: self == .zh ? "zh_Hans_CN" : "en_US") }
}

private final class LanguageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AppLanguage = AppLanguage.resolve(nil)
    var value: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

/// A string in both languages, for tables of static data.
public struct LocalizedText: Hashable, Sendable {
    public let en: String
    public let zh: String

    public init(_ en: String, _ zh: String) {
        self.en = en
        self.zh = zh
    }

    public var text: String { AppLanguage.current == .zh ? zh : en }
}

/// The English or Chinese string, for the current language.
public func L(_ en: String, _ zh: String) -> String {
    AppLanguage.current == .zh ? zh : en
}

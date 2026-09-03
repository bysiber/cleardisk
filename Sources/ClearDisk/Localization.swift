import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Keep language names recognizable even before the interface changes language.
    var title: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static var current: AppLanguage {
        guard
            let storedValue = UserDefaults.standard.string(forKey: storageKey),
            let language = AppLanguage(rawValue: storedValue)
        else {
            // ClearDisk intentionally starts in English instead of inheriting the system language.
            return .english
        }
        return language
    }
}

extension Notification.Name {
    static let clearDiskLanguageDidChange = Notification.Name("ClearDisk.languageDidChange")
}

private enum AppLocalization {
    private static var bundles: [AppLanguage: Bundle] = [:]
    private static let lock = NSLock()

    static func bundle(for language: AppLanguage) -> Bundle {
        lock.lock()
        defer { lock.unlock() }

        if let cached = bundles[language] {
            return cached
        }

        let localizedBundle = Bundle.main.path(
            forResource: language.rawValue,
            ofType: "lproj"
        ).flatMap(Bundle.init(path:)) ?? Bundle.main
        bundles[language] = localizedBundle
        return localizedBundle
    }
}

/// Looks up a localized rendering of an English source string.
///
/// SwiftUI views take `LocalizedStringKey` and localize their literals on their own, so this
/// helper exists for the plain `String` values that never reach a view initializer directly:
/// cache names, descriptions, safety notes, and notification text.
///
/// The English text is the key, which keeps call sites readable and makes an untranslated
/// string fall back to itself rather than to a placeholder identifier.
func L(_ key: String) -> String {
    AppLocalization.bundle(for: .current)
        .localizedString(forKey: key, value: key, table: nil)
}

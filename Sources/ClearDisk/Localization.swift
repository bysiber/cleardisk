import Foundation

/// Looks up a localized rendering of an English source string.
///
/// SwiftUI views take `LocalizedStringKey` and localize their literals on their own, so this
/// helper exists for the plain `String` values that never reach a view initializer directly:
/// cache names, descriptions, safety notes, and notification text.
///
/// The English text is the key, which keeps call sites readable and makes an untranslated
/// string fall back to itself rather than to a placeholder identifier.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

import Foundation

/// Centralized localization access for strings produced outside SwiftUI.
/// SwiftUI string literals are localized automatically from Localizable.strings.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}

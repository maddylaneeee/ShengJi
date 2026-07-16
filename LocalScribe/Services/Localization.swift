import Foundation

/// Centralized localization access for strings produced outside SwiftUI.
/// SwiftUI string literals are localized automatically from Localizable.strings.
enum L10n {
    static func text(_ key: String, languageCode: String? = nil) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle(for: languageCode),
            value: key,
            comment: ""
        )
    }

    static func format(
        _ key: String,
        languageCode: String? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let locale = languageCode.map(Locale.init(identifier:)) ?? .current
        return String(
            format: text(key, languageCode: languageCode),
            locale: locale,
            arguments: arguments
        )
    }

    private static func bundle(for languageCode: String?) -> Bundle {
        guard let languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return .main
        }
        return localizedBundle
    }
}

import Foundation

/// Centralized localization access for strings produced outside SwiftUI.
/// SwiftUI string literals are localized automatically from Localizable.strings.
enum L10n {
    static func text(_ key: String, languageCode: String? = nil) -> String {
        let resolvedLanguageCode = languageCode ?? preferredLanguageCode
        return NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle(for: resolvedLanguageCode),
            value: key,
            comment: ""
        )
    }

    static func format(
        _ key: String,
        languageCode: String? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let locale = (languageCode ?? preferredLanguageCode).map(Locale.init(identifier:)) ?? .current
        return String(
            format: text(key, languageCode: languageCode),
            locale: locale,
            arguments: arguments
        )
    }

    static var interfaceLocale: Locale {
        preferredLanguageCode.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    static var preferredLanguageCode: String? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return nil
        }
        return language.languageCode
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

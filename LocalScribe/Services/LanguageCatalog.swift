import Foundation
import Observation
import Speech

@MainActor
@Observable
final class LanguageCatalog {
    private(set) var languages: [LanguageOption] = []
    private(set) var recommendedLanguages: [LanguageOption] = []
    private(set) var isLoading = true
    private(set) var isSpeechAvailable = false
    var selectedLocaleIdentifier = Locale.current.identifier

    var selectedLocale: Locale {
        languages.first(where: { $0.id == selectedLocaleIdentifier })?.locale
            ?? Locale(identifier: selectedLocaleIdentifier)
    }

    var selectedLanguage: LanguageOption? {
        languages.first(where: { $0.id == selectedLocaleIdentifier })
    }

    func load() async {
        isLoading = true
        guard #available(macOS 26.0, *) else {
            isSpeechAvailable = false
            // On macOS 15.5–25 SpeechTranscriber is unavailable, but the
            // bundled third-party engines (Whisper, SenseVoice, Parakeet)
            // still support many languages. Fall back to the Whisper
            // multilingual catalog so the language picker stays useful.
            languages = Self.whisperSupportedLanguages
            recommendedLanguages = Self.recommendations(from: languages, deviceLocale: .current)
            if let device = Self.bestMatch(for: .current, in: languages) {
                selectedLocaleIdentifier = device.id
            } else if let first = languages.first {
                selectedLocaleIdentifier = first.id
            }
            isLoading = false
            return
        }
        isSpeechAvailable = SpeechTranscriber.isAvailable
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set((await SpeechTranscriber.installedLocales).map(\.identifier))
        languages = supported
            .map { LanguageOption(locale: $0, isInstalled: installed.contains($0.identifier)) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        recommendedLanguages = Self.recommendations(from: languages, deviceLocale: .current)

        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            selectedLocaleIdentifier = equivalent.identifier
        } else if let firstInstalled = languages.first(where: \.isInstalled) {
            selectedLocaleIdentifier = firstInstalled.id
        } else if let first = languages.first {
            selectedLocaleIdentifier = first.id
        }
        isLoading = false
    }

    var otherLanguages: [LanguageOption] {
        let recommendedIDs = Set(recommendedLanguages.map(\.id))
        return languages.filter { !recommendedIDs.contains($0.id) }
    }

    /// Language codes supported by whisper.cpp multilingual models
    /// (ISO 639, matching whisper's built-in language table). Used as the
    /// recognition language catalog on macOS 15.5–25 where SpeechTranscriber
    /// supportedLocales is unavailable.
    static let whisperLanguageIdentifiers: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
        "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
        "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
        "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
        "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
        "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]

    /// Whisper's multilingual catalog, sorted by localized display name.
    static var whisperSupportedLanguages: [LanguageOption] {
        whisperLanguageIdentifiers
            .map { LanguageOption(locale: Locale(identifier: $0), isInstalled: true) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func recommendations(
        from languages: [LanguageOption],
        deviceLocale: Locale
    ) -> [LanguageOption] {
        guard !languages.isEmpty else { return [] }

        let deviceLanguageCode = deviceLocale.language.languageCode?.identifier
        let device = bestMatch(for: deviceLocale, in: languages)
        let english = bestEnglishMatch(for: deviceLocale, in: languages)

        if deviceLanguageCode == "en" {
            return [device ?? english].compactMap { $0 }
        }

        var result: [LanguageOption] = []
        for candidate in [english, device].compactMap({ $0 }) where !result.contains(where: { $0.id == candidate.id }) {
            result.append(candidate)
        }
        return result
    }

    private static func bestMatch(
        for locale: Locale,
        in languages: [LanguageOption]
    ) -> LanguageOption? {
        if let exact = languages.first(where: { $0.id == locale.identifier }) {
            return exact
        }
        let languageCode = locale.language.languageCode?.identifier
        return languages.first {
            $0.locale.language.languageCode?.identifier == languageCode
        }
    }

    private static func bestEnglishMatch(
        for deviceLocale: Locale,
        in languages: [LanguageOption]
    ) -> LanguageOption? {
        if deviceLocale.language.languageCode?.identifier == "en",
           let deviceMatch = bestMatch(for: deviceLocale, in: languages) {
            return deviceMatch
        }
        return languages.first(where: { $0.id == "en_US" })
            ?? languages.first(where: { $0.id == "en-US" })
            ?? languages.first {
                $0.locale.language.languageCode?.identifier == "en"
            }
    }
}

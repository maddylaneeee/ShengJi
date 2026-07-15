import Foundation
import Observation
import Speech

@MainActor
@Observable
final class LanguageCatalog {
    private(set) var languages: [LanguageOption] = []
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
            languages = [LanguageOption(locale: Locale.current, isInstalled: false)]
            selectedLocaleIdentifier = Locale.current.identifier
            isLoading = false
            return
        }
        isSpeechAvailable = SpeechTranscriber.isAvailable
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set((await SpeechTranscriber.installedLocales).map(\.identifier))
        languages = supported
            .map { LanguageOption(locale: $0, isInstalled: installed.contains($0.identifier)) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            selectedLocaleIdentifier = equivalent.identifier
        } else if let firstInstalled = languages.first(where: \.isInstalled) {
            selectedLocaleIdentifier = firstInstalled.id
        } else if let first = languages.first {
            selectedLocaleIdentifier = first.id
        }
        isLoading = false
    }
}

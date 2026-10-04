import AVFoundation
import Foundation
import NaturalLanguage
import Observation

struct SpeechVoiceOption: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let language: String
    static func isAllowed(identifier: String, language: String, allowAll: Bool) -> Bool {
        allowAll || (identifier.hasPrefix("com.apple.siri.natural.") && Locale(identifier: language).language.languageCode?.identifier == "en")
    }
    var title: String { "\(name) · \(language) · \(id.components(separatedBy: ".").last ?? id)" }
}

@MainActor @Observable
final class SpeechSynthesisPreferences {
    static let shared = SpeechSynthesisPreferences()
    private let defaults: UserDefaults
    var allowAll: Bool { didSet { defaults.set(allowAll, forKey: "AllowAllSpeechSynthesis") } }
    var lastVoiceIdentifier: String { didSet { defaults.set(lastVoiceIdentifier, forKey: "LastSynthesisVoice") } }
    init(defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults: UserDefaults
#if DEBUG
        if suppliedDefaults == nil, let root = ProcessInfo.processInfo.environment["LOCALSCRIBE_TEST_DATA_ROOT"] {
            defaults = UserDefaults(suiteName: "ca.lixinchen.localscribe.validation." + URL(fileURLWithPath: root).lastPathComponent)!
            if let value = ProcessInfo.processInfo.environment["LOCALSCRIBE_TEST_ALLOW_ALL"] { defaults.set(value == "1", forKey: "AllowAllSpeechSynthesis") }
        } else { defaults = suppliedDefaults ?? .standard }
#else
        defaults = suppliedDefaults ?? .standard
#endif
        self.defaults = defaults
        allowAll = defaults.bool(forKey: "AllowAllSpeechSynthesis")
        lastVoiceIdentifier = defaults.string(forKey: "LastSynthesisVoice") ?? ""
    }
}

@MainActor @Observable
final class SpeechVoiceCatalog {
    var voices: [SpeechVoiceOption] = []
    private let provider: () -> [SpeechVoiceOption]
    init(provider: @escaping () -> [SpeechVoiceOption] = {
        AVSpeechSynthesisVoice.speechVoices().map { SpeechVoiceOption(id: $0.identifier, name: $0.name, language: $0.language) }
    }) { self.provider = provider }
    func refresh(allowAll: Bool) {
        guard SessionAudioFeatures.speechSynthesisEnabled else { voices = []; return }
        voices = provider().filter {
            SpeechVoiceOption.isAllowed(identifier: $0.id, language: $0.language, allowAll: allowAll)
        }.sorted { $0.id < $1.id }
    }
    static func independentEntryAllowed(allowAll: Bool, effectiveLanguage: String, hasVoices: Bool) -> Bool {
        SessionAudioFeatures.speechSynthesisEnabled && hasVoices && (allowAll || Locale(identifier: effectiveLanguage).language.languageCode?.identifier == "en")
    }
    static var effectiveInterfaceLanguage: String {
        L10n.preferredLanguageCode ?? Bundle.main.preferredLocalizations.first ?? "en"
    }
}

enum SpeechTextLanguage: Equatable, Sendable {
    case english, other(String), uncertain
    static func detect(_ text: String) -> Self {
        let sample = String(text.prefix(20_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.filter(\.isLetter).count >= 12 else { return .uncertain }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let sorted = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        guard let first = sorted.first, first.value >= 0.70,
              sorted.dropFirst().first.map({ first.value - $0.value >= 0.30 }) ?? true else { return .uncertain }
        let code = Locale(identifier: first.key.rawValue).language.languageCode?.identifier ?? first.key.rawValue
        // Look for substantial language mixing at paragraph/sentence boundaries too.
        let parts = sample.components(separatedBy: CharacterSet(charactersIn: ".!?。！？\n"))
        for part in parts where part.filter(\.isLetter).count >= 12 {
            let r = NLLanguageRecognizer(); r.processString(part)
            if let candidate = r.languageHypotheses(withMaximum: 1).first, candidate.value >= 0.80,
               Locale(identifier: candidate.key.rawValue).language.languageCode?.identifier != code { return .uncertain }
        }
        return code == "en" ? .english : .other(code)
    }
    var languageCode: String? {
        switch self { case .english: "en"; case .other(let code): code; case .uncertain: nil }
    }
    func permits(allowAll: Bool, englishConfirmed: Bool) -> Bool {
        if allowAll { return true }
        switch self { case .english: return true; case .other: return false; case .uncertain: return englishConfirmed }
    }
}

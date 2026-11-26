import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Sampling for one request. `temperature == nil` means greedy decoding.
struct AFMGenerationOptions: Equatable, Sendable {
    var temperature: Double?
    var maximumResponseTokens: Int

    static func greedy(maximumResponseTokens: Int) -> AFMGenerationOptions {
        AFMGenerationOptions(temperature: nil, maximumResponseTokens: maximumResponseTokens)
    }
}

/// The text-generation surface used by translation and AI optimization.
/// Tests inject fakes; production uses `SystemAppleIntelligenceGenerator`.
protocol AppleIntelligenceGenerating: Sendable {
    /// Streams cumulative snapshots of the response and returns the final text.
    func generate(
        instructions: String,
        prompt: String,
        options: AFMGenerationOptions,
        onSnapshot: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

/// Internal classification of Foundation Models errors from both the
/// macOS 26 (`LanguageModelSession.GenerationError`) and macOS 27
/// (`LanguageModelError`) SDKs.
enum AFMFailure: Error, Equatable, Sendable, LocalizedError {
    case contextExceeded
    case guardrail
    case refusal
    case unsupportedLanguage
    case rateLimited
    case busy
    case timeout
    case unavailable(String)

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .busy, .timeout: true
        default: false
        }
    }

    /// Content-specific rejections are retried with smaller windows.
    var isContentRejection: Bool { self == .guardrail || self == .refusal }

    var errorDescription: String? {
        switch self {
        case .contextExceeded: L10n.text("内容超出 Apple 智能的上下文长度。")
        case .guardrail, .refusal: L10n.text("Apple 智能拒绝处理部分内容。")
        case .unsupportedLanguage: L10n.text("Apple 智能不支持当前语言。")
        case .rateLimited, .busy: L10n.text("Apple 智能正忙，请稍后重试。")
        case .timeout: L10n.text("Apple 智能请求超时。")
        case .unavailable(let reason): L10n.format("Apple 智能暂不可用：%@", reason)
        }
    }

    /// `nil` for cancellation.
    static func classify(_ error: Error) -> AFMFailure? {
        if error is CancellationError { return nil }
        if let failure = error as? AFMFailure { return failure }
        let label = caseLabel(of: error)
        switch label {
        case "exceededContextWindowSize", "contextSizeExceeded": return .contextExceeded
        case "guardrailViolation": return .guardrail
        case "refusal": return .refusal
        case "unsupportedLanguageOrLocale": return .unsupportedLanguage
        case "rateLimited": return .rateLimited
        case "concurrentRequests": return .busy
        case "timeout": return .timeout
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return nil }
            let description = (error as? LocalizedError)?.errorDescription ?? nsError.localizedDescription
            return .unavailable(description)
        }
    }

    /// Enum case name, read reflectively so that SDK-specific error types do
    /// not need to exist at compile time.
    static func caseLabel(of error: Error) -> String {
        if let label = Mirror(reflecting: error).children.first?.label { return label }
        let description = String(describing: error)
        return String(description.prefix { $0 != "(" }).components(separatedBy: ".").last ?? description
    }
}

/// Serializes on-device model calls: a session accepts one request at a time
/// and concurrent requests across sessions are rate limited by the system.
actor AppleIntelligenceGate {
    static let shared = AppleIntelligenceGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

struct SystemAppleIntelligenceGenerator: AppleIntelligenceGenerating {
    func generate(
        instructions: String,
        prompt: String,
        options: AFMGenerationOptions,
        onSnapshot: @escaping @Sendable (String) -> Void
    ) async throws -> String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await AppleIntelligenceGate.shared.withExclusiveAccess {
                try await Self.stream(instructions: instructions, prompt: prompt, options: options, onSnapshot: onSnapshot)
            }
        }
#endif
        throw AFMFailure.unavailable(AppleIntelligenceStatus.osTooOld.message)
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func stream(
        instructions: String,
        prompt: String,
        options: AFMGenerationOptions,
        onSnapshot: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let generationOptions: GenerationOptions
        if let temperature = options.temperature {
            generationOptions = GenerationOptions(temperature: temperature, maximumResponseTokens: options.maximumResponseTokens)
        } else {
#if compiler(>=6.4)
            generationOptions = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: options.maximumResponseTokens)
#else
            generationOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: options.maximumResponseTokens)
#endif
        }
        var latest = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt, options: generationOptions) {
                try Task.checkCancellation()
                latest = snapshot.content
                onSnapshot(latest)
            }
        } catch {
            if let failure = AFMFailure.classify(error) { throw failure }
            throw CancellationError()
        }
        return latest
    }
#endif
}

/// Parsed `[n] text` output with an optional `TERMS:` / `STYLE:` trailer.
struct AFMNumberedOutput: Equatable, Sendable {
    var lines: [Int: String] = [:]
    /// Numbers that appeared more than once; their text is unreliable.
    var duplicates: Set<Int> = []
    /// The number of the last line while it may still be growing.
    var openLine: Int?
    var terms: [AFMTerm] = []
    /// Trailer answers of the form "(n) translation" for the prompt's NAMES list.
    var nameTranslations: [Int: String] = [:]
    var style: String?
    /// Text before the first marker (often a refusal or a preamble).
    var preamble = ""

    var closedLines: [Int: String] {
        guard let openLine else { return lines }
        return lines.filter { $0.key != openLine }
    }
}

struct AFMTerm: Equatable, Sendable {
    let source: String
    let target: String
}

enum AFMNumberedLineParser {
    /// Parses a cumulative snapshot. When `isFinal` is false the last numbered
    /// line is reported as open.
    static func parse(_ raw: String, isFinal: Bool) -> AFMNumberedOutput {
        var output = AFMNumberedOutput()
        var current: Int?
        var inTrailer = false
        var seen: Set<Int> = []
        for rawLine in normalized(raw).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            if let marker = trailerMarker(line) {
                inTrailer = true
                current = nil
                if marker.kind == "STYLE", !marker.rest.isEmpty { output.style = marker.rest }
                if marker.kind == "TERMS", let (number, value) = numberedName(marker.rest) {
                    output.nameTranslations[number] = value
                } else if marker.kind == "TERMS", let term = parseTerm(marker.rest) {
                    output.terms.append(term)
                }
                continue
            }
            if inTrailer {
                if let (number, value) = numberedName(line) {
                    output.nameTranslations[number] = value
                } else if let term = parseTerm(line) {
                    output.terms.append(term)
                } else if let style = trailerMarker(line), style.kind == "STYLE" {
                    output.style = style.rest
                }
                continue
            }
            // "(n) …" answers the NAMES list even when the model omits "TERMS:".
            if current != nil, line.hasPrefix("(") || line.hasPrefix("（"), let (number, value) = numberedName(line) {
                inTrailer = true
                current = nil
                output.nameTranslations[number] = value
                continue
            }
            if let (number, text) = numberedLine(line) {
                if seen.contains(number) { output.duplicates.insert(number) }
                seen.insert(number)
                let cleaned = strippingTrailingMarker(text)
                output.lines[number] = cleaned
                if cleaned != text { inTrailer = true; current = nil; continue }
                current = number
                continue
            }
            guard !line.isEmpty else { continue }
            if let open = current {
                let existing = output.lines[open] ?? ""
                let joined = existing.isEmpty ? line : existing + " " + line
                let cleaned = strippingTrailingMarker(joined)
                output.lines[open] = cleaned
                if cleaned != joined {
                    inTrailer = true
                    current = nil
                }
            } else {
                output.preamble += output.preamble.isEmpty ? line : " " + line
            }
        }
        if !isFinal, !inTrailer { output.openLine = current }
        return output
    }

    static func normalized(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (from, to) in [("［", "["), ("］", "]"), ("【", "["), ("】", "]")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        let fullWidthDigits = "０１２３４５６７８９"
        for (index, character) in fullWidthDigits.enumerated() {
            value = value.replacingOccurrences(of: String(character), with: String(index))
        }
        return value
    }

    private static func numberedLine(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("[") || line.hasPrefix("**[") else { return nil }
        var rest = Substring(line)
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        rest = rest.dropFirst()
        let digits = rest.prefix { $0.isWhitespace || $0.isNumber }
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix("]") else { return nil }
        rest = rest.dropFirst()
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return (number, text)
    }

    /// "(3) 埃琳娜·沃加", "3) …", "3. …" or "(3) Elena Varga => 埃琳娜·沃加".
    private static func numberedName(_ line: String) -> (Int, String)? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("-") || rest.hasPrefix("•") { rest = rest.dropFirst().drop { $0 == " " } }
        let opened = rest.hasPrefix("(") || rest.hasPrefix("（")
        if opened { rest = rest.dropFirst() }
        let digits = rest.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        rest = rest.dropFirst(digits.count)
        guard let close = rest.first, [")", "）", "."].contains(close) || (!opened && close == ":") else { return nil }
        rest = rest.dropFirst()
        var value = rest.trimmingCharacters(in: .whitespaces)
        for separator in ["=>", "->", "→", "：", ":"] where value.contains(separator) {
            value = value.components(separatedBy: separator).last?.trimmingCharacters(in: .whitespaces) ?? value
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        guard !value.isEmpty, value.count <= 80 else { return nil }
        return (number, value)
    }

    /// Marker spellings, including ones the model sometimes translates into the target language.
    private static let markerAliases: [(kind: String, spellings: [String])] = [
        ("TERMS", ["TERMS", "TERM", "GLOSSARY", "术语", "術語", "用语", "用語", "词表", "용어"]),
        ("STYLE", ["STYLE", "风格", "風格", "スタイル", "文体", "스타일"]),
    ]

    private static func trailerMarker(_ line: String) -> (kind: String, rest: String)? {
        let stripped = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        let upper = stripped.uppercased()
        for (kind, spellings) in markerAliases {
            for spelling in spellings where upper.hasPrefix(spelling) {
                let afterKind = stripped.dropFirst(spelling.count)
                guard let first = afterKind.first, first == ":" || first == "：" else { continue }
                return (kind, afterKind.dropFirst().trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Removes a dangling "TERMS:" (or a translated spelling) glued to the end of a line.
    static func strippingTrailingMarker(_ text: String) -> String {
        let spellings = markerAliases.flatMap(\.spellings).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "\\s*\\**(?:" + spellings + ")\\**\\s*[:：]\\**\\s*$"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func parseTerm(_ line: String) -> AFMTerm? {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("-") || value.hasPrefix("•") || value.hasPrefix("*") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for separator in ["=>", "->", "→", "⇒", "＝>"] {
            let parts = value.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let source = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
            let target = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
            guard !source.isEmpty, !target.isEmpty,
                  source.count <= 80, target.count <= 80,
                  source.uppercased() != "NONE" else { return nil }
            return AFMTerm(source: source, target: target)
        }
        return nil
    }
}

enum AFMRefusalDetector {
    private static let prefixes = [
        "sorry, i can", "sorry, but i can", "i'm sorry", "i’m sorry", "i am sorry",
        "i cannot", "i can't", "i can’t", "i'm unable", "i’m unable", "i am unable",
        "as an ai", "i apologize",
        "抱歉", "很抱歉", "对不起", "我无法", "我不能",
        "申し訳", "すみません",
    ]

    /// True when `output` reads like a refusal that is not explained by the source.
    static func isRefusal(_ output: String, source: String) -> Bool {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard prefixes.contains(where: { value.hasPrefix($0) }) else { return false }
        let original = source.lowercased()
        return !prefixes.contains(where: { original.contains($0) })
            && !["sorry", "apolog", "unable", "cannot", "can't"].contains(where: { original.contains($0) })
    }
}

enum AFMLanguage {
    /// English language names work best in model instructions.
    static func englishName(for locale: Locale) -> String {
        let language = Locale.Language(identifier: locale.identifier)
        let code = language.languageCode?.identifier ?? locale.identifier
        if code == "zh" {
            let script = language.script?.identifier
            let region = language.region?.identifier
            if script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? "")) {
                return "Traditional Chinese"
            }
            return "Simplified Chinese"
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Dominant language of `text`, used to keep summaries in the transcript's language.
    static func dominantLanguageName(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        guard let language = recognizer.dominantLanguage else { return "the transcript's language" }
        switch language {
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        default:
            return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? "the transcript's language"
        }
    }
}

enum AFMPrompt {
    static func instructions(_ id: AIPromptID, values: [String: String] = [:]) throws -> String {
        var text = try AIPromptLoader.load(id)
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }

    /// Persistent plus one-time guidance, capped so that it cannot crowd out the transcript.
    static func userPreferences(_ guidance: String) -> String? {
        let trimmed = String(guidance.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "User preferences (style and terminology only):\n\(trimmed)"
    }

    static func flattened(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Retries transient AFM failures with a short backoff.
enum AFMRetry {
    static func run<T: Sendable>(
        attempts: Int = 3,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                guard let failure = AFMFailure.classify(error) else { throw CancellationError() }
                attempt += 1
                guard failure.isRetryable, attempt < attempts else { throw failure }
                try await Task.sleep(for: .milliseconds(1_000 * attempt + 500))
            }
        }
    }
}

/// Proper names in a translation window, extracted locally so that the
/// glossary's source side never depends on the model.
enum AFMNameExtractor {
    static func names(in text: String, limit: Int = 12) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []
        let titles: Set<String> = ["dr", "mr", "mrs", "ms", "miss", "prof", "professor", "sir", "madam", "doctor", "president"]
        func add(_ value: String) {
            var words = value.split(separator: " ").map(String.init)
            while let first = words.first, titles.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                words.removeFirst()
            }
            let trimmed = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !titles.contains(trimmed.lowercased()) else { return }
            guard trimmed.count >= 2, trimmed.count <= 60, output.count < limit,
                  seen.insert(trimmed.lowercased()).inserted else { return }
            output.append(trimmed)
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let types: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag, types.contains(tag) else { return true }
            let name = String(text[range])
            add(name)
            // Surnames are how people are usually referred to later.
            let parts = name.split(separator: " ")
            if tag == .personalName, parts.count >= 2, let last = parts.last { add(String(last)) }
            return true
        }
        // Multi-word capitalized phrases (organizations and places NLTagger may miss).
        if let regex = try? NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z'’-]+(?:\s+[A-Z][a-zA-Z'’-]+)+\b"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let phrase = String(text[swiftRange])
                let first = phrase.split(separator: " ").first.map(String.init) ?? ""
                let stop: Set<String> = ["The", "A", "An", "And", "But", "So", "Now", "Then", "Good", "Thank", "Finally", "Every", "Last", "Their", "If", "Our", "We", "I", "It", "This", "That"]
                let cleaned = stop.contains(first) ? phrase.split(separator: " ").dropFirst().joined(separator: " ") : phrase
                if cleaned.contains(" ") { add(cleaned) }
            }
        }
        return output
    }
}

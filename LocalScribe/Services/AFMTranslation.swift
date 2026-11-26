import Foundation

/// Glossary and style notes carried from one translation window to the next.
/// Lives only for one translation run; it is never shown or stored.
struct TranslationMemory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let source: String
        let target: String
        var lastSeen: Int
    }

    static let maximumEntries = 40
    static let maximumNewEntriesPerWindow = 8

    private(set) var entries: [String: Entry] = [:]
    var style: String?

    /// Adds new terms that occur in the window. Existing translations are never
    /// overwritten so that names stay consistent across the transcript.
    mutating func merge(_ terms: [AFMTerm], windowText: String, windowIndex: Int) {
        let haystack = windowText.lowercased()
        var added = 0
        for candidate in terms {
            // The model sometimes writes "translation => original"; orient by the source text.
            let term: AFMTerm
            if haystack.contains(candidate.source.lowercased()) {
                term = candidate
            } else if haystack.contains(candidate.target.lowercased()) {
                term = AFMTerm(source: candidate.target, target: candidate.source)
            } else {
                continue
            }
            let key = term.source.lowercased()
            guard term.source.lowercased() != term.target.lowercased() else { continue }
            if entries[key] != nil {
                entries[key]?.lastSeen = windowIndex
                continue
            }
            guard added < Self.maximumNewEntriesPerWindow else { continue }
            entries[key] = Entry(source: term.source, target: term.target, lastSeen: windowIndex)
            added += 1
        }
        touch(windowText: windowText, windowIndex: windowIndex)
        while entries.count > Self.maximumEntries,
              let oldest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func touch(windowText: String, windowIndex: Int) {
        let haystack = windowText.lowercased()
        for key in entries.keys where haystack.contains(key) {
            entries[key]?.lastSeen = windowIndex
        }
    }

    mutating func setStyleIfNeeded(_ value: String?) {
        guard style == nil, let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return }
        style = trimmed
    }

    /// Removes a trailing "(Original)" that the model sometimes appends to a translation.
    static func strippingEcho(_ value: String, source: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, last == ")" || last == "）",
              let open = text.lastIndex(where: { $0 == "(" || $0 == "（" }) else { return text }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        if inner.lowercased() == source.lowercased() || inner.unicodeScalars.allSatisfy({ $0.isASCII }) {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Entries whose source occurs in `text`, most recently used first, within `tokenLimit`.
    func relevant(to text: String, tokenLimit: Int) -> [Entry] {
        let haystack = text.lowercased()
        var output: [Entry] = []
        var used = 0
        for entry in entries.values
            .filter({ haystack.contains($0.source.lowercased()) })
            .sorted(by: { ($0.lastSeen, $0.source) > ($1.lastSeen, $1.source) }) {
            let cost = TokenBudget.estimate("\(entry.source) => \(entry.target)") + 2
            guard used + cost <= tokenLimit else { break }
            used += cost
            output.append(entry)
        }
        return output
    }
}

/// Translates transcript units with the on-device Apple Foundation Model.
struct AFMTranslationEngine: Sendable {
    let generator: any AppleIntelligenceGenerating
    let windows: TokenBudget.Windows
    /// Apple Translation, used for content AFM refuses or cannot handle.
    let substitute: @Sendable (_ texts: [String], _ sourceLocale: Locale, _ target: TranslationTargetLanguage) async throws -> [String]
    let supportsLanguage: @Sendable (Locale) -> Bool
    var extractNames: @Sendable (String) -> [String] = { AFMNameExtractor.names(in: $0) }

    static func live(substitute: @escaping @Sendable ([String], Locale, TranslationTargetLanguage) async throws -> [String]) -> AFMTranslationEngine {
        AFMTranslationEngine(
            generator: SystemAppleIntelligenceGenerator(),
            windows: .current,
            substitute: substitute,
            supportsLanguage: { AppleIntelligenceSupport.supportsLanguage(of: $0) }
        )
    }

    func translate(
        units: [TranslationUnit],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        onProgress: (@Sendable (TranslationProgress) -> Void)? = nil,
        onPartialResult: (@Sendable (SegmentTranslation) -> Void)? = nil,
        onNotice: (@Sendable (String) -> Void)? = nil
    ) async -> [SegmentTranslation] {
        let run = AFMTranslationRun(
            engine: self,
            units: units,
            sourceLocale: sourceLocale,
            targetLanguage: targetLanguage,
            onProgress: onProgress,
            onPartialResult: onPartialResult
        )
        return await run.execute(onNotice: onNotice)
    }
}

/// One translation run. Used from a single task, never concurrently.
private final class AFMTranslationRun: @unchecked Sendable {
    struct Line {
        let unitIndex: Int
        let text: String
        let tokens: Int
    }

    enum LineResult {
        case translated(String)
        case substituted(String)
        case failed(String)

        var text: String? {
            switch self {
            case .translated(let value), .substituted(let value): value
            case .failed: nil
            }
        }
    }

    let engine: AFMTranslationEngine
    let units: [TranslationUnit]
    let sourceLocale: Locale
    let targetLanguage: TranslationTargetLanguage
    let onProgress: (@Sendable (TranslationProgress) -> Void)?
    let onPartialResult: (@Sendable (SegmentTranslation) -> Void)?

    let lines: [Line]
    let linesByUnit: [[Int]]
    var results: [Int: LineResult] = [:]
    var memory = TranslationMemory()
    var windowCounter = 0
    /// Set when AFM must not be called again in this run.
    var stopReason: String?
    let instructions: String?

    init(
        engine: AFMTranslationEngine,
        units: [TranslationUnit],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        onProgress: (@Sendable (TranslationProgress) -> Void)?,
        onPartialResult: (@Sendable (SegmentTranslation) -> Void)?
    ) {
        self.engine = engine
        self.units = units
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
        self.onProgress = onProgress
        self.onPartialResult = onPartialResult
        var lines: [Line] = []
        var linesByUnit: [[Int]] = []
        for (unitIndex, unit) in units.enumerated() {
            var indices: [Int] = []
            let flattened = AFMPrompt.flattened(unit.sourceText)
            if !flattened.isEmpty {
                for piece in TokenBudget.pieces(of: flattened, limit: engine.windows.maximumSourceTokens) {
                    indices.append(lines.count)
                    lines.append(Line(unitIndex: unitIndex, text: piece, tokens: TokenBudget.estimate(piece)))
                }
            }
            linesByUnit.append(indices)
        }
        self.lines = lines
        self.linesByUnit = linesByUnit
        instructions = try? AFMPrompt.instructions(.afmTranslate, values: [
            "source": AFMLanguage.englishName(for: sourceLocale),
            "target": AFMLanguage.englishName(for: targetLanguage.locale),
        ])
    }

    func execute(onNotice: (@Sendable (String) -> Void)?) async -> [SegmentTranslation] {
        onProgress?(.preparing)
        onProgress?(.translating(completed: 0, total: units.count))

        if instructions == nil {
            stopReason = L10n.text("Apple 智能提示词文件缺失")
        } else if !engine.supportsLanguage(sourceLocale) {
            stopReason = L10n.format("Apple 智能不支持%@，本次已改用 Apple 翻译。", L10n.languageName(for: sourceLocale.identifier))
        } else if !engine.supportsLanguage(targetLanguage.locale) {
            stopReason = L10n.format("Apple 智能不支持%@，本次已改用 Apple 翻译。", targetLanguage.title)
        }

        let ranges = TokenBudget.windows(costs: lines.map(\.tokens), target: engine.windows.targetSourceTokens)
        for range in ranges {
            if Task.isCancelled { break }
            let indices = Array(range)
            if stopReason != nil {
                await substitute(indices)
            } else {
                await process(indices, allowMissingRetry: true)
            }
            reportProgress()
        }

        let output = assemble()
        if let stopReason {
            onNotice?(stopReason)
        } else {
            let substituted = output.filter { $0.substituteProvider != nil }.count
            if substituted > 0 {
                onNotice?(L10n.format("%lld 个片段由 Apple 翻译兜底。", substituted))
            }
        }
        return output
    }

    // MARK: Windows

    private func process(_ indices: [Int], allowMissingRetry: Bool) async {
        guard !indices.isEmpty, !Task.isCancelled else { return }
        if stopReason != nil {
            await substitute(indices)
            return
        }
        do {
            let names = newNames(for: indices)
            let parsed = try await AFMRetry.run { try await self.generate(indices, names: names) }
            if parsed.lines.isEmpty, AFMRefusalDetector.isRefusal(parsed.preamble, source: indices.map { lines[$0].text }.joined(separator: " ")) {
                throw AFMFailure.refusal
            }
            var missing: [Int] = []
            for (offset, lineIndex) in indices.enumerated() {
                let number = offset + 1
                guard !parsed.duplicates.contains(number),
                      let value = parsed.lines[number]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      !AFMRefusalDetector.isRefusal(value, source: lines[lineIndex].text) else {
                    missing.append(lineIndex)
                    continue
                }
                results[lineIndex] = .translated(value)
            }
            let windowText = indices.map { lines[$0].text }.joined(separator: "\n")
            // More answers than names means the numbering drifted; trust none of them.
            let named = parsed.nameTranslations.count > names.count ? [] : parsed.nameTranslations.compactMap { number, value -> AFMTerm? in
                guard names.indices.contains(number - 1) else { return nil }
                let target = TranslationMemory.strippingEcho(value, source: names[number - 1])
                guard !target.isEmpty else { return nil }
                return AFMTerm(source: names[number - 1], target: target)
            }
            memory.merge(named + parsed.terms, windowText: windowText, windowIndex: windowCounter)
            memory.setStyleIfNeeded(parsed.style)
            windowCounter += 1
            emitPartials(for: indices, snapshot: nil, numbers: [:])
            if !missing.isEmpty {
                if allowMissingRetry, missing.count < indices.count || indices.count > 1 {
                    await process(missing, allowMissingRetry: false)
                } else {
                    await substitute(missing)
                }
            }
        } catch {
            guard let failure = AFMFailure.classify(error) else { return }
            switch failure {
            case .contextExceeded, .guardrail, .refusal:
                if indices.count > 1 {
                    let middle = indices.count / 2
                    await process(Array(indices[..<middle]), allowMissingRetry: allowMissingRetry)
                    await process(Array(indices[middle...]), allowMissingRetry: allowMissingRetry)
                } else {
                    await substitute(indices)
                }
            case .unsupportedLanguage:
                stopReason = L10n.text("Apple 智能不支持当前语言，本次已改用 Apple 翻译。")
                await substitute(indices)
            case .unavailable(let reason):
                AppleIntelligenceSupport.markBlocked(reason: reason)
                stopReason = L10n.format("Apple 智能暂不可用（%@），其余内容已改用 Apple 翻译。", reason)
                await substitute(indices)
            case .rateLimited, .busy, .timeout:
                await substitute(indices)
            }
        }
    }

    /// Names in the window that the glossary does not cover yet.
    func newNames(for indices: [Int]) -> [String] {
        let text = indices.map { lines[$0].text }.joined(separator: "\n")
        return Array(engine.extractNames(text).filter { memory.entries[$0.lowercased()] == nil }.prefix(8))
    }

    private func generate(_ indices: [Int], names: [String]) async throws -> AFMNumberedOutput {
        guard let instructions else { throw AFMFailure.unavailable(L10n.text("Apple 智能提示词文件缺失")) }
        let prompt = makePrompt(indices, names: names)
        let sourceTokens = indices.reduce(0) { $0 + lines[$1].tokens }
        let promptTokens = TokenBudget.estimate(instructions) + TokenBudget.estimate(prompt)
        let available = engine.windows.contextSize - promptTokens - 64
        guard available > 64 else { throw AFMFailure.contextExceeded }
        let maximum = min(available, max(256, sourceTokens * 2 + indices.count * 8 + 200))
        let numbers = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.offset + 1, $0.element) })
        let response = try await engine.generator.generate(
            instructions: instructions,
            prompt: prompt,
            options: .greedy(maximumResponseTokens: maximum),
            onSnapshot: { [self] snapshot in
                let parsed = AFMNumberedLineParser.parse(snapshot, isFinal: false)
                emitPartials(for: indices, snapshot: parsed, numbers: numbers)
            }
        )
        return AFMNumberedLineParser.parse(response, isFinal: true)
    }

    func makePrompt(_ indices: [Int], names: [String] = []) -> String {
        let windowText = indices.map { lines[$0].text }.joined(separator: "\n")
        var sections: [String] = []
        let glossary = memory.relevant(to: windowText, tokenLimit: engine.windows.memoryTokens)
        if !glossary.isEmpty {
            sections.append("GLOSSARY:\n" + glossary.map { "\($0.source) => \($0.target)" }.joined(separator: "\n"))
        }
        if let style = memory.style {
            sections.append("STYLE: \(style)")
        }
        if let first = indices.first {
            let previous = (max(0, first - 2)..<first).compactMap { index -> String? in
                guard let translated = results[index]?.text else { return nil }
                return "source: \(lines[index].text)\ntranslation: \(translated)"
            }
            if !previous.isEmpty {
                sections.append("CONTEXT (reference only, do not output):\n" + previous.joined(separator: "\n"))
            }
        }
        let numbered = indices.enumerated().map { "[\($0.offset + 1)] \(lines[$0.element].text)" }
        sections.append("LINES:\n" + numbered.joined(separator: "\n"))
        if !names.isEmpty {
            sections.append("NAMES:\n" + names.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "\n"))
        }
        if memory.style == nil {
            sections.append("Finally add STYLE: a few words on tone and form of address.")
        }
        return sections.joined(separator: "\n\n")
    }

    private func substitute(_ indices: [Int]) async {
        let pending = indices.filter { results[$0] == nil || results[$0]?.text == nil }
        guard !pending.isEmpty, !Task.isCancelled else { return }
        do {
            let values = try await engine.substitute(pending.map { lines[$0].text }, sourceLocale, targetLanguage)
            guard values.count == pending.count else { throw AppleTranslationError.invalidResponse }
            for (offset, index) in pending.enumerated() {
                let value = values[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                results[index] = value.isEmpty ? .failed(L10n.text("翻译服务返回了空译文。")) : .substituted(value)
            }
        } catch is CancellationError {
            return
        } catch {
            for index in pending { results[index] = .failed(error.localizedDescription) }
        }
        emitPartials(for: pending, snapshot: nil, numbers: [:])
    }

    // MARK: Results

    private var joiner: String {
        let code = targetLanguage.locale.language.languageCode?.identifier
        return code == "zh" || code == "ja" ? "" : " "
    }

    /// Streams the units touched by a window: settled lines plus the line still being generated.
    private func emitPartials(for indices: [Int], snapshot: AFMNumberedOutput?, numbers: [Int: Int]) {
        guard let onPartialResult else { return }
        var streaming: [Int: String] = [:]
        if let snapshot {
            for (number, value) in snapshot.lines {
                guard let lineIndex = numbers[number], !snapshot.duplicates.contains(number) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { streaming[lineIndex] = trimmed }
            }
        }
        let touchedUnits = Set(indices.map { lines[$0].unitIndex }).sorted()
        for unitIndex in touchedUnits {
            let pieces = linesByUnit[unitIndex].compactMap { results[$0]?.text ?? streaming[$0] }
            guard !pieces.isEmpty else { continue }
            let unit = units[unitIndex]
            let substituted = linesByUnit[unitIndex].contains {
                if case .substituted = results[$0] { return true }
                return false
            }
            onPartialResult(SegmentTranslation(
                id: unit.id,
                sourceSegmentID: unit.sourceSegmentID,
                ordinal: unit.ordinal,
                startTime: unit.startTime,
                endTime: unit.endTime,
                sourceText: unit.sourceText,
                translatedText: pieces.joined(separator: joiner),
                state: .translated,
                errorMessage: nil,
                substituteProvider: substituted ? .apple : nil
            ))
        }
    }

    private func reportProgress() {
        let completed = linesByUnit.filter { $0.allSatisfy { results[$0] != nil } }.count
        onProgress?(.translating(completed: completed, total: units.count))
    }

    private func assemble() -> [SegmentTranslation] {
        units.enumerated().map { unitIndex, unit in
            let indices = linesByUnit[unitIndex]
            if indices.isEmpty {
                return SegmentTranslation(
                    id: unit.id, sourceSegmentID: unit.sourceSegmentID, ordinal: unit.ordinal,
                    startTime: unit.startTime, endTime: unit.endTime, sourceText: unit.sourceText,
                    translatedText: "", state: .translated, errorMessage: nil
                )
            }
            var pieces: [String] = []
            var substituted = false
            var failure: String?
            for index in indices {
                switch results[index] {
                case .translated(let value): pieces.append(value)
                case .substituted(let value): pieces.append(value); substituted = true
                case .failed(let message): failure = failure ?? message
                case nil: failure = failure ?? L10n.text("翻译已取消")
                }
            }
            if let failure {
                return SegmentTranslation(
                    id: unit.id, sourceSegmentID: unit.sourceSegmentID, ordinal: unit.ordinal,
                    startTime: unit.startTime, endTime: unit.endTime, sourceText: unit.sourceText,
                    translatedText: unit.sourceText, state: .fallback, errorMessage: failure
                )
            }
            return SegmentTranslation(
                id: unit.id, sourceSegmentID: unit.sourceSegmentID, ordinal: unit.ordinal,
                startTime: unit.startTime, endTime: unit.endTime, sourceText: unit.sourceText,
                translatedText: pieces.joined(separator: joiner), state: .translated, errorMessage: nil,
                substituteProvider: substituted ? .apple : nil
            )
        }
    }
}

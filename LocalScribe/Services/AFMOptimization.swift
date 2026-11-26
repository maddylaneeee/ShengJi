import Foundation
import NaturalLanguage

/// Proofreading and rolling summaries with the on-device Apple Foundation Model.
struct AFMOptimizer: Sendable {
    let generator: any AppleIntelligenceGenerating
    let windows: TokenBudget.Windows

    static var live: AFMOptimizer {
        AFMOptimizer(generator: SystemAppleIntelligenceGenerator(), windows: .current)
    }

    func optimize(
        segments input: [TranscriptSegment],
        fallbackText: String,
        kind: GemmaOptimizationKind,
        prompt: String,
        progress: @escaping @Sendable (Int, Int) -> Void,
        preview: @escaping @Sendable (String) -> Void
    ) async throws -> AIOptimizationResult {
        let segments = input.isEmpty
            ? TranscriptSegment.sentenceSegments(from: fallbackText, duration: 0)
            : input.sorted { $0.startTime < $1.startTime }
        guard !segments.isEmpty else {
            return AIOptimizationResult(text: "", segments: [], summary: nil, failures: [])
        }
        switch kind {
        case .proofread:
            let run = AFMProofreadRun(optimizer: self, segments: segments, prompt: prompt, preview: preview)
            return try await run.execute(progress: progress)
        case .summarize:
            if AIOptimizationService.isUnsafeSummaryGuidance(prompt) { throw GemmaOptimizationError.unsafeGuidance }
            let run = AFMSummaryRun(optimizer: self, segments: segments, prompt: prompt, preview: preview)
            let (summary, skipped) = try await run.execute(progress: progress)
            return AIOptimizationResult(
                text: segments.map(\.text).joined(separator: "\n"),
                segments: segments,
                summary: summary,
                failures: [],
                notice: skipped ? L10n.text("部分内容未能总结。") : nil
            )
        }
    }

    func responseLimit(instructions: String, prompt: String, desired: Int) throws -> Int {
        let used = TokenBudget.estimate(instructions) + TokenBudget.estimate(prompt)
        let available = windows.contextSize - used - 64
        guard available > 96 else { throw AFMFailure.contextExceeded }
        return min(available, max(128, desired))
    }
}

// MARK: - Proofreading

private final class AFMProofreadRun: @unchecked Sendable {
    let optimizer: AFMOptimizer
    let segments: [TranscriptSegment]
    let prompt: String
    let preview: @Sendable (String) -> Void
    var output: [TranscriptSegment]
    var failures: [GemmaSegmentFailure] = []

    init(optimizer: AFMOptimizer, segments: [TranscriptSegment], prompt: String, preview: @escaping @Sendable (String) -> Void) {
        self.optimizer = optimizer
        self.segments = segments
        self.prompt = prompt
        self.preview = preview
        output = segments
    }

    func execute(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> AIOptimizationResult {
        let instructions = try AFMPrompt.instructions(.afmProofread)
        let ranges = TokenBudget.windows(
            costs: segments.map { TokenBudget.estimate($0.text) },
            target: optimizer.windows.targetSourceTokens
        )
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            try await process(Array(range), instructions: instructions)
            progress(index + 1, ranges.count)
            preview(output.map(\.text).joined(separator: "\n"))
        }
        return AIOptimizationResult(
            text: output.map(\.text).joined(separator: "\n"),
            segments: output,
            summary: nil,
            failures: failures
        )
    }

    private func process(_ indices: [Int], instructions: String) async throws {
        guard let first = indices.first, let last = indices.last else { return }
        let editable = indices.map { segments[$0] }
        let before = output[max(0, first - 2)..<first].map(\.text)
        let after = segments[(last + 1)..<min(segments.count, last + 3)].map(\.text)
        var sections: [String] = []
        if let preferences = AFMPrompt.userPreferences(prompt) { sections.append(preferences) }
        if !before.isEmpty {
            sections.append("CONTEXT BEFORE (reference only):\n" + before.map(AFMPrompt.flattened).joined(separator: "\n"))
        }
        sections.append("LINES:\n" + editable.enumerated().map { "[\($0.offset + 1)] \(AFMPrompt.flattened($0.element.text))" }.joined(separator: "\n"))
        if !after.isEmpty {
            sections.append("CONTEXT AFTER (reference only):\n" + after.map(AFMPrompt.flattened).joined(separator: "\n"))
        }
        let requestPrompt = sections.joined(separator: "\n\n")
        let sourceTokens = editable.reduce(0) { $0 + TokenBudget.estimate($1.text) }
        let baseline = output
        let preview = self.preview

        do {
            let limit = try optimizer.responseLimit(
                instructions: instructions,
                prompt: requestPrompt,
                desired: sourceTokens * 3 / 2 + editable.count * 8 + 64
            )
            let response = try await AFMRetry.run {
                try await self.optimizer.generator.generate(
                    instructions: instructions,
                    prompt: requestPrompt,
                    options: .greedy(maximumResponseTokens: limit),
                    onSnapshot: { snapshot in
                        let parsed = AFMNumberedLineParser.parse(snapshot, isFinal: false)
                        let proposed = AIOptimizationService.applyingPreviewCorrections(
                            Self.corrections(from: parsed, editable: editable),
                            editable: editable,
                            baseline: baseline
                        )
                        preview(proposed.map(\.text).joined(separator: "\n"))
                    }
                )
            }
            let parsed = AFMNumberedLineParser.parse(response, isFinal: true)
            if parsed.lines.isEmpty, AFMRefusalDetector.isRefusal(parsed.preamble, source: editable.map(\.text).joined(separator: " ")) {
                throw AFMFailure.refusal
            }
            let validated = AIOptimizationService.validate(Self.corrections(from: parsed, editable: editable), originals: editable)
            for segment in editable {
                if let corrected = validated.values[segment.id],
                   let index = output.firstIndex(where: { $0.id == segment.id }) {
                    output[index] = TranscriptSegment(id: segment.id, startTime: segment.startTime, endTime: segment.endTime, text: corrected)
                } else {
                    failures.append(GemmaSegmentFailure(
                        id: segment.id,
                        message: validated.errors[segment.id] ?? L10n.text("该片段未通过结果校验")
                    ))
                }
            }
        } catch {
            guard let failure = AFMFailure.classify(error) else { throw CancellationError() }
            switch failure {
            case .contextExceeded, .guardrail, .refusal:
                if indices.count > 1 {
                    let middle = indices.count / 2
                    try await process(Array(indices[..<middle]), instructions: instructions)
                    try await process(Array(indices[middle...]), instructions: instructions)
                } else {
                    failures.append(GemmaSegmentFailure(id: editable[0].id, message: failure.localizedDescription))
                }
            case .unavailable(let reason):
                AppleIntelligenceSupport.markBlocked(reason: reason)
                throw failure
            case .unsupportedLanguage:
                throw failure
            case .rateLimited, .busy, .timeout:
                failures.append(contentsOf: editable.map { GemmaSegmentFailure(id: $0.id, message: failure.localizedDescription) })
            }
        }
    }

    /// Maps numbered lines back to segment IDs, dropping refusals.
    static func corrections(from parsed: AFMNumberedOutput, editable: [TranscriptSegment]) -> [GemmaCorrection] {
        editable.enumerated().compactMap { offset, segment in
            let number = offset + 1
            guard !parsed.duplicates.contains(number),
                  let value = parsed.lines[number]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !AFMRefusalDetector.isRefusal(value, source: segment.text) else { return nil }
            return GemmaCorrection(id: segment.id.uuidString, text: value)
        }
    }
}

// MARK: - Rolling summary

final class AFMSummaryRun: @unchecked Sendable {
    let optimizer: AFMOptimizer
    let segments: [TranscriptSegment]
    let prompt: String
    let preview: @Sendable (String) -> Void
    let language: String
    var notes = ""
    var skipped = false

    init(optimizer: AFMOptimizer, segments: [TranscriptSegment], prompt: String, preview: @escaping @Sendable (String) -> Void) {
        self.optimizer = optimizer
        self.segments = AIOptimizationService.summaryInputSegments(from: segments)
        self.prompt = prompt
        self.preview = preview
        language = AFMLanguage.dominantLanguageName(of: segments.map(\.text).joined(separator: "\n"))
    }

    var source: String {
        segments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func execute(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (String, Bool) {
        let source = self.source
        guard !source.isEmpty else { throw GemmaOptimizationError.invalidResponse }
        let target = AIOptimizationService.summaryCharacterTarget(sourceLength: source.count)
        let ranges = TokenBudget.windows(
            costs: segments.map { TokenBudget.estimate($0.text) },
            target: optimizer.windows.summarySourceTokens
        )

        if ranges.count <= 1 {
            let summary = try await single(source: source, target: target)
            progress(1, 1)
            return (summary, false)
        }

        let total = ranges.count + 1
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let text = range.map { AFMPrompt.flattened(segments[$0].text) }.joined(separator: "\n")
            try await step(text)
            progress(index + 1, total)
        }
        guard !notes.isEmpty else { throw GemmaOptimizationError.invalidResponse }
        var summary: String
        do {
            summary = try await polish(source: source, target: target)
        } catch GemmaOptimizationError.invalidResponse {
            // The rolling notes are already grounded; use them when the polish pass misbehaves.
            guard let fallback = Self.validatedSummary(notes, source: source, target: target) else {
                throw GemmaOptimizationError.invalidResponse
            }
            preview(fallback)
            summary = fallback
        }
        progress(total, total)
        return (summary, skipped)
    }

    private func single(source: String, target: Int) async throws -> String {
        let instructions = try AFMPrompt.instructions(.afmSummarySingle, values: ["language": language, "length": String(target)])
        var sections: [String] = []
        if let preferences = AFMPrompt.userPreferences(prompt) { sections.append(preferences) }
        sections.append("TRANSCRIPT:\n" + source)
        return try await finalize(instructions: instructions, prompt: sections.joined(separator: "\n\n"), source: source, target: target)
    }

    /// One rolling step: sees the summary written so far plus the next part.
    private func step(_ text: String, depth: Int = 0) async throws {
        if TokenBudget.estimate(notes) > optimizer.windows.summaryNotesTokens {
            try await compress()
        }
        let instructions = try AFMPrompt.instructions(.afmSummaryStep, values: ["language": language])
        var sections: [String] = []
        if let preferences = AFMPrompt.userPreferences(prompt) { sections.append(preferences) }
        sections.append("SUMMARY SO FAR:\n" + (notes.isEmpty ? "(empty)" : notes))
        sections.append("NEXT PART:\n" + text)
        let requestPrompt = sections.joined(separator: "\n\n")
        let existing = notes
        let preview = self.preview
        do {
            let limit = try optimizer.responseLimit(
                instructions: instructions,
                prompt: requestPrompt,
                desired: max(200, TokenBudget.estimate(text) / 3)
            )
            let response = try await AFMRetry.run {
                try await self.optimizer.generator.generate(
                    instructions: instructions,
                    prompt: requestPrompt,
                    options: AFMGenerationOptions(temperature: 0.2, maximumResponseTokens: limit),
                    onSnapshot: { snapshot in
                        let addition = Self.cleanedAddition(snapshot, existing: existing)
                        preview(addition.isEmpty ? existing : [existing, addition].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                )
            }
            let addition = Self.groundedAddition(Self.cleanedAddition(response, existing: existing), source: text + "\n" + existing)
            if !addition.isEmpty {
                notes = notes.isEmpty ? addition : notes + "\n" + addition
            }
            preview(notes)
        } catch {
            guard let failure = AFMFailure.classify(error) else { throw CancellationError() }
            switch failure {
            case .contextExceeded, .guardrail, .refusal:
                let lines = text.components(separatedBy: "\n")
                if depth < 3, lines.count > 1 {
                    let middle = lines.count / 2
                    try await step(lines[..<middle].joined(separator: "\n"), depth: depth + 1)
                    try await step(lines[middle...].joined(separator: "\n"), depth: depth + 1)
                } else {
                    skipped = true
                }
            case .unavailable(let reason):
                AppleIntelligenceSupport.markBlocked(reason: reason)
                throw failure
            case .unsupportedLanguage:
                throw failure
            case .rateLimited, .busy, .timeout:
                skipped = true
            }
        }
    }

    private func compress() async throws {
        let target = max(200, notes.count / 2)
        let instructions = try AFMPrompt.instructions(.afmSummaryFinal, values: ["language": language, "length": String(target)])
        let requestPrompt = "NOTES:\n" + notes
        let limit = try optimizer.responseLimit(instructions: instructions, prompt: requestPrompt, desired: TokenBudget.estimate(notes))
        let response = try await AFMRetry.run {
            try await self.optimizer.generator.generate(
                instructions: instructions,
                prompt: requestPrompt,
                options: AFMGenerationOptions(temperature: 0.3, maximumResponseTokens: limit),
                onSnapshot: { _ in }
            )
        }
        let compressed = AIOptimizationService.cleanedSummaryText(response)
        if !compressed.isEmpty, compressed.count < notes.count,
           AIOptimizationService.artifactsAreGrounded(compressed, in: notes) {
            notes = compressed
        }
    }

    private func polish(source: String, target: Int) async throws -> String {
        let instructions = try AFMPrompt.instructions(.afmSummaryFinal, values: ["language": language, "length": String(target)])
        var sections: [String] = []
        if let preferences = AFMPrompt.userPreferences(prompt) { sections.append(preferences) }
        sections.append("NOTES:\n" + notes)
        return try await finalize(instructions: instructions, prompt: sections.joined(separator: "\n\n"), source: source, target: target)
    }

    /// Streams a final summary, validates it, and retries once.
    private func finalize(instructions: String, prompt: String, source: String, target: Int) async throws -> String {
        let preview = self.preview
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let requestPrompt = attempt == 0
                ? prompt
                : prompt + "\n\nWrite it once more: shorter, facts only, no speaker attribution."
            do {
                let limit = try optimizer.responseLimit(instructions: instructions, prompt: requestPrompt, desired: max(256, target * 2))
                let response = try await AFMRetry.run {
                    try await self.optimizer.generator.generate(
                        instructions: instructions,
                        prompt: requestPrompt,
                        options: AFMGenerationOptions(temperature: 0.3, maximumResponseTokens: limit),
                        onSnapshot: { preview(AIOptimizationService.cleanedSummaryText($0)) }
                    )
                }
                if !AFMRefusalDetector.isRefusal(response, source: source),
                   let summary = Self.validatedSummary(response, source: source, target: target) {
                    preview(summary)
                    return summary
                }
            } catch {
                guard let failure = AFMFailure.classify(error) else { throw CancellationError() }
                if case .unavailable(let reason) = failure { AppleIntelligenceSupport.markBlocked(reason: reason) }
                if !failure.isContentRejection && !failure.isRetryable { throw failure }
            }
        }
        throw GemmaOptimizationError.invalidResponse
    }

    /// Final-summary validation that treats "8%" and "8 percent" alike.
    static func validatedSummary(_ response: String, source: String, target: Int) -> String? {
        let strip = { (text: String) in text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "％", with: "") }
        guard AIOptimizationService.validatedFinalSummary(strip(response), source: strip(source), targetCharacters: target) != nil else {
            return nil
        }
        let summary = AIOptimizationService.cleanedSummaryText(response)
        return summary.isEmpty ? nil : summary
    }

    static func cleanedAddition(_ value: String, existing: String = "") -> String {
        let text = AIOptimizationService.cleanedSummaryText(value)
        let marker = text.trimmingCharacters(in: CharacterSet(charactersIn: " .。!！\n")).uppercased()
        if marker == "NONE" || marker.hasPrefix("NONE") && marker.count <= 6 { return "" }
        var known = comparable(existing)
        return text.components(separatedBy: "\n")
            .compactMap { line -> String? in
                var line = line.trimmingCharacters(in: .whitespaces)
                if let header = line.range(of: #"^(?i)(summary so far|next part|new points|notes|transcript)\s*[:：]\s*"#, options: .regularExpression) {
                    line.removeSubrange(header)
                }
                guard !line.isEmpty, line.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ".。")) != "NONE",
                      line != "(empty)" else { return nil }
                let kept = sentences(in: line).filter { sentence in
                    let key = comparable(sentence)
                    guard key.isEmpty || !known.contains(key) else { return false }
                    known += key
                    return true
                }
                let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return joined.isEmpty ? nil : joined
            }
            .joined(separator: "\n")
    }

    /// Lower-cased letters and digits only, so echoed sentences match despite spacing or punctuation.
    private static func comparable(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Drops lines that introduce numbers, links or times absent from the source.
    static func groundedAddition(_ value: String, source: String) -> String {
        value.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" && AIOptimizationService.artifactsAreGrounded($0, in: source) }
            .filter { !AIOptimizationService.usesSpeakerAttributionFraming($0) }
            .joined(separator: "\n")
    }
}

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
            let limited = AFMOptimizer(generator: generator, windows: windows.limitedForSummary())
            let run = AFMSummaryRun(optimizer: limited, segments: segments, prompt: prompt, preview: preview)
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

/// One proofread decision for a source segment.
enum AFMProofreadEdit: Equatable, Sendable {
    /// The segment keeps its place with new text; `through` is the last
    /// segment joined into it (itself when nothing was joined).
    case text(String, through: UUID)
    /// The segment was joined into an earlier one.
    case joined
    /// The segment held only filler words.
    case removed
}

private final class AFMProofreadRun: @unchecked Sendable {
    let optimizer: AFMOptimizer
    let segments: [TranscriptSegment]
    let prompt: String
    let preview: @Sendable (String) -> Void
    var edits: [UUID: AFMProofreadEdit] = [:]
    var failures: [GemmaSegmentFailure] = []

    init(optimizer: AFMOptimizer, segments: [TranscriptSegment], prompt: String, preview: @escaping @Sendable (String) -> Void) {
        self.optimizer = optimizer
        self.segments = segments
        self.prompt = prompt
        self.preview = preview
    }

    func execute(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> AIOptimizationResult {
        let instructions = try AFMPrompt.instructions(.afmProofread)
        let ranges = AFMProofreadPlan.ranges(
            texts: segments.map(\.text),
            target: optimizer.windows.proofreadSourceTokens,
            maximumCount: TokenBudget.Windows.proofreadMaximumLines
        )
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            try await process(Array(range), instructions: instructions)
            progress(index + 1, ranges.count)
            preview(AFMProofreadPlan.text(of: AFMProofreadPlan.applying(edits, to: segments)))
        }
        let output = AFMProofreadPlan.applying(edits, to: segments)
        return AIOptimizationResult(
            text: AFMProofreadPlan.text(of: output),
            segments: output,
            summary: nil,
            failures: failures
        )
    }

    private func process(_ indices: [Int], instructions: String) async throws {
        guard let first = indices.first, let last = indices.last else { return }
        let editable = indices.map { segments[$0] }
        let done = AFMProofreadPlan.applying(edits, to: Array(segments[..<first]))
        let before = done.suffix(2).map(\.text)
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
        let baseline = edits
        let all = segments
        let preview = self.preview
        let gate = AFMSnapshotGate()

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
                        let lines = AFMProofreadPlan.outputLines(snapshot, closedOnly: true)
                        guard gate.advance(to: lines.count) else { return }
                        let plan = AFMProofreadPlan.make(from: lines, editable: editable)
                        var proposed = baseline
                        proposed.merge(plan.edits) { _, new in new }
                        preview(AFMProofreadPlan.text(of: AFMProofreadPlan.applying(proposed, to: all)))
                    }
                )
            }
            let lines = AFMProofreadPlan.outputLines(response, closedOnly: false)
            let source = editable.map(\.text).joined(separator: " ")
            if lines.isEmpty || (lines.count == 1 && AFMRefusalDetector.isRefusal(lines[0], source: source)) {
                throw AFMFailure.refusal
            }
            let plan = AFMProofreadPlan.make(from: lines, editable: editable)
            // When little of the answer can be traced back to the source, the
            // model rewrote or drifted; a smaller window usually fixes it.
            let substantive = editable.filter { !AFMProofreadPlan.isFillerOnly($0.text) }.count
            if substantive >= 8, plan.matchedLines * 3 < substantive {
                throw AFMFailure.refusal
            }
            edits.merge(plan.edits) { _, new in new }
            failures.append(contentsOf: plan.failures)
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
}

/// Lets a streaming preview recompute only when a new output line closes.
private final class AFMSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = -1
    func advance(to value: Int) -> Bool {
        lock.withLock {
            guard value != count else { return false }
            count = value
            return true
        }
    }
}

/// Maps free-form proofread output back onto the source segments.
///
/// The on-device model naturally rewrites fragments as whole sentences and
/// renumbers them, so its line numbers cannot be trusted. Instead every
/// output line is aligned, in order, to a run of consecutive source lines
/// whose words it actually contains. Output that cannot be traced back to
/// its source is dropped and those segments keep their original text, so
/// the diff preview always matches what is applied.
enum AFMProofreadPlan {
    /// Source lines one output sentence may absorb.
    static let maximumJoinedLines = 6
    static let maximumJoinedCharacters = 400
    /// Output lines one long source line may be split into.
    static let maximumSplitLines = 3
    /// Share of output words that must come from the matched source.
    static let minimumPrecision = 0.75
    /// Share of the source's non-filler words the output must keep.
    static let minimumRecall = 0.6

    struct Result {
        var edits: [UUID: AFMProofreadEdit] = [:]
        var failures: [GemmaSegmentFailure] = []
        /// Source lines covered by an accepted edit.
        var matchedLines = 0
    }

    private enum Step {
        case skipSource
        case skipOutput
        case match(sourceEnd: Int, outputEnd: Int, shared: Int)
    }

    static func make(from outputs: [String], editable: [TranscriptSegment]) -> Result {
        let n = editable.count
        let m = outputs.count
        let sourceTokens = editable.map { AFMLineAlignment.tokens($0.text) }
        let outputTokens = outputs.map(AFMLineAlignment.tokens)
        let sourceCounts = sourceTokens.map(counts)
        let outputCounts = outputTokens.map(counts)

        // Suffix DP: best number of shared words aligning sources[i...] with outputs[k...].
        var score = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        var steps = Array(repeating: Array(repeating: Step.skipSource, count: m + 1), count: n + 1)
        for i in stride(from: n, through: 0, by: -1) {
            for k in stride(from: m, through: 0, by: -1) where i < n || k < m {
                var best = -1
                var step = Step.skipSource
                if i < n, score[i + 1][k] > best { best = score[i + 1][k]; step = .skipSource }
                if k < m, score[i][k + 1] > best { best = score[i][k + 1]; step = .skipOutput }
                if i < n, k < m, !outputCounts[k].isEmpty {
                    var output: [String: Int] = [:]
                    for outputEnd in (k + 1)...min(m, k + maximumSplitLines) {
                        merge(&output, outputCounts[outputEnd - 1])
                        var source: [String: Int] = [:]
                        var characters = 0
                        for sourceEnd in (i + 1)...min(n, i + maximumJoinedLines) {
                            merge(&source, sourceCounts[sourceEnd - 1])
                            characters += editable[sourceEnd - 1].text.count
                            if characters > maximumJoinedCharacters { break }
                            // One sentence may absorb several lines, or one line
                            // may become several sentences, but not both at once.
                            if outputEnd - k > 1, sourceEnd - i > 1 { break }
                            guard acceptedOverlap(output: output, source: source) != nil,
                                  let shared = acceptedOrder(
                                      output: Array(outputTokens[k..<outputEnd].joined()),
                                      source: Array(sourceTokens[i..<sourceEnd].joined())
                                  ) else { continue }
                            let total = shared + score[sourceEnd][outputEnd]
                            if total > best { best = total; step = .match(sourceEnd: sourceEnd, outputEnd: outputEnd, shared: shared) }
                        }
                    }
                }
                score[i][k] = max(best, 0)
                steps[i][k] = step
            }
        }

        var result = Result()
        var matched = Set<Int>()
        var rejectedAt: [Int] = []
        var i = 0
        var k = 0
        while i < n || k < m {
            switch steps[i][k] {
            case .skipSource:
                i += 1
            case .skipOutput:
                if !outputCounts[k].isEmpty { rejectedAt.append(i) }
                k += 1
            case .match(let sourceEnd, let outputEnd, _):
                let group = Array(editable[i..<sourceEnd])
                let head = group[0]
                let text = joined(Array(outputs[k..<outputEnd]))
                let source = joined(group.map(\.text))
                let combined = TranscriptSegment(id: head.id, startTime: head.startTime, endTime: group.last!.endTime, text: source)
                let validated = AFMRefusalDetector.isRefusal(text, source: source)
                    ? nil
                    : AIOptimizationService.validate([GemmaCorrection(id: head.id.uuidString, text: text)], originals: [combined])
                if let value = validated?.values[head.id] {
                    result.edits[head.id] = .text(value, through: group.last!.id)
                    for member in group.dropFirst() { result.edits[member.id] = .joined }
                    matched.formUnion(i..<sourceEnd)
                } else {
                    result.failures.append(GemmaSegmentFailure(
                        id: head.id,
                        message: validated?.errors[head.id] ?? L10n.text("该片段未通过结果校验")
                    ))
                }
                i = sourceEnd
                k = outputEnd
            }
        }
        result.matchedLines = matched.count

        // Output that matched nothing: flag the nearest untouched source line.
        var flagged = Set(result.failures.map(\.id))
        for position in rejectedAt {
            let candidates = [position, position - 1].filter { $0 >= 0 && $0 < n && !matched.contains($0) }
            guard let index = candidates.first(where: { !isFillerOnly(editable[$0].text) }),
                  flagged.insert(editable[index].id).inserted else { continue }
            result.failures.append(GemmaSegmentFailure(id: editable[index].id, message: L10n.text("该片段的修改与原文对不上，已保留原文")))
        }
        // Filler-only lines the cleaned text left out are dropped.
        if !matched.isEmpty {
            for (index, segment) in editable.enumerated() where !matched.contains(index) && isFillerOnly(segment.text) {
                result.edits[segment.id] = .removed
            }
        }
        return result
    }

    /// Words kept in order when `output` is a faithful cleanup of `source`:
    /// almost every output word comes from the source, in the same order,
    /// and most of the source's content words survive.
    static func acceptedOrder(output: [String], source: [String]) -> Int? {
        let shared = commonSubsequence(output, source)
        guard shared > 0, Double(shared) / Double(output.count) >= minimumPrecision else { return nil }
        let content = source.filter { !fillers.contains($0) }
        if !content.isEmpty {
            let kept = commonSubsequence(output.filter { !fillers.contains($0) }, content)
            guard Double(kept) / Double(content.count) >= minimumRecall else { return nil }
        }
        return shared
    }

    static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: b.count + 1)
        var current = previous
        for x in a {
            for (index, y) in b.enumerated() {
                current[index + 1] = x == y ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Cheap bag-of-words filter run before the order check.
    static func acceptedOverlap(output: [String: Int], source: [String: Int]) -> Int? {
        let outputTotal = output.values.reduce(0, +)
        guard outputTotal > 0 else { return nil }
        var shared = 0
        var sharedContent = 0
        var sourceContent = 0
        for (token, count) in source {
            let common = min(count, output[token] ?? 0)
            shared += common
            if !fillers.contains(token) {
                sourceContent += count
                sharedContent += common
            }
        }
        guard shared > 0, Double(shared) / Double(outputTotal) >= minimumPrecision else { return nil }
        if sourceContent > 0, Double(sharedContent) / Double(sourceContent) < minimumRecall { return nil }
        return shared
    }

    /// Cleaned lines from a (possibly partial) response, without the
    /// numbering, bullets and stray `[n]` tags the model likes to add.
    static func outputLines(_ response: String, closedOnly: Bool) -> [String] {
        var lines = response.components(separatedBy: .newlines)
        if closedOnly { lines.removeLast() }
        return lines.compactMap { line in
            var value = line.trimmingCharacters(in: .whitespaces)
            value = value.replacingOccurrences(of: #"^(?:\[\s*\d{0,3}\s*\]|\d{1,3}[.)、:：](?=\s)|[-*•](?=\s))\s*"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(?:\s*\[\s*(?:n|\d{1,3}|\+|-)?\s*\])+\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            value = value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !isHeader(value) else { return nil }
            return value
        }
    }

    private static func isHeader(_ value: String) -> Bool {
        value.range(
            of: #"^(?:LINES|TRANSCRIPT|OUTPUT|CLEANED(?: TEXT| TRANSCRIPT)?|CONTEXT(?: BEFORE| AFTER)?(?: \(REFERENCE ONLY\))?)\s*[:：]?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Windows of at most `maximumCount` lines and about `target` tokens,
    /// cut after a sentence end when one is near so the model is not asked
    /// to clean half a sentence.
    static func ranges(texts: [String], target: Int, maximumCount: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < texts.count {
            var end = start
            var total = 0
            while end < texts.count, end - start < maximumCount {
                let cost = TokenBudget.estimate(texts[end])
                if end > start, total + cost > target { break }
                total += cost
                end += 1
            }
            if end < texts.count {
                let floor = start + max(1, (end - start) / 2)
                if let cut = (floor...end).reversed().first(where: { endsSentence(texts[$0 - 1]) }) {
                    end = cut
                }
            }
            result.append(start..<end)
            start = end
        }
        return result
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’」』)）]")))
        guard let last = trimmed.last else { return false }
        return ".?!。？！…".contains(last)
    }

    static func applying(_ edits: [UUID: AFMProofreadEdit], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let endTimes = Dictionary(segments.map { ($0.id, $0.endTime) }, uniquingKeysWith: { first, _ in first })
        return segments.compactMap { segment in
            switch edits[segment.id] {
            case nil:
                return segment
            case .joined, .removed:
                return nil
            case .text(let text, let through):
                let end = max(segment.endTime, endTimes[through] ?? segment.endTime)
                return TranscriptSegment(id: segment.id, startTime: segment.startTime, endTime: end, text: text)
            }
        }
    }

    static func text(of segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: "\n")
    }

    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhm", "erm", "er", "ah", "oh", "hmm", "mm", "mhm", "like", "so", "okay", "ok",
        "yeah", "well", "right", "you", "know", "i", "mean", "and", "but",
        "嗯", "啊", "呃", "额", "哦", "唔", "噢", "哎", "诶", "欸", "那", "个", "就", "是", "然", "后",
        "えー", "えっと", "あの", "あのー", "ま", "まあ", "その",
    ]

    static func isFillerOnly(_ text: String) -> Bool {
        let tokens = AFMLineAlignment.tokens(text)
        return !tokens.isEmpty && tokens.allSatisfy(fillers.contains)
    }

    static func joined(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce("") { result, text in
                guard let last = result.unicodeScalars.last, let first = text.unicodeScalars.first else { return result + text }
                let tight = TokenBudget.isDense(last) && TokenBudget.isDense(first)
                return result + (tight ? "" : " ") + text
            }
    }

    private static func counts(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func merge(_ target: inout [String: Int], _ other: [String: Int]) {
        target.merge(other, uniquingKeysWith: +)
    }
}

enum AFMLineAlignment {
    /// Word tokens, lower-cased; one token per CJK character.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { result.append(word) }
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if TokenBudget.isDense(scalar) {
                flush()
                if CharacterSet.alphanumerics.contains(scalar) { result.append(String(scalar)) }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
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

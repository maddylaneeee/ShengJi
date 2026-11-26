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
    /// Text after the recognition-error pass, by segment.
    var corrected: [UUID: String] = [:]

    init(optimizer: AFMOptimizer, segments: [TranscriptSegment], prompt: String, preview: @escaping @Sendable (String) -> Void) {
        self.optimizer = optimizer
        self.segments = segments
        self.prompt = prompt
        self.preview = preview
    }

    func execute(progress: @escaping @Sendable (Int, Int) -> Void) async throws -> AIOptimizationResult {
        let instructions = try AFMPrompt.instructions(.afmProofread)
        let correction = try? AFMPrompt.instructions(.afmCorrect)
        let ranges = AFMProofreadPlan.ranges(
            texts: segments.map(\.text),
            target: optimizer.windows.proofreadSourceTokens,
            maximumCount: TokenBudget.Windows.proofreadMaximumLines
        )
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            if let correction {
                try await correctRecognitionErrors(Array(range), instructions: correction)
                preview(AFMProofreadPlan.text(of: AFMProofreadPlan.applying(edits, to: segments)))
            }
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

    /// First pass, one task per request as Apple recommends: replace
    /// misheard words line by line. Only in-place replacements are kept;
    /// any other change leaves the line as it was. Failures are silent
    /// because the cleanup pass still runs.
    private func correctRecognitionErrors(_ indices: [Int], instructions: String) async throws {
        let lines = indices.map { segments[$0] }
        var sections: [String] = []
        if let preferences = AFMPrompt.userPreferences(prompt) { sections.append(preferences) }
        sections.append("LINES:\n" + lines.enumerated().map { "[\($0.offset + 1)] \(AFMPrompt.flattened($0.element.text))" }.joined(separator: "\n"))
        let requestPrompt = sections.joined(separator: "\n\n")
        let sourceTokens = lines.reduce(0) { $0 + TokenBudget.estimate($1.text) }
        let response: String
        do {
            let limit = try optimizer.responseLimit(instructions: instructions, prompt: requestPrompt, desired: sourceTokens * 3 / 2 + lines.count * 8 + 32)
            response = try await AFMRetry.run {
                try await self.optimizer.generator.generate(
                    instructions: instructions, prompt: requestPrompt,
                    options: .greedy(maximumResponseTokens: limit), onSnapshot: { _ in }
                )
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return
        }
        let parsed = AFMNumberedLineParser.parse(response, isFinal: true)
        for (offset, segment) in lines.enumerated() {
            guard !parsed.duplicates.contains(offset + 1),
                  let value = parsed.lines[offset + 1]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, AFMProofreadPlan.isRecognitionFix(value, of: segment.text),
                  // Only the swapped words move into the original line; its
                  // own spacing and punctuation stay for the cleanup pass.
                  case let swapped = AFMProofreadPlan.restoringSourceWords(segment.text, source: value),
                  swapped != segment.text,
                  let fixed = AIOptimizationService.validate([GemmaCorrection(id: segment.id.uuidString, text: swapped)], originals: [segment]).values[segment.id]
            else { continue }
            corrected[segment.id] = fixed
            edits[segment.id] = .text(fixed, through: segment.id)
        }
    }

    private func process(_ indices: [Int], instructions: String) async throws {
        guard let first = indices.first, let last = indices.last else { return }
        let editable = indices.map { index in
            let segment = segments[index]
            guard let text = corrected[segment.id] else { return segment }
            return TranscriptSegment(id: segment.id, startTime: segment.startTime, endTime: segment.endTime, text: text)
        }
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
    /// Output lines one aligned group may span.
    static let maximumSplitLines = 6
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
                            // A single long line may always be cleaned on its own.
                            if characters > maximumJoinedCharacters, sourceEnd - i > 1 { break }
                            // Several sentences may also cover several fragments when
                            // the model re-cuts sentence boundaries ("…, my name" /
                            // "is Dr. Varga" → "…" / "My name is Dr. Varga.").
                            // Ties keep the finer alignment found first.
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
                let source = joined(group.map(\.text))
                // Word fixes belong to the correction pass; cleanup keeps the
                // speaker's words and only adds punctuation, joins and cuts.
                let text = latinPunctuation(tighteningDenseSpaces(
                    restoringSourceWords(joined(Array(outputs[k..<outputEnd])), source: source), source: source))
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

    /// Puts back the source's words wherever `text` swapped a few of them
    /// in place ("你" → "您", "gonna" → "going to"), keeping everything else
    /// the cleanup did: punctuation, spacing, joins and dropped fillers.
    static func restoringSourceWords(_ text: String, source: String) -> String {
        let output = AFMLineAlignment.spans(text)
        let original = AFMLineAlignment.spans(source)
        guard !output.isEmpty, !original.isEmpty else { return text }
        let a = original.map(\.token)
        let b = output.map(\.token)
        let repeated = repeatedPositions(in: a)
        let n = a.count
        let m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var replacements: [(Range<String.Index>, Substring)] = []
        var deleted: [Int] = []
        var inserted: [Int] = []
        func closeGap() {
            defer { deleted = []; inserted = [] }
            let removable = removable(deleted, in: a, repeated: repeated)
            let content = deleted.filter { !removable.contains($0) }
            guard let first = content.first, let last = content.last, let from = inserted.first, let to = inserted.last,
                  content.count <= maximumReplacementTokens, inserted.count <= maximumReplacementTokens else { return }
            replacements.append((output[from].range.lowerBound..<output[to].range.upperBound,
                                 source[original[first].range.lowerBound..<original[last].range.upperBound]))
        }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                closeGap()
                i += 1
                j += 1
            } else if j >= m || (i < n && table[i + 1][j] >= table[i][j + 1]) {
                deleted.append(i)
                i += 1
            } else {
                inserted.append(j)
                j += 1
            }
        }
        closeGap()
        var result = text
        for (range, words) in replacements.reversed() { result.replaceSubrange(range, with: words) }
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
        guard unfaithfulEdits(output: output, source: source) <= content.count / 15 else { return nil }
        return shared
    }

    /// True when `fixed` only swaps a few misheard words of `source` in
    /// place: nothing dropped or added beyond fillers, at most a fifth of
    /// the words (minimum two) replaced, and every replacement sounds like
    /// what was recognised. The last check stops the model from "fixing"
    /// names and facts it does not know ("Kessler" → "Gateway").
    static func isRecognitionFix(_ fixed: String, of source: String) -> Bool {
        let output = AFMLineAlignment.tokens(fixed)
        let original = AFMLineAlignment.tokens(source)
        guard !output.isEmpty, unfaithfulEdits(output: output, source: original) == 0 else { return false }
        let replaced = original.count - commonSubsequence(output, original)
        guard replaced <= max(2, original.count / 5) else { return false }
        return replacements(output: output, source: original).allSatisfy { soundsAlike($0.0, $0.1) }
    }

    /// Gaps of an order-preserving alignment where source words were
    /// swapped for different output words, as (source, output) tokens.
    static func replacements(output: [String], source: [String]) -> [([String], [String])] {
        let n = source.count
        let m = output.count
        guard n > 0, m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = source[i] == output[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [([String], [String])] = []
        var deleted: [String] = []
        var inserted: [String] = []
        func closeGap() {
            if !deleted.isEmpty, !inserted.isEmpty { result.append((deleted, inserted)) }
            deleted = []
            inserted = []
        }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, source[i] == output[j] {
                closeGap()
                i += 1
                j += 1
            } else if j >= m || (i < n && table[i + 1][j] >= table[i][j + 1]) {
                deleted.append(source[i])
                i += 1
            } else {
                inserted.append(output[j])
                j += 1
            }
        }
        closeGap()
        return result
    }

    /// Whether two token runs sound alike: CJK compared by toneless pinyin
    /// (or kana romaji) with common recogniser confusions folded together,
    /// other text by spelling distance.
    static func soundsAlike(_ heard: [String], _ fixed: [String]) -> Bool {
        let dense = (heard + fixed).contains { $0.unicodeScalars.contains(where: TokenBudget.isDense) }
        func spoken(_ tokens: [String]) -> String {
            let latin = tokens.joined().applyingTransform(.toLatin, reverse: false) ?? tokens.joined()
            let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
                .filter { $0.isLetter || $0.isNumber }
            guard dense else { return plain }
            return plain.replacingOccurrences(of: "zh", with: "z").replacingOccurrences(of: "ch", with: "c")
                .replacingOccurrences(of: "sh", with: "s").replacingOccurrences(of: "ng", with: "n")
        }
        let a = Array(spoken(heard))
        let b = Array(spoken(fixed))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if dense { return a == b }
        var previous = Array(0...b.count)
        for x in a {
            var current = [previous[0] + 1]
            for (index, y) in b.enumerated() {
                current.append(min(previous[index] + (x == y ? 0 : 1), previous[index + 1] + 1, current[index] + 1))
            }
            previous = current
        }
        return previous[b.count] * 5 <= max(a.count, b.count) * 2
    }

    /// Longest replacement treated as a misrecognised word (in tokens; one
    /// token per CJK character).
    static let maximumReplacementTokens = 4

    /// Counts edits that change what was said. Walking an order-preserving
    /// alignment, every gap between matched words is judged:
    /// - deleted words are fine only when they are fillers or one copy of
    ///   an immediately repeated word or phrase ("the the", "we, we");
    /// - a small replacement of similar length is a recognition fix
    ///   ("公圆" → "公园", "their" → "there");
    /// - anything else (dropped content, added words, rewrites) counts.
    static func unfaithfulEdits(output: [String], source: [String]) -> Int {
        guard !output.isEmpty, !source.isEmpty else { return output.count + source.count }
        let repeated = repeatedPositions(in: source)
        let n = source.count
        let m = output.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = source[i] == output[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var edits = 0
        var deleted: [Int] = []
        var inserted = 0
        func closeGap() {
            let content = deleted.count - removableCount(deleted, in: source, repeated: repeated)
            if inserted == 0 {
                edits += content
            } else if content == 0 {
                edits += inserted
            } else if content <= maximumReplacementTokens, inserted <= maximumReplacementTokens {
                edits += abs(inserted - content)
            } else {
                edits += max(inserted, content)
            }
            deleted = []
            inserted = 0
        }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, source[i] == output[j] {
                closeGap()
                i += 1
                j += 1
            } else if j >= m || (i < n && table[i + 1][j] >= table[i][j + 1]) {
                deleted.append(i)
                i += 1
            } else {
                inserted += 1
                j += 1
            }
        }
        closeGap()
        return edits
    }

    /// Filler sounds and fixed filler phrases a cleanup may delete. Single
    /// function words ("you", "是", "就") are not in it: dropping them alone
    /// changes what was said.
    static let removableFillers: [[String]] = [
        "um", "umm", "uh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm",
        "嗯", "啊", "呃", "额", "哦", "唔", "噢", "哎", "诶", "欸", "えー", "えっと", "あのー",
    ].map { [$0] } + [
        ["那", "个"], ["这", "个"], ["就", "是"], ["然", "后"], ["you", "know"], ["i", "mean"],
        ["like"], ["so"], ["well"], ["okay"], ["ok"], ["oh"], ["yeah"], ["あの"], ["まあ"], ["その"],
        // A sentence re-cut may drop the joining "and".
        ["and"],
    ]

    /// Which of the consecutive `positions` deleted from `tokens` are filler
    /// sounds, filler phrases or one copy of a repetition.
    static func removable(_ positions: [Int], in tokens: [String], repeated: [Bool]) -> Set<Int> {
        var result = Set(positions.filter { repeated[$0] })
        var index = 0
        while index < positions.count {
            let rest = positions[index...].map { tokens[$0] }
            if let phrase = removableFillers.filter({ rest.starts(with: $0) }).max(by: { $0.count < $1.count }) {
                result.formUnion(positions[index..<(index + phrase.count)])
                index += phrase.count
            } else {
                index += 1
            }
        }
        return result
    }

    static func removableCount(_ positions: [Int], in tokens: [String], repeated: [Bool]) -> Int {
        removable(positions, in: tokens, repeated: repeated).count
    }

    /// Swaps full-width sentence marks for ASCII ones in text with no CJK
    /// characters ("…the project。" → "…the project.").
    static func latinPunctuation(_ text: String) -> String {
        guard !text.unicodeScalars.contains(where: { TokenBudget.isDense($0) && CharacterSet.alphanumerics.contains($0) }) else { return text }
        var result = text
        for (wide, ascii) in [("。", "."), ("，", ","), ("？", "?"), ("！", "!"), ("：", ":"), ("；", ";")] {
            result = result.replacingOccurrences(of: wide + " ", with: ascii + " ").replacingOccurrences(of: wide, with: ascii + " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Removes spaces the model put between two CJK characters when joining
    /// fragments ("今天我们 主要讨论" → "今天我们主要讨论"), unless the source
    /// had a space there.
    static func tighteningDenseSpaces(_ text: String, source: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let sourceScalars = Array(source.unicodeScalars)
        var kept = Set<String>()
        for (index, scalar) in sourceScalars.enumerated() where scalar.properties.isWhitespace {
            var start = index
            while start > 0, sourceScalars[start - 1].properties.isWhitespace { start -= 1 }
            var end = index
            while end + 1 < sourceScalars.count, sourceScalars[end + 1].properties.isWhitespace { end += 1 }
            if start > 0, end + 1 < sourceScalars.count {
                kept.insert(String(sourceScalars[start - 1]) + String(sourceScalars[end + 1]))
            }
        }
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace, let last = result.last, TokenBudget.isDense(last) {
                var end = index
                while end < scalars.count, scalars[end].properties.isWhitespace { end += 1 }
                if end < scalars.count, TokenBudget.isDense(scalars[end]), !kept.contains(String(last) + String(scalars[end])) {
                    index = end
                    continue
                }
            }
            result.append(scalar)
            index += 1
        }
        return String(result)
    }

    /// Positions inside an immediately repeated word or phrase of up to four
    /// tokens; either copy may be dropped as a stutter.
    static func repeatedPositions(in tokens: [String]) -> [Bool] {
        var result = [Bool](repeating: false, count: tokens.count)
        for size in 1...4 where tokens.count >= size * 2 {
            for start in 0...(tokens.count - size * 2)
            where tokens[start..<(start + size)] == tokens[(start + size)..<(start + size * 2)] {
                for index in start..<(start + size * 2) { result[index] = true }
            }
        }
        return result
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
        spans(text).map(\.token)
    }

    /// Tokens with their ranges in `text`.
    static func spans(_ text: String) -> [(token: String, range: Range<String.Index>)] {
        var result: [(token: String, range: Range<String.Index>)] = []
        let scalars = text.unicodeScalars
        var start: String.Index?
        func flush(at end: String.Index) {
            if let start { result.append((String(text.unicodeScalars[start..<end]).lowercased(), start..<end)) }
            start = nil
        }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if TokenBudget.isDense(scalar) {
                flush(at: index)
                if CharacterSet.alphanumerics.contains(scalar) { result.append((String(scalar).lowercased(), index..<next)) }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if start == nil { start = index }
            } else {
                flush(at: index)
            }
            index = next
        }
        flush(at: scalars.endIndex)
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

import Foundation

/// Conservative token estimates and window budgets for the on-device model.
///
/// Measured on AFM 3 Core: English ≈ 5.6 characters per token and Chinese
/// ≈ 1.56 characters per token. The estimate deliberately over-counts (CJK
/// one token per character, other scripts four characters per token, plus
/// 15 %) because exceeding the context fails mid-generation and discards the
/// partial output.
enum TokenBudget {
    static func estimate(_ text: String) -> Int {
        var dense = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isDense(scalar) { dense += 1 } else { other += 1 }
        }
        let raw = Double(dense) + Double(other) / 4.0
        return Int((raw * 1.15).rounded(.up))
    }

    static func isDense(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // Full-width forms
             0x3000...0x303F, // CJK punctuation
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Window sizes derived from the model's context size. On macOS 27
    /// (8,192 tokens) the translation and proofreading target is about 1,800
    /// source tokens with a hard limit near 3,000; on macOS 26 (4,096 tokens)
    /// both are halved.
    struct Windows: Equatable, Sendable {
        let contextSize: Int

        /// Upper bound for one translation or proofreading window's source text.
        var maximumSourceTokens: Int { Int(Double(contextSize) * 0.37) }
        /// Preferred size; smaller windows stream progress sooner.
        var targetSourceTokens: Int { Int(Double(maximumSourceTokens) * 0.6) }
        /// Source text per rolling-summary step. The summary output is short,
        /// so these windows can be larger than translation windows.
        var summarySourceTokens: Int { contextSize / 2 }
        /// When the running summary grows beyond this, it is compressed first.
        var summaryNotesTokens: Int { Int(Double(contextSize) * 0.15) }
        /// Glossary and style notes injected into one translation window.
        var memoryTokens: Int { max(120, contextSize / 32) }
        /// Proofreading must keep every output line on its own input line.
        /// The on-device model starts merging and shifting short transcript
        /// fragments in long windows, so proofreading uses small windows.
        var proofreadSourceTokens: Int { min(targetSourceTokens, 600) }
        static let proofreadMaximumLines = 24

        static var current: Windows { Windows(contextSize: AppleIntelligenceSupport.contextSize) }

        /// Total per-call budget for summaries. macOS 26 is limited to about
        /// 3,000 tokens and Macs with 9 GB of memory or less to about 4,000,
        /// which keeps the model's memory use and latency predictable.
        static func summaryContextCap(operatingSystemMajor: Int, physicalMemory: UInt64) -> Int? {
            if operatingSystemMajor <= 26 { return 3_000 }
            if physicalMemory <= 9 * 1_024 * 1_024 * 1_024 { return 4_000 }
            return nil
        }

        func limitedForSummary(
            operatingSystemMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
        ) -> Windows {
            guard let cap = Self.summaryContextCap(operatingSystemMajor: operatingSystemMajor, physicalMemory: physicalMemory) else {
                return self
            }
            return Windows(contextSize: min(contextSize, cap))
        }
    }

    /// Groups consecutive items into windows without splitting an item.
    static func windows(
        costs: [Int],
        target: Int,
        maximumCount: Int = .max
    ) -> [Range<Int>] {
        guard !costs.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        var total = 0
        for index in costs.indices {
            let cost = max(1, costs[index])
            if index > start, total + cost > target || index - start >= maximumCount {
                ranges.append(start..<index)
                start = index
                total = 0
            }
            total += cost
        }
        ranges.append(start..<costs.count)
        return ranges
    }

    /// Splits text that alone exceeds `limit` into sentence-sized pieces,
    /// falling back to hard character cuts for unpunctuated text.
    static func pieces(of text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard estimate(trimmed) > limit else { return [trimmed] }
        let sentences = TranscriptSegment.sentenceSegments(from: trimmed, duration: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var output: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { output.append(current) }
            current = ""
        }
        for sentence in sentences.isEmpty ? [trimmed] : sentences {
            if estimate(sentence) > limit {
                flush()
                output.append(contentsOf: hardSplit(sentence, limit: limit))
                continue
            }
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if estimate(joined) > limit {
                flush()
                current = sentence
            } else {
                current = joined
            }
        }
        flush()
        return output.isEmpty ? [trimmed] : output
    }

    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        let denseText = text.unicodeScalars.filter(isDense).count * 2 > text.unicodeScalars.count
        let characters = max(16, Int(Double(limit) / 1.15 * (denseText ? 1 : 4)))
        var output: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: characters, limitedBy: text.endIndex) ?? text.endIndex
            output.append(String(text[start..<end]))
            start = end
        }
        return output
    }
}

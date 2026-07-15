import Foundation

enum StreamingTextPacing {
    static func updatedAverage(current: TimeInterval, sample: TimeInterval) -> TimeInterval {
        let bounded = min(max(sample, 0.08), 3.0)
        return current * 0.7 + bounded * 0.3
    }

    static func charactersPerSecond(pendingCount: Int, averageInterval: TimeInterval) -> Double {
        guard pendingCount > 0 else { return 0 }
        let desiredDuration = min(max(averageInterval * 0.9, 0.28), 1.15)
        return min(max(Double(pendingCount) / desiredDuration, 18), 110)
    }
}

@MainActor
final class AdaptiveStreamingTextAnimator {
    private var targetCharacters: [Character] = []
    private var visibleCharacters: [Character] = []
    private var animationTask: Task<Void, Never>?
    private var lastSubmissionAt: ContinuousClock.Instant?
    private var averageSubmissionInterval: TimeInterval = 0.7
    private var characterCredit = 0.0
    private let onUpdate: (String) -> Void

    init(onUpdate: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
    }

    func reset(to text: String = "") {
        animationTask?.cancel()
        animationTask = nil
        targetCharacters = Array(text)
        visibleCharacters = targetCharacters
        lastSubmissionAt = nil
        averageSubmissionInterval = 0.7
        characterCredit = 0
        onUpdate(text)
    }

    func submit(_ text: String, animated: Bool) {
        let newTarget = Array(text)
        guard newTarget != targetCharacters else { return }

        let now = ContinuousClock.now
        if let lastSubmissionAt {
            let duration = lastSubmissionAt.duration(to: now)
            let sample = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            averageSubmissionInterval = StreamingTextPacing.updatedAverage(
                current: averageSubmissionInterval,
                sample: sample
            )
        }
        lastSubmissionAt = now
        targetCharacters = newTarget

        guard animated else {
            flush()
            return
        }

        let sharedCount = commonPrefixCount(visibleCharacters, targetCharacters)
        if sharedCount < visibleCharacters.count {
            visibleCharacters = Array(visibleCharacters.prefix(sharedCount))
            onUpdate(String(visibleCharacters))
        }
        startAnimationIfNeeded()
    }

    func flush() {
        animationTask?.cancel()
        animationTask = nil
        characterCredit = 0
        visibleCharacters = targetCharacters
        onUpdate(String(visibleCharacters))
    }

    func cancel() {
        animationTask?.cancel()
        animationTask = nil
    }

    private func startAnimationIfNeeded() {
        guard visibleCharacters.count < targetCharacters.count, animationTask == nil else { return }
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(24))
                guard !Task.isCancelled, let self else { return }
                if self.advance(frameDuration: 0.024) { return }
            }
        }
    }

    private func advance(frameDuration: TimeInterval) -> Bool {
        let pendingCount = targetCharacters.count - visibleCharacters.count
        guard pendingCount > 0 else {
            animationTask = nil
            characterCredit = 0
            return true
        }

        characterCredit += StreamingTextPacing.charactersPerSecond(
            pendingCount: pendingCount,
            averageInterval: averageSubmissionInterval
        ) * frameDuration
        let requestedCount = Int(characterCredit)
        guard requestedCount > 0 else { return false }

        let revealCount = min(requestedCount, pendingCount)
        characterCredit -= Double(revealCount)
        let start = visibleCharacters.count
        visibleCharacters.append(contentsOf: targetCharacters[start..<(start + revealCount)])
        onUpdate(String(visibleCharacters))

        if visibleCharacters.count == targetCharacters.count {
            animationTask = nil
            characterCredit = 0
            return true
        }
        return false
    }

    private func commonPrefixCount(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] { index += 1 }
        return index
    }
}

enum MicrophoneTranscriptFilter {
    static func sanitizedStreamingText(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let normalized = normalize(cleaned)
        guard !containsCreatorBoilerplate(normalized), !terminalPhrases.contains(normalized) else {
            return nil
        }
        return cleaned
    }

    static func removingTerminalBoilerplate(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            guard sanitizedStreamingText(segment.text) != nil else { continue }
            result.append(segment)

            let maximumWindow = min(6, result.count)
            for windowSize in 1...maximumWindow {
                let combined = result.suffix(windowSize).map(\.text).joined(separator: " ")
                if containsCreatorBoilerplate(normalize(combined)) {
                    result.removeLast(windowSize)
                    break
                }
            }
        }

        while let last = result.last, terminalPhrases.contains(normalize(last.text)) {
            result.removeLast()
        }
        return result
    }

    static func removingConsecutiveDuplicates(
        from candidates: [TranscriptSegment],
        after previous: TranscriptSegment?
    ) -> [TranscriptSegment] {
        var lastNormalized = previous.map { normalize($0.text) }
        var result: [TranscriptSegment] = []
        for segment in candidates {
            let normalized = normalize(segment.text)
            guard !normalized.isEmpty, normalized != lastNormalized else { continue }
            result.append(segment)
            lastNormalized = normalized
        }
        return result
    }

    private static let terminalPhrases: Set<String> = [
        "谢谢", "谢谢大家", "感谢大家", "感谢观看", "谢谢观看", "下期再见",
        "thankyou", "thanks", "thankyouforwatching", "thanksforwatching"
    ]

    private static let creatorPhrases = [
        "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "请不吝点赞订阅转发打赏支持明镜与点点",
        "点赞订阅转发打赏支持明镜与点点栏目",
        "请点赞订阅转发打赏支持明镜与点点栏目",
        "請不吝點讚訂閱轉發打賞支持明鏡與點點欄目"
    ]

    private static func containsCreatorBoilerplate(_ normalized: String) -> Bool {
        if creatorPhrases.contains(where: normalized.contains) { return true }
        let mentionsProgram = normalized.contains("明镜与点点")
            || normalized.contains("明鏡與點點")
        let promotionKeywords = ["点赞", "點讚", "订阅", "訂閱", "转发", "轉發", "打赏", "打賞"]
            .filter { normalized.contains($0) }
        return mentionsProgram && promotionKeywords.count >= 2
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
    }
}

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

    static func adaptiveCharactersPerSecond(
        pendingCount: Int,
        recentThreeSecondCount: Int,
        recentTwoSecondCount: Int,
        observationDuration: TimeInterval
    ) -> Double {
        guard pendingCount > 0 else { return 0 }
        // A one-second startup denominator preserves a readable reveal for small
        // updates instead of treating the first frame as an enormous per-second
        // producer spike.
        let duration = min(max(observationDuration, 1), 3)
        let recognitionRate = Double(recentThreeSecondCount) / duration
        let allowedBacklog = max(recentTwoSecondCount, 500)
        let excessBacklog = max(pendingCount - allowedBacklog, 0)

        // Follow the producer under normal load. If the two-second backlog gate is
        // exceeded, add enough catch-up capacity to return below it promptly. This
        // deliberately has no fixed upper rate: a fixed cap makes long or bursty
        // recognition output mathematically impossible to catch up with.
        return max(recognitionRate * 1.15, 18) + Double(excessBacklog) / 0.35
    }
}

@MainActor
protocol StreamingTextMonotonicClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor
protocol StreamingTextScheduledAnimation: AnyObject {
    func cancel()
}

@MainActor
protocol StreamingTextFrameScheduler: AnyObject {
    func schedule(every interval: TimeInterval, frame: @escaping @MainActor () -> Bool) -> StreamingTextScheduledAnimation
}

@MainActor
private final class SystemStreamingTextClock: StreamingTextMonotonicClock {
    private let origin = ContinuousClock.now

    var now: TimeInterval {
        let duration = origin.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

@MainActor
private final class TaskStreamingTextAnimation: StreamingTextScheduledAnimation {
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, frame: @escaping @MainActor () -> Bool) {
        task = Task { @MainActor in
            let nanoseconds = Int64(max(interval, 0.001) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(nanoseconds))
                guard !Task.isCancelled else { return }
                if frame() { return }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
private final class TaskStreamingTextFrameScheduler: StreamingTextFrameScheduler {
    func schedule(
        every interval: TimeInterval,
        frame: @escaping @MainActor () -> Bool
    ) -> StreamingTextScheduledAnimation {
        TaskStreamingTextAnimation(interval: interval, frame: frame)
    }
}

@MainActor
final class AdaptiveStreamingTextAnimator {
    private struct SubmissionSample {
        let time: TimeInterval
        let scalarCount: Int
    }

    private static let frameInterval: TimeInterval = 0.024
    private static let immediateBatchScalarCount = 5_000

    private var targetScalars: [Unicode.Scalar] = []
    private var visibleScalarCount = 0
    private var scheduledAnimation: StreamingTextScheduledAnimation?
    private var submissionSamples: [SubmissionSample] = []
    private var firstSubmissionAt: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private var characterCredit = 0.0
    private let clock: StreamingTextMonotonicClock
    private let frameScheduler: StreamingTextFrameScheduler
    private let onUpdate: (String) -> Void

    init(onUpdate: @escaping (String) -> Void) {
        self.clock = SystemStreamingTextClock()
        self.frameScheduler = TaskStreamingTextFrameScheduler()
        self.onUpdate = onUpdate
    }

    init(
        clock: StreamingTextMonotonicClock,
        frameScheduler: StreamingTextFrameScheduler,
        onUpdate: @escaping (String) -> Void
    ) {
        self.clock = clock
        self.frameScheduler = frameScheduler
        self.onUpdate = onUpdate
    }

    func reset(to text: String = "") {
        scheduledAnimation?.cancel()
        scheduledAnimation = nil
        targetScalars = Array(text.unicodeScalars)
        visibleScalarCount = targetScalars.count
        submissionSamples.removeAll(keepingCapacity: true)
        firstSubmissionAt = nil
        lastFrameAt = nil
        characterCredit = 0
        onUpdate(text)
    }

    func submit(_ text: String, animated: Bool) {
        let newTarget = Array(text.unicodeScalars)
        guard newTarget != targetScalars else { return }

        let sharedWithOldTarget = commonPrefixCount(targetScalars, newTarget)
        let sharedWithVisible = min(sharedWithOldTarget, visibleScalarCount)
        let changedScalarCount = max(newTarget.count - sharedWithOldTarget, 0)
        let now = clock.now
        firstSubmissionAt = firstSubmissionAt ?? now
        submissionSamples.append(SubmissionSample(time: now, scalarCount: changedScalarCount))
        pruneSubmissionSamples(at: now)
        targetScalars = newTarget

        if sharedWithVisible < visibleScalarCount {
            visibleScalarCount = sharedWithVisible
            onUpdate(visibleText())
        }

        guard animated, changedScalarCount < Self.immediateBatchScalarCount else {
            flush()
            return
        }
        startAnimationIfNeeded()
    }

    func flush() {
        scheduledAnimation?.cancel()
        scheduledAnimation = nil
        characterCredit = 0
        lastFrameAt = nil
        visibleScalarCount = targetScalars.count
        onUpdate(visibleText())
    }

    func cancel() {
        scheduledAnimation?.cancel()
        scheduledAnimation = nil
        lastFrameAt = nil
    }

    private func startAnimationIfNeeded() {
        guard visibleScalarCount < targetScalars.count, scheduledAnimation == nil else { return }
        lastFrameAt = clock.now
        scheduledAnimation = frameScheduler.schedule(every: Self.frameInterval) { [weak self] in
            guard let self else { return true }
            return self.advanceFrame()
        }
    }

    private func advanceFrame() -> Bool {
        let now = clock.now
        let frameDuration = min(max(now - (lastFrameAt ?? now), 0), 0.25)
        lastFrameAt = now
        pruneSubmissionSamples(at: now)

        let pendingCount = targetScalars.count - visibleScalarCount
        guard pendingCount > 0 else {
            scheduledAnimation = nil
            characterCredit = 0
            lastFrameAt = nil
            return true
        }

        let recentThreeSecondCount = recentSubmissionCount(since: now - 3)
        let recentTwoSecondCount = recentSubmissionCount(since: now - 2)
        let observationDuration = min(max(now - (firstSubmissionAt ?? now), Self.frameInterval), 3)
        characterCredit += StreamingTextPacing.adaptiveCharactersPerSecond(
            pendingCount: pendingCount,
            recentThreeSecondCount: recentThreeSecondCount,
            recentTwoSecondCount: recentTwoSecondCount,
            observationDuration: observationDuration
        ) * frameDuration
        let requestedCount = Int(characterCredit)
        guard requestedCount > 0 else { return false }

        let revealCount = min(requestedCount, pendingCount)
        characterCredit -= Double(revealCount)
        visibleScalarCount += revealCount
        onUpdate(visibleText())

        if visibleScalarCount == targetScalars.count {
            scheduledAnimation = nil
            characterCredit = 0
            lastFrameAt = nil
            return true
        }
        return false
    }

    private func pruneSubmissionSamples(at now: TimeInterval) {
        submissionSamples.removeAll { $0.time < now - 3 }
    }

    private func recentSubmissionCount(since cutoff: TimeInterval) -> Int {
        submissionSamples.lazy
            .filter { $0.time >= cutoff }
            .reduce(0) { $0 + $1.scalarCount }
    }

    private func visibleText() -> String {
        String(String.UnicodeScalarView(targetScalars.prefix(visibleScalarCount)))
    }

    private func commonPrefixCount(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
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

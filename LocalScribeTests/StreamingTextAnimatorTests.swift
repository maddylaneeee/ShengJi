import XCTest
@testable import LocalScribe

@MainActor
private final class ManualStreamingTextClock: StreamingTextMonotonicClock {
    var now: TimeInterval = 0

    func advance(by duration: TimeInterval) {
        now += duration
    }
}

@MainActor
private final class ManualScheduledAnimation: StreamingTextScheduledAnimation {
    var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class ManualStreamingTextFrameScheduler: StreamingTextFrameScheduler {
    private(set) var token: ManualScheduledAnimation?
    private var frame: (@MainActor () -> Bool)?

    func schedule(
        every interval: TimeInterval,
        frame: @escaping @MainActor () -> Bool
    ) -> StreamingTextScheduledAnimation {
        let token = ManualScheduledAnimation()
        self.token = token
        self.frame = frame
        return token
    }

    func runFrame() {
        guard token?.isCancelled == false, let frame else { return }
        if frame() {
            self.frame = nil
        }
    }
}

final class StreamingTextAnimatorTests: XCTestCase {
    func testAdaptivePacingHasNoFixedUpperRate() {
        let rate = StreamingTextPacing.adaptiveCharactersPerSecond(
            pendingCount: 4_999,
            recentThreeSecondCount: 2_400,
            recentTwoSecondCount: 1_600,
            observationDuration: 3
        )

        XCTAssertGreaterThan(rate, 110)
    }

    @MainActor
    func testLargeBatchIsVisibleImmediatelyWithoutPerFrameRebuilds() {
        let clock = ManualStreamingTextClock()
        let scheduler = ManualStreamingTextFrameScheduler()
        var updates: [String] = []
        let animator = AdaptiveStreamingTextAnimator(
            clock: clock,
            frameScheduler: scheduler,
            onUpdate: { updates.append($0) }
        )
        let target = String(repeating: "声", count: 100_000)

        let startedAt = ContinuousClock.now
        animator.submit(target, animated: true)
        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        XCTAssertEqual(updates, [target])
        XCTAssertNil(scheduler.token)
        XCTAssertLessThan(elapsedSeconds, 0.1)
    }

    @MainActor
    func testBacklogBoundAtRequiredRecognitionRates() {
        for rate in [50, 200, 800] {
            let clock = ManualStreamingTextClock()
            let scheduler = ManualStreamingTextFrameScheduler()
            var latest = ""
            let animator = AdaptiveStreamingTextAnimator(
                clock: clock,
                frameScheduler: scheduler,
                onUpdate: { latest = $0 }
            )
            var target = ""
            var producedInLastTwoSeconds: [Int] = []

            for tick in 0..<100 {
                let produced = rate / 10
                target.append(String(repeating: "a", count: produced))
                producedInLastTwoSeconds.append(produced)
                if producedInLastTwoSeconds.count > 20 { producedInLastTwoSeconds.removeFirst() }
                animator.submit(target, animated: true)
                clock.advance(by: 0.1)
                scheduler.runFrame()

                if tick >= 19 {
                    let backlog = target.unicodeScalars.count - latest.unicodeScalars.count
                    XCTAssertLessThanOrEqual(
                        backlog,
                        max(producedInLastTwoSeconds.reduce(0, +), 500),
                        "Backlog exceeded the two-second bound at \(rate) scalars/second, tick \(tick)"
                    )
                }
            }
        }
    }

    @MainActor
    func testInjectedClockAndSchedulerDriveAdaptiveProgress() {
        let clock = ManualStreamingTextClock()
        let scheduler = ManualStreamingTextFrameScheduler()
        var latest = ""
        let animator = AdaptiveStreamingTextAnimator(
            clock: clock,
            frameScheduler: scheduler,
            onUpdate: { latest = $0 }
        )
        let target = String(repeating: "a", count: 800)

        animator.submit(target, animated: true)
        XCTAssertEqual(latest, "")

        for _ in 0..<20 {
            clock.advance(by: 0.1)
            scheduler.runFrame()
        }

        let backlog = target.unicodeScalars.count - latest.unicodeScalars.count
        XCTAssertLessThanOrEqual(backlog, 500)
    }

    @MainActor
    func testUnicodeScalarRevisionAndShrinkRemainExact() {
        let clock = ManualStreamingTextClock()
        let scheduler = ManualStreamingTextFrameScheduler()
        var latest = ""
        let animator = AdaptiveStreamingTextAnimator(
            clock: clock,
            frameScheduler: scheduler,
            onUpdate: { latest = $0 }
        )

        animator.submit("Cafe\u{301} 👩🏽‍💻 alpha", animated: true)
        clock.advance(by: 0.5)
        scheduler.runFrame()
        animator.submit("Cafe\u{301} 👩🏽‍💻 beta", animated: true)
        animator.submit("Cafe\u{301} 👩🏽", animated: true)
        animator.flush()

        XCTAssertEqual(
            Array(latest.unicodeScalars),
            Array("Cafe\u{301} 👩🏽".unicodeScalars)
        )
    }

    @MainActor
    func testSeededAppendShrinkAndRevisionSequencesConvergeExactly() {
        let clock = ManualStreamingTextClock()
        let scheduler = ManualStreamingTextFrameScheduler()
        var latest = ""
        let animator = AdaptiveStreamingTextAnimator(
            clock: clock,
            frameScheduler: scheduler,
            onUpdate: { latest = $0 }
        )
        let alphabet: [Unicode.Scalar] = ["a", "界", "🙂", "\u{301}"]
        var state: UInt64 = 0x5EED
        var target: [Unicode.Scalar] = []

        func nextInt(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state % UInt64(upperBound))
        }

        for _ in 0..<100 {
            switch nextInt(3) {
            case 0:
                target.append(alphabet[nextInt(alphabet.count)])
            case 1 where !target.isEmpty:
                target.removeLast(nextInt(target.count) + 1)
            default:
                let shared = target.isEmpty ? 0 : nextInt(target.count + 1)
                target = Array(target.prefix(shared))
                target.append(alphabet[nextInt(alphabet.count)])
            }
            animator.submit(String(String.UnicodeScalarView(target)), animated: true)
            clock.advance(by: 0.05)
            scheduler.runFrame()
        }

        animator.flush()
        XCTAssertEqual(Array(latest.unicodeScalars), target)
    }

    @MainActor
    func testIncrementalVisibleTextMatchesTargetPrefixesAcrossRevisions() {
        let clock = ManualStreamingTextClock()
        let scheduler = ManualStreamingTextFrameScheduler()
        var updates: [String] = []
        let animator = AdaptiveStreamingTextAnimator(
            clock: clock,
            frameScheduler: scheduler,
            onUpdate: { updates.append($0) }
        )
        animator.reset(to: "前文\n")

        let first = "前文\n第一行 alpha 😀\n第二行"
        animator.submit(first, animated: true)
        for _ in 0..<5 {
            clock.advance(by: 0.05)
            scheduler.runFrame()
        }
        let firstScalars = Array(first.unicodeScalars)
        for update in updates {
            let scalars = Array(update.unicodeScalars)
            XCTAssertEqual(scalars, Array(firstScalars.prefix(scalars.count)))
        }

        // Revise text before the visible end; output must roll back, then resume.
        updates.removeAll()
        let revised = "前文\n第一行 beta\n第二行改\n第三行"
        animator.submit(revised, animated: true)
        for _ in 0..<200 {
            clock.advance(by: 0.05)
            scheduler.runFrame()
        }
        let revisedScalars = Array(revised.unicodeScalars)
        for update in updates {
            let scalars = Array(update.unicodeScalars)
            XCTAssertEqual(scalars, Array(revisedScalars.prefix(scalars.count)))
        }
        XCTAssertEqual(updates.last, revised)
    }
}

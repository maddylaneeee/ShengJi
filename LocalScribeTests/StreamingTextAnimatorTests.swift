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

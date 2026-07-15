import XCTest
@testable import LocalScribe

final class TranscriptImportAndEditingTests: XCTestCase {
    func testSRTImportPreservesTextAndTimestamps() throws {
        let source = """
        1
        00:00:01,000 --> 00:00:03,250
        第一段字幕

        2
        00:00:04,000 --> 00:00:06,500
        第二段字幕
        """
        let result = try TranscriptImporter.parse(data: Data(source.utf8), fileName: "sample.srt")
        XCTAssertEqual(result.text, "第一段字幕\n第二段字幕")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(result.duration, 6.5, accuracy: 0.001)
    }

    func testWebVTTImportRemovesMarkup() throws {
        let source = """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        <v Speaker>Hello world</v>
        """
        let result = try TranscriptImporter.parse(data: Data(source.utf8), fileName: "sample.vtt")
        XCTAssertEqual(result.text, "Hello world")
    }

    func testFindReplaceAndRangeDeletion() throws {
        let text = "alpha beta gamma delta"
        let found = try XCTUnwrap(TranscriptTextEditing.find("beta", in: text, after: NSRange(location: 0, length: 0)))
        XCTAssertEqual((text as NSString).substring(with: found), "beta")
        let replaced = try XCTUnwrap(TranscriptTextEditing.replacing(text, range: found, with: "B"))
        XCTAssertEqual(replaced.0, "alpha B gamma delta")

        let between = try XCTUnwrap(TranscriptTextEditing.deletingBetween(
            text,
            first: NSRange(location: 0, length: 5),
            second: NSRange(location: 17, length: 5)
        ))
        XCTAssertEqual(between.0, "alphadelta")
    }

    func testLiveCaptionSlidingWindowKeepsContinuousUnpunctuatedOutput() {
        let target = "这是一个没有任何标点并且会持续增长的实时字幕识别结果"
        var frame = ""
        var frames = 0
        while frame != target, frames < 100 {
            let next = LiveCaptionSlidingWindow.nextFrame(current: frame, target: target)
            XCTAssertTrue(next.hasPrefix(frame))
            XCTAssertLessThanOrEqual(next.count - frame.count, 6)
            frame = next
            frames += 1
        }
        XCTAssertEqual(frame, target)
        XCTAssertGreaterThan(frames, 1)
    }

    func testLiveCaptionSlidingWindowAcceptsModelRevision() {
        XCTAssertEqual(
            LiveCaptionSlidingWindow.nextFrame(current: "今天天气", target: "今天的天气很好"),
            "今天的天气很好"
        )
    }

    func testLiveCaptionCompletedSegmentIsHeldAtBoundary() {
        let completed = LiveCaptionLine(
            source: "麦克风",
            text: "这句话已经完成。",
            isFinal: true
        )
        let partial = LiveCaptionLine(
            source: "麦克风",
            text: "下一句话",
            isFinal: false
        )

        XCTAssertTrue(LiveCaptionReadabilityPolicy.shouldHoldPrevious(completed))
        XCTAssertFalse(LiveCaptionReadabilityPolicy.shouldHoldPrevious(partial))
        XCTAssertEqual(LiveCaptionReadabilityPolicy.completedSegmentHoldDuration, .seconds(2))
        XCTAssertEqual(
            LiveCaptionReadabilityPolicy.displayText(
                held: completed.text,
                current: "下一句话仍在继续"
            ),
            "这句话已经完成。  下一句话仍在继续"
        )
    }
}

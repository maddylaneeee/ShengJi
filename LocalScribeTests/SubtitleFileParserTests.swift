import XCTest
@testable import LocalScribe

final class SubtitleFileParserTests: XCTestCase {
    private func parse(_ text: String, _ name: String) throws -> SubtitleDocument {
        try SubtitleFileParser.parse(data: Data(text.utf8), fileName: name)
    }

    private func assertRejects(_ text: String, _ name: String, _ expected: SubtitleValidationError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text, name), file: file, line: line) { error in
            XCTAssertEqual(error as? SubtitleValidationError, expected, file: file, line: line)
        }
    }

    // MARK: Supported formats

    func testParsesSRT() throws {
        let document = try parse("""
        1
        00:00:01,000 --> 00:00:02,500
        Hello <i>there</i>

        2
        00:00:03,000 --> 00:00:04,000
        第二行
        继续
        """, "a.srt")
        XCTAssertEqual(document.format, .srt)
        XCTAssertEqual(document.cues, [
            SubtitleCue(startTime: 1, endTime: 2.5, text: "Hello there"),
            SubtitleCue(startTime: 3, endTime: 4, text: "第二行\n继续"),
        ])
    }

    func testParsesWebVTTWithShortTimesNotesAndSettings() throws {
        let document = try parse("""
        WEBVTT - title

        NOTE this is ignored

        intro
        00:01.000 --> 00:02.000 align:start position:10%
        One

        01:00:00.250 --> 01:00:01.000
        Two
        """, "a.vtt")
        XCTAssertEqual(document.format, .webVTT)
        XCTAssertEqual(document.cues.map(\.startTime), [1, 3_600.25])
        XCTAssertEqual(document.cues.map(\.text), ["One", "Two"])
    }

    func testParsesLocalScribeJSONExport() throws {
        let data = try TranscriptExporter.makeData(
            format: .json, title: "t", source: "s", language: "en", duration: 5, text: "A\nB",
            segments: [TranscriptSegment(startTime: 0.5, endTime: 1.5, text: "A"),
                       TranscriptSegment(startTime: 2, endTime: 3, text: "B")],
            hasManualEdits: false
        )
        let document = try SubtitleFileParser.parse(data: data, fileName: "export.json")
        XCTAssertEqual(document.format, .localScribeJSON)
        XCTAssertEqual(document.cues.map(\.text), ["A", "B"])
        XCTAssertEqual(document.cues.first?.startTime, 0.5)
    }

    func testRoundTripsOwnSRTAndVTTExports() throws {
        let segments = [TranscriptSegment(startTime: 0, endTime: 1.2, text: "Hello"),
                        TranscriptSegment(startTime: 1.5, endTime: 2.75, text: "World")]
        for format in [TranscriptExportFormat.srt, .webVTT] {
            let data = try TranscriptExporter.makeData(format: format, title: "t", source: "s", language: "en",
                                                       duration: 3, text: "Hello\nWorld", segments: segments, hasManualEdits: false)
            let document = try SubtitleFileParser.parse(data: data, fileName: format == .srt ? "x.srt" : "x.vtt")
            XCTAssertEqual(document.cues.map(\.text), ["Hello", "World"])
            XCTAssertEqual(document.cues.last?.endTime ?? 0, 2.75, accuracy: 0.001)
        }
    }

    func testParsesASSIgnoringStylesAndOverrides() throws {
        let document = try parse("""
        [Script Info]
        Title: Demo

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,ignored
        Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\an8\\b1}Top, with comma\\NLine two
        """, "a.ass")
        XCTAssertEqual(document.format, .ass)
        XCTAssertEqual(document.cues, [SubtitleCue(startTime: 1.5, endTime: 3, text: "Top, with comma\nLine two")])
    }

    func testParsesSBV() throws {
        let document = try parse("""
        0:00:00.599,0:00:04.160
        >> First line

        0:00:04.160,0:00:06.770
        Second
        """, "captions.sbv")
        XCTAssertEqual(document.format, .sbv)
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.cues[0].startTime, 0.599, accuracy: 0.0001)
    }

    func testParsesTTMLClockOffsetTicksAndBreaks() throws {
        let document = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:tickRate="10000000">
          <body><div>
            <p begin="00:00:01.000" end="00:00:02.000">Hello<br/>world</p>
            <p begin="2.5s" dur="500ms"><span>Offset</span> time</p>
            <p begin="30000000t" end="40000000t">Ticks</p>
          </div></body>
        </tt>
        """, "a.dfxp")
        XCTAssertEqual(document.format, .ttml)
        XCTAssertEqual(document.cues.map(\.text), ["Hello\nworld", "Offset time", "Ticks"])
        XCTAssertEqual(document.cues[1].endTime, 3, accuracy: 0.0001)
        XCTAssertEqual(document.cues[2].startTime, 3, accuracy: 0.0001)
    }

    func testDetectsFormatByContentWhenExtensionIsWrong() throws {
        let document = try parse("1\n00:00:01,000 --> 00:00:02,000\nHi\n", "subtitle.txt")
        XCTAssertEqual(document.format, .srt)
    }

    func testDecodesBOMUTF16AndCRLF() throws {
        let text = "1\r\n00:00:01,000 --> 00:00:02,000\r\n你好\r\n"
        var utf8BOM = Data([0xEF, 0xBB, 0xBF]); utf8BOM.append(Data(text.utf8))
        XCTAssertEqual(try SubtitleFileParser.parse(data: utf8BOM, fileName: "a.srt").cues.first?.text, "你好")
        var utf16 = Data([0xFF, 0xFE]); utf16.append(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try SubtitleFileParser.parse(data: utf16, fileName: "a.srt").cues.first?.text, "你好")
    }

    func testSortsCuesByStartTime() throws {
        let document = try parse("""
        2
        00:00:05,000 --> 00:00:06,000
        Later

        1
        00:00:01,000 --> 00:00:02,000
        Earlier
        """, "a.srt")
        XCTAssertEqual(document.cues.map(\.text), ["Earlier", "Later"])
    }

    // MARK: Rejections

    func testRejectsPlainTextAndMarkdown() {
        assertRejects("Just a transcript.\nNo timing.", "notes.txt", .unsupportedFormat)
        assertRejects("# Title\n\nBody", "notes.md", .unsupportedFormat)
        XCTAssertThrowsError(try SubtitleFileParser.parse(data: Data([0, 1, 2, 3, 0]), fileName: "video.srt"))
    }

    func testRejectsSubtitleExtensionWithoutTimestamps() {
        assertRejects("Hello\n\nWorld", "a.srt", .noTimestamps)
    }

    func testRejectsInvalidTimestampsWithLineNumber() {
        assertRejects("1\n00:00:02,000 --> 00:00:01,000\nBackwards\n", "a.srt", .invalidTimestamp(line: 2))
        assertRejects("1\n00:00:01,000 --> 00:00:02,000\nOK\n\n2\n00:00:61,000 --> 00:01:02,000\nBad seconds\n", "a.srt",
                      .invalidTimestamp(line: 6))
        assertRejects("1\n00:00:01,000 -> 00:00:02,000\nBroken arrow\n", "a.srt", .invalidTimestamp(line: 2))
        assertRejects("WEBVTT\n\n00:01.000 --> 00:00.500\nBad\n", "a.vtt", .invalidTimestamp(line: 3))
        assertRejects("0:00:03.000,0:00:01.000\nBad\n", "a.sbv", .invalidTimestamp(line: 1))
    }

    func testRejectsASSWithBadTimeOrNoDialogue() {
        let header = "[Script Info]\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        assertRejects(header + "Dialogue: 0,0:00:05.00,0:00:01.00,Default,,0,0,0,,Bad\n", "a.ass", .invalidTimestamp(line: 5))
        assertRejects(header, "a.ass", .noTimestamps)
    }

    func testRejectsJSONWithoutReliableSegments() throws {
        assertRejects(#"{"text":"Hello"}"#, "a.json", .noTimestamps)
        assertRejects(#"{"text":"Hello","segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startTime":0,"endTime":1,"text":"Hello"}],"timelineProvenance":"estimated"}"#,
                      "a.json", .unreliableTimeline)
        assertRejects(#"{"text":"Hello","segments":[{"startTime":2,"endTime":1,"text":"Hello"}],"timelineProvenance":"json"}"#,
                      "a.json", .invalidSegment(index: 1))
        assertRejects(#"{"unrelated":true}"#, "a.json", .noTimestamps)
        assertRejects(#"[1,2,3]"#, "a.json", .unsupportedFormat)
    }

    func testRejectsTTMLParagraphWithoutTiming() {
        assertRejects("""
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p>No timing</p>
        </div></body></tt>
        """, "a.ttml", .invalidTimestamp(line: 2))
        assertRejects("<tt xmlns=\"http://www.w3.org/ns/ttml\"><body/></tt>", "a.ttml", .noTimestamps)
    }

    func testRejectsTimedFileWithOnlyEmptyText() {
        assertRejects("1\n00:00:01,000 --> 00:00:02,000\n\n", "a.srt", .noText)
    }

    func testErrorMessagesAreLocalized() {
        XCTAssertFalse(SubtitleValidationError.invalidTimestamp(line: 3).localizedDescription.isEmpty)
        XCTAssertTrue(SubtitleValidationError.invalidTimestamp(line: 3).localizedDescription.contains("3"))
    }

    // MARK: Warnings

    func testWarnsAboutCuesBeyondVideoAndOverlaps() throws {
        let document = try parse("""
        1
        00:00:01,000 --> 00:00:03,000
        A

        2
        00:00:02,000 --> 00:00:04,000
        B

        3
        00:00:09,000 --> 00:00:12,000
        C
        """, "a.srt")
        XCTAssertEqual(document.warnings(videoDuration: 10), [.beyondVideo(count: 1), .overlapping(count: 1)])
        XCTAssertEqual(document.warnings(videoDuration: nil), [.overlapping(count: 1)])
    }
}

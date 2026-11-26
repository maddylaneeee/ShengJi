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

    func testDecodesBOMUTF16AndCRLF() throws {
        let text = "1\r\n00:00:01,000 --> 00:00:02,000\r\n你好\r\n"
        var utf8BOM = Data([0xEF, 0xBB, 0xBF]); utf8BOM.append(Data(text.utf8))
        XCTAssertEqual(try SubtitleFileParser.parse(data: utf8BOM, fileName: "a.srt").cues.first?.text, "你好")
        var utf16 = Data([0xFF, 0xFE]); utf16.append(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try SubtitleFileParser.parse(data: utf16, fileName: "a.srt").cues.first?.text, "你好")
    }

    func testRejectsInvalidTimestampsWithLineNumber() {
        assertRejects("1\n00:00:02,000 --> 00:00:01,000\nBackwards\n", "a.srt", .invalidTimestamp(line: 2))
        assertRejects("1\n00:00:01,000 --> 00:00:02,000\nOK\n\n2\n00:00:61,000 --> 00:01:02,000\nBad seconds\n", "a.srt",
                      .invalidTimestamp(line: 6))
        assertRejects("1\n00:00:01,000 -> 00:00:02,000\nBroken arrow\n", "a.srt", .invalidTimestamp(line: 2))
        assertRejects("WEBVTT\n\n00:01.000 --> 00:00.500\nBad\n", "a.vtt", .invalidTimestamp(line: 3))
        assertRejects("0:00:03.000,0:00:01.000\nBad\n", "a.sbv", .invalidTimestamp(line: 1))
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
}

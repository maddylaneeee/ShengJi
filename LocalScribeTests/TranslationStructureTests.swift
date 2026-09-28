import XCTest
@testable import LocalScribe

final class TranslationStructureTests: XCTestCase {
    func testLongUnspacedChineseIsSplitWithoutLosingTextOrTime() throws {
        let text = String(repeating: "这是没有空格也没有句末标点的中文字幕", count: 5)
        let segment = TranscriptSegment(startTime: 1, endTime: 11, text: text)
        let cues = SubtitleTextLayout.cues(for: segment)

        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertEqual(cues.map(\.text).joined().replacingOccurrences(of: "\n", with: ""), text)
        XCTAssertEqual(cues.first?.startTime, 1)
        XCTAssertEqual(cues.last?.endTime, 11)
        XCTAssertTrue(cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 })
        XCTAssertTrue(zip(cues, cues.dropFirst()).allSatisfy { $0.endTime == $1.startTime })

        let srt = try TranscriptExporter.makeData(
            format: .srt, title: "CJK", source: "fixture.wav", language: "Chinese",
            duration: 11, text: text, segments: [segment], hasManualEdits: false
        )
        XCTAssertTrue(String(decoding: srt, as: UTF8.self).contains("00:00:01,000 -->"))
    }

    func testBlankSubtitleDoesNotCreateEmptyCue() throws {
        for format: TranscriptExportFormat in [.srt, .webVTT] {
            let data = try TranscriptExporter.makeData(
                format: format, title: "Blank", source: "fixture.wav", language: "Chinese",
                duration: 10, text: "  \n  ", segments: [], hasManualEdits: true
            )
            let output = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(output.contains("-->"))
        }
    }

    func testMixedLanguageAndExistingNewlinesKeepCharacters() {
        let text = "中文，English words.\n下一行🙂字幕"
        let cues = SubtitleTextLayout.cues(for: TranscriptSegment(startTime: 0, endTime: 4, text: text))
        XCTAssertEqual(cues.map(\.text).joined().replacingOccurrences(of: "\n", with: ""),
                       text.replacingOccurrences(of: "\n", with: ""))
        XCTAssertTrue(cues.allSatisfy { !$0.text.isEmpty })
    }

    func testCJKCueBoundaryAndTwoLineLimit() throws {
        let text = String(repeating: "中文", count: 20)
        let data = try TranscriptExporter.makeData(
            format: .srt, title: "CJK", source: "fixture.wav", language: "Chinese",
            duration: 10, text: text, segments: [], hasManualEdits: true
        )
        let expected = """
        1
        00:00:00,000 --> 00:00:09,000
        \(String(repeating: "中文", count: 9))
        \(String(repeating: "中文", count: 9))

        2
        00:00:09,000 --> 00:00:10,000
        中文中文

        """
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    func testJSONKeepsOriginalSegmentWithoutSubtitleLayout() throws {
        let text = String(repeating: "中文", count: 20)
        let segment = TranscriptSegment(startTime: 1, endTime: 11, text: text)
        let data = try TranscriptExporter.makeData(
            format: .json, title: "CJK", source: "fixture.wav", language: "Chinese",
            duration: 11, text: text, segments: [segment], hasManualEdits: false
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(payload["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?["text"] as? String, text)
    }

    func testNLLBLineBatchPreservesBlankLinesAndUnitIdentity() throws {
        let first = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            startTime: 0,
            endTime: 2,
            text: "第一行\n第二行\n\n第四行"
        )
        let second = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            startTime: 2,
            endTime: 3,
            text: "第五行"
        )
        let units = [first, second].enumerated().map {
            TranslationUnit(segment: $0.element, ordinal: $0.offset)
        }
        let batch = NLLBLineBatch(units: units)

        XCTAssertEqual(batch.requestTexts, ["第一行", "第二行", "第四行", "第五行"])
        XCTAssertEqual(batch.requestIDs.count, 4)
        XCTAssertEqual(
            try batch.reconstruct(translations: ["First", "Second", "Fourth", "Fifth"]),
            ["First\nSecond\n\nFourth", "Fifth"]
        )
    }

    func testTranslationKeepsSourceIdentityAndLineBoundaries() throws {
        let first = TranscriptSegment(startTime: 0, endTime: 1.5, text: "第一行")
        let second = TranscriptSegment(startTime: 1.5, endTime: 3, text: "第二行")
        let values = [first, second].enumerated().map { index, segment in
            let unit = TranslationUnit(segment: segment, ordinal: index)
            return SegmentTranslation(
                id: unit.id,
                sourceSegmentID: unit.sourceSegmentID,
                ordinal: unit.ordinal,
                startTime: unit.startTime,
                endTime: unit.endTime,
                sourceText: unit.sourceText,
                translatedText: index == 0 ? "First line" : "Second line",
                state: .translated,
                errorMessage: nil
            )
        }

        XCTAssertEqual(values.map(\.transcriptSegment).map(\.id), [first.id, second.id])
        XCTAssertEqual(values.map(\.displayText).joined(separator: "\n"), "First line\nSecond line")
        XCTAssertEqual(values[1].transcriptSegment.startTime, second.startTime)
        XCTAssertEqual(values[1].transcriptSegment.endTime, second.endTime)
    }

    func testFailedTranslationIsExplicitAndKeepsSourceText() {
        let source = TranscriptSegment(startTime: 4, endTime: 5, text: "保留我")
        let unit = TranslationUnit(segment: source, ordinal: 0)
        let failed = SegmentTranslation(
            id: unit.id,
            sourceSegmentID: unit.sourceSegmentID,
            ordinal: 0,
            startTime: unit.startTime,
            endTime: unit.endTime,
            sourceText: unit.sourceText,
            translatedText: unit.sourceText,
            state: .fallback,
            errorMessage: "mock failure"
        )

        XCTAssertEqual(failed.displayText(languageCode: "en"), "[Not translated] 保留我")
        XCTAssertEqual(failed.displayText(languageCode: "zh-Hans"), "【未翻译】保留我")
        XCTAssertEqual(failed.transcriptSegment.id, source.id)
    }

    func testSRTAndWebVTTKeepCueBoundaries() throws {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Line one"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "Line two")
        ]
        let srt = try TranscriptExporter.makeData(
            format: .srt,
            title: "Test",
            source: "fixture.wav",
            language: "English",
            duration: 2,
            text: "Line one\nLine two",
            segments: segments,
            hasManualEdits: false
        )
        let vtt = try TranscriptExporter.makeData(
            format: .webVTT,
            title: "Test",
            source: "fixture.wav",
            language: "English",
            duration: 2,
            text: "Line one\nLine two",
            segments: segments,
            hasManualEdits: false
        )

        XCTAssertTrue(String(decoding: srt, as: UTF8.self).contains("Line one\n\n2\n"))
        XCTAssertTrue(String(decoding: vtt, as: UTF8.self).contains("Line one\n\n00:00:01.000"))
    }
}

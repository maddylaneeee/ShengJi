import XCTest
@testable import LocalScribe

final class TranslationStructureTests: XCTestCase {
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

        XCTAssertEqual(failed.displayText, "【未翻译】保留我")
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

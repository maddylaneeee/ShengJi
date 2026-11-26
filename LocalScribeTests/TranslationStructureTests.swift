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

    func testMixedLanguageAndExistingNewlinesKeepCharacters() {
        let text = "中文，English words.\n下一行🙂字幕"
        let cues = SubtitleTextLayout.cues(for: TranscriptSegment(startTime: 0, endTime: 4, text: text))
        XCTAssertEqual(cues.map(\.text).joined().replacingOccurrences(of: "\n", with: ""),
                       text.replacingOccurrences(of: "\n", with: ""))
        XCTAssertTrue(cues.allSatisfy { !$0.text.isEmpty })
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
}

import XCTest
@testable import LocalScribe

final class LongTaskStorageTests: XCTestCase {
    @MainActor
    func testRecognitionPreferencesDefaultToAppleAndRestoreExplicitChoice() {
        let defaults = UserDefaults.standard
        let keys = ["RecognitionEngine", "LastThirdPartyRecognitionEngine"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        keys.forEach(defaults.removeObject(forKey:))
        XCTAssertEqual(RecognitionPreferences().engine, .apple)

        defaults.set(RecognitionEngine.parakeet.rawValue, forKey: "RecognitionEngine")
        defaults.set(RecognitionEngine.parakeet.rawValue, forKey: "LastThirdPartyRecognitionEngine")
        XCTAssertEqual(RecognitionPreferences().engine, .parakeet)
    }

    func testFloatRingBufferMaintainsOrderAcrossCompaction() {
        var buffer = FloatRingBuffer()
        buffer.append(contentsOf: Array(repeating: 1, count: 70_000))
        XCTAssertEqual(buffer.takeFirst(68_000).count, 68_000)
        buffer.append(contentsOf: [2, 3, 4])
        XCTAssertEqual(buffer.takeAll().suffix(3), [2, 3, 4])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRecognitionConfigurationDecodesLegacySnapshotWithoutComputeBackend() throws {
        let data = Data(#"{"engine":"whisper","whisperModel":"tiny"}"#.utf8)
        let configuration = try JSONDecoder().decode(RecognitionConfiguration.self, from: data)
        XCTAssertEqual(configuration.computeBackend, .automatic)
    }

    func testRepositoryReplaysPagesThatAreNoLongerInTheMemoryTail() async throws {
        let repository = TranscriptRepository(sessionID: UUID())
        let values = (0..<1_000).map { index in
            TranscriptSegment(
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                text: "片段 \(index)"
            )
        }
        await repository.appendSourceSegments(values)
        let firstPage = await repository.page(offset: 0, limit: 200)
        let lastPage = await repository.page(offset: 800, limit: 200)
        XCTAssertEqual(firstPage.totalCount, 1_000)
        XCTAssertEqual(firstPage.segments.first?.text, "片段 0")
        XCTAssertEqual(lastPage.segments.last?.text, "片段 999")
        let directory = await repository.directoryURL
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepositoryReadsColdPagesFromHundredThousandSegmentJournal() async throws {
        let repository = TranscriptRepository(sessionID: UUID())
        for batchStart in stride(from: 0, to: 100_000, by: 1_000) {
            let batch = (batchStart..<(batchStart + 1_000)).map { index in
                TranscriptSegment(
                    startTime: Double(index) * 0.5,
                    endTime: Double(index + 1) * 0.5,
                    text: "耐久片段 \(index)"
                )
            }
            await repository.appendSourceSegments(batch)
        }

        let first = await repository.page(offset: 0, limit: 200)
        let middle = await repository.page(offset: 49_900, limit: 200)
        let last = await repository.page(offset: 99_800, limit: 200)
        XCTAssertEqual(first.totalCount, 100_000)
        XCTAssertEqual(first.segments.first?.text, "耐久片段 0")
        XCTAssertEqual(middle.segments.first?.text, "耐久片段 49900")
        XCTAssertEqual(middle.segments.last?.text, "耐久片段 50099")
        XCTAssertEqual(last.segments.last?.text, "耐久片段 99999")

        let directory = await repository.directoryURL
        try? FileManager.default.removeItem(at: directory)
    }
}

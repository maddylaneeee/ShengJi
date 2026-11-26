import XCTest
@testable import LocalScribe

final class LongTaskStorageTests: XCTestCase {
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
        XCTAssertEqual(configuration.advancedOptions, .default)
    }

    func testAdvancedOptionsRoundTripAndClampUnsafePersistedValues() throws {
        let data = Data(#"""
        {
          "engine": "whisper",
          "whisperModel": "tiny",
          "advancedOptions": {
            "whisper": {
              "initialPrompt": "LocalScribe terminology",
              "temperature": 7,
              "beamSize": 99,
              "threadCount": -4
            },
            "parakeet": {
              "decodingMethod": "modifiedBeamSearch",
              "maxActivePaths": 200,
              "blankPenalty": -2,
              "threadCount": 999
            }
          }
        }
        """#.utf8)
        let configuration = try JSONDecoder().decode(RecognitionConfiguration.self, from: data)
        XCTAssertEqual(configuration.advancedOptions.whisper.initialPrompt, "LocalScribe terminology")
        XCTAssertEqual(configuration.advancedOptions.whisper.temperature, 1)
        XCTAssertEqual(configuration.advancedOptions.whisper.beamSize, 20)
        XCTAssertEqual(configuration.advancedOptions.whisper.threadCount, 0)
        XCTAssertEqual(configuration.advancedOptions.parakeet.decodingMethod, .modifiedBeamSearch)
        XCTAssertEqual(configuration.advancedOptions.parakeet.maxActivePaths, 64)
        XCTAssertEqual(configuration.advancedOptions.parakeet.blankPenalty, 0)
        XCTAssertEqual(
            configuration.advancedOptions.parakeet.threadCount,
            RecognitionThreadPolicy.maximumManualCount
        )

        let roundTripped = try JSONDecoder().decode(
            RecognitionConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(roundTripped, configuration)
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

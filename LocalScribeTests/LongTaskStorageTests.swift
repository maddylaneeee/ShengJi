import XCTest
@testable import LocalScribe

final class LongTaskStorageTests: XCTestCase {
    @MainActor
    func testRecognitionPreferencesDefaultToAppleAndRestoreExplicitChoice() {
        let defaults = UserDefaults.standard
        let keys = [
            "RecognitionEngine",
            "LastThirdPartyRecognitionEngine",
            "WhisperModel",
            "SenseVoiceModel",
            "ParakeetModel"
        ]
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
        defaults.set(WhisperModel.medium.rawValue, forKey: "WhisperModel")
        defaults.set(SenseVoiceModel.full_2024.rawValue, forKey: "SenseVoiceModel")
        defaults.set(ParakeetModel.unified06bInt8.rawValue, forKey: "ParakeetModel")

        let restored = RecognitionPreferences()
        XCTAssertEqual(restored.engine, .parakeet)
        XCTAssertEqual(restored.selectedWhisperModel, .medium)
        XCTAssertEqual(restored.selectedSenseVoiceModel, .full_2024)
        XCTAssertEqual(restored.selectedParakeetModel, .unified06bInt8)
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
        XCTAssertEqual(configuration.advancedOptions, .default)
    }

    @MainActor
    func testAdvancedOptionsPersistAcrossPreferenceInstancesAndCanReset() {
        let defaults = UserDefaults.standard
        let key = "RecognitionAdvancedOptions"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let first = RecognitionPreferences()
        first.advancedOptions.whisper.initialPrompt = "Persistent terminology"
        first.advancedOptions.whisper.temperature = 0.45

        let restored = RecognitionPreferences()
        XCTAssertEqual(restored.advancedOptions.whisper.initialPrompt, "Persistent terminology")
        XCTAssertEqual(restored.advancedOptions.whisper.temperature, 0.45)

        restored.resetAdvancedOptions(for: .whisper)
        XCTAssertEqual(restored.advancedOptions.whisper, .default)
    }

    func testAdvancedOptionsRoundTripAndClampUnsafePersistedValues() throws {
        let data = Data(#"""
        {
          "engine": "whisper",
          "whisperModel": "tiny",
          "advancedOptions": {
            "whisper": {
              "initialPrompt": "ShengJi terminology",
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
        XCTAssertEqual(configuration.advancedOptions.whisper.initialPrompt, "ShengJi terminology")
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

    func testSherpaArgumentsUseOnlySupportedAdvancedOptions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribe-AdvancedOptions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["model.onnx", "tokens.txt", "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        var advanced = RecognitionAdvancedOptions.default
        advanced.senseVoice.useInverseTextNormalization = false
        advanced.senseVoice.threadCount = 3
        let senseVoice = try SherpaOnnxFileProcessor.arguments(
            for: .senseVoice(.full_2025),
            modelURL: directory,
            languageCode: "zh",
            provider: "cpu",
            advancedOptions: advanced
        )
        XCTAssertTrue(senseVoice.contains("--sense-voice-use-itn=false"))
        XCTAssertTrue(senseVoice.contains("--num-threads=\(RecognitionThreadPolicy.normalized(3))"))

        advanced.parakeet.decodingMethod = .modifiedBeamSearch
        advanced.parakeet.maxActivePaths = 12
        advanced.parakeet.blankPenalty = 0.7
        advanced.parakeet.threadCount = 5
        let parakeet = try SherpaOnnxFileProcessor.arguments(
            for: .parakeet(.tdt06bV3Int8),
            modelURL: directory,
            languageCode: "en",
            provider: "coreml",
            advancedOptions: advanced
        )
        XCTAssertTrue(parakeet.contains("--decoding-method=modified_beam_search"))
        XCTAssertTrue(parakeet.contains("--max-active-paths=12"))
        XCTAssertTrue(parakeet.contains("--blank-penalty=0.7"))
        XCTAssertTrue(parakeet.contains("--num-threads=\(RecognitionThreadPolicy.normalized(5))"))
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

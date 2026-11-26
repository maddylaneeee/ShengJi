import XCTest
import WhisperMetal
@testable import LocalScribe

final class WhisperPipelineTests: XCTestCase {
    func testAdvancedOptionsMapToWhisperCppParametersForFileAndMicrophone() {
        var options = WhisperAdvancedOptions.default
        options.temperature = 0.35
        options.temperatureIncrement = 0.15
        options.beamSize = 9
        options.greedyBestOf = 6
        options.maxTextContextTokens = 160
        options.suppressBlank = false
        options.suppressNonSpeechTokens = false
        options.compressionRatioThreshold = 3.1
        options.logProbabilityThreshold = -0.7
        options.noSpeechThreshold = 0.62
        options.realtimeNoSpeechThreshold = 0.38
        options.carryInitialPrompt = true
        options.threadCount = 4

        let file = WhisperModelContext.decodingParameters(
            options: options,
            preserveContext: true,
            mode: .accurate
        )
        XCTAssertEqual(file.strategy, WHISPER_SAMPLING_BEAM_SEARCH)
        XCTAssertEqual(file.temperature, 0.35, accuracy: 0.001)
        XCTAssertEqual(file.temperature_inc, 0.15, accuracy: 0.001)
        XCTAssertEqual(file.beam_search.beam_size, 9)
        XCTAssertEqual(file.n_max_text_ctx, 160)
        XCTAssertEqual(file.n_threads, Int32(RecognitionThreadPolicy.normalized(4)))
        XCTAssertFalse(file.suppress_blank)
        XCTAssertFalse(file.suppress_nst)
        XCTAssertEqual(file.entropy_thold, 3.1, accuracy: 0.001)
        XCTAssertEqual(file.logprob_thold, -0.7, accuracy: 0.001)
        XCTAssertEqual(file.no_speech_thold, 0.62, accuracy: 0.001)
        XCTAssertTrue(file.carry_initial_prompt)

        let microphone = WhisperModelContext.decodingParameters(
            options: options,
            preserveContext: true,
            mode: .realtime
        )
        XCTAssertEqual(microphone.strategy, WHISPER_SAMPLING_GREEDY)
        XCTAssertEqual(microphone.greedy.best_of, 6)
        XCTAssertEqual(microphone.temperature_inc, 0, accuracy: 0.001)
        XCTAssertEqual(microphone.no_speech_thold, 0.38, accuracy: 0.001)
    }

    func testBundledVADModelIsReadableAndNonEmpty() throws {
        let url = try XCTUnwrap(WhisperVADResource.modelURL)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }

    func testAudioPreprocessingRemovesInvalidSamplesAndDCOffset() {
        var samples: [Float] = [.nan, .infinity, 1.4, 0.4]
        WhisperAudio.preprocess(&samples)

        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 0.981)
        XCTAssertEqual(samples.reduce(0, +) / Float(samples.count), 0, accuracy: 0.0001)
    }

    func testHallucinationFilterCombinesSilenceAndConfidence() {
        XCTAssertTrue(WhisperOutputFilter.shouldDiscard(
            text: "感谢观看",
            noSpeechProbability: 0.5,
            averageTokenProbability: 0.4
        ))
        XCTAssertTrue(WhisperOutputFilter.shouldDiscard(
            text: "uncertain output",
            noSpeechProbability: 0.4,
            averageTokenProbability: 0.1
        ))
        XCTAssertFalse(WhisperOutputFilter.shouldDiscard(
            text: "这是正常语音",
            noSpeechProbability: 0.1,
            averageTokenProbability: 0.7
        ))
    }

    func testTerminalThanksIsRemovedOnlyWhenItsAudioRegionIsSilent() {
        let normal = TranscriptSegment(startTime: 1, endTime: 4, text: "这是正常内容。")
        let thanks = TranscriptSegment(startTime: 20, endTime: 22, text: "谢谢大家。")

        let silentResult = WhisperOutputFilter.removingTerminalHallucinations(
            from: [normal, thanks],
            audioHasSpeech: { $0.id != thanks.id }
        )
        XCTAssertEqual(silentResult, [normal])

        let spokenResult = WhisperOutputFilter.removingTerminalHallucinations(
            from: [normal, thanks],
            audioHasSpeech: { _ in true }
        )
        XCTAssertEqual(spokenResult, [normal, thanks])
    }

    func testNormalTerminalTextIsNotRemovedEvenIfQuiet() {
        let segment = TranscriptSegment(startTime: 1, endTime: 3, text: "会议在星期五举行。")
        let result = WhisperOutputFilter.removingTerminalHallucinations(
            from: [segment],
            audioHasSpeech: { _ in false }
        )
        XCTAssertEqual(result, [segment])
    }

    func testLiveBufferWaitsForPauseInsteadOfFixedShortSlice() async {
        let buffer = WhisperLiveSampleBuffer()
        await buffer.append(Array(repeating: 0.05, count: WhisperAudio.sampleRate * 3))
        let continuous = await buffer.takeSpeechAwareChunk(
            minimumCount: WhisperAudio.sampleRate * 3,
            maximumCount: WhisperAudio.sampleRate * 12,
            trailingSilenceCount: WhisperAudio.sampleRate / 2
        )
        XCTAssertNil(continuous)

        await buffer.append(Array(repeating: 0, count: WhisperAudio.sampleRate * 3 / 5))
        let paused = await buffer.takeSpeechAwareChunk(
            minimumCount: WhisperAudio.sampleRate * 3,
            maximumCount: WhisperAudio.sampleRate * 12,
            trailingSilenceCount: WhisperAudio.sampleRate / 2
        )
        XCTAssertEqual(paused?.count, WhisperAudio.sampleRate * 18 / 5)
    }
}

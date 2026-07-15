import XCTest
@testable import LocalScribe

final class WhisperPipelineTests: XCTestCase {
    func testBundledVADModelIsPresentWithExpectedSize() throws {
        let url = try XCTUnwrap(WhisperVADResource.modelURL)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(size, 885_098)
    }

    func testAdaptiveVADOnlyAppliesToLongFormAudio() {
        XCTAssertFalse(WhisperVADResource.shouldUse(forSampleCount: WhisperAudio.sampleRate * 11))
        XCTAssertTrue(WhisperVADResource.shouldUse(forSampleCount: WhisperAudio.sampleRate * 12))
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

    func testHallucinatedIdenticalRunKeepsAtMostTwoSegments() {
        let segments = (0..<4).map {
            TranscriptSegment(startTime: Double($0), endTime: Double($0 + 1), text: "重复内容。")
        }
        XCTAssertEqual(WhisperOutputFilter.removingHallucinatedRuns(from: segments).count, 2)
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

    func testMicrophoneFilterRemovesKnownCreatorBoilerplate() {
        XCTAssertNil(MicrophoneTranscriptFilter.sanitizedStreamingText(
            "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"
        ))
    }

    func testMicrophoneFilterRemovesIsolatedTerminalThanksButPreservesSentence() {
        XCTAssertNil(MicrophoneTranscriptFilter.sanitizedStreamingText("谢谢大家。"))
        XCTAssertNil(MicrophoneTranscriptFilter.sanitizedStreamingText("Thank you!"))
        XCTAssertEqual(
            MicrophoneTranscriptFilter.sanitizedStreamingText("会议结束，谢谢大家。"),
            "会议结束，谢谢大家。"
        )
    }

    func testMicrophoneFilterCatchesBoilerplateSplitAcrossSegments() {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "正常内容"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "请不吝点赞 订阅 转发"),
            TranscriptSegment(startTime: 2, endTime: 3, text: "打赏支持明镜与点点栏目")
        ]
        XCTAssertEqual(MicrophoneTranscriptFilter.removingTerminalBoilerplate(from: segments), [segments[0]])
    }

    func testMicrophoneFilterDropsConsecutiveChunkDuplicate() {
        let previous = TranscriptSegment(startTime: 0, endTime: 3, text: "这是连续语音")
        let candidates = [
            TranscriptSegment(startTime: 3, endTime: 6, text: "这是连续语音。"),
            TranscriptSegment(startTime: 6, endTime: 9, text: "这是下一句话")
        ]
        XCTAssertEqual(
            MicrophoneTranscriptFilter.removingConsecutiveDuplicates(from: candidates, after: previous),
            [candidates[1]]
        )
    }

    func testStreamingPacingTracksPendingTextAndStaysBounded() {
        XCTAssertEqual(StreamingTextPacing.charactersPerSecond(pendingCount: 0, averageInterval: 1), 0)
        XCTAssertGreaterThan(StreamingTextPacing.charactersPerSecond(pendingCount: 30, averageInterval: 0.8), 30)
        XCTAssertLessThanOrEqual(StreamingTextPacing.charactersPerSecond(pendingCount: 1_000, averageInterval: 0.1), 110)
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

    @MainActor
    func testStreamingAnimatorRevealsIncrementallyAndCanFlush() async {
        var latest = ""
        let animator = AdaptiveStreamingTextAnimator { latest = $0 }
        let target = "这是一段用于验证逐字输出动画的较长测试文字。"
        animator.submit(target, animated: true)
        XCTAssertEqual(latest, "")

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(latest.isEmpty)
        XCTAssertLessThan(latest.count, target.count)

        animator.flush()
        XCTAssertEqual(latest, target)
    }
}

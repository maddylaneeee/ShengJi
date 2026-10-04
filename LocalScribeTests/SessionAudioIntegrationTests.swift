import AVFoundation
import XCTest
@testable import LocalScribe

final class SessionAudioIntegrationTests: XCTestCase {
    private func pcm(frames: UInt32 = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.08)) * 0.1 }
        return buffer
    }
    private func asset(id: UUID) async throws -> SessionAudioAsset {
        let recorder = try OriginalAudioRecorder(sessionID: id, quality: .quality) { _ in }
        recorder.accept(pcm())
        let result = await recorder.finish()
        return try XCTUnwrap(result)
    }
    private func synthesized(_ asset: SessionAudioAsset) -> SessionAudioAsset {
        SessionAudioAsset(id: asset.id, sessionID: asset.sessionID, relativePath: asset.relativePath, kind: .synthesis,
                          quality: asset.quality, duration: asset.duration, sampleRate: asset.sampleRate, channels: asset.channels,
                          frames: asset.frames, isPartial: asset.isPartial, fingerprint: asset.fingerprint, createdAt: asset.createdAt)
    }
    @MainActor private final class DelayedSynthesizer: SpeechSynthesizing {
        var continuation: CheckedContinuation<SessionAudioAsset, Error>?
        var wasCancelled = false
        func cancel() { wasCancelled = true }
        func generate(_ input: SynthesisInputSnapshot, sessionID: UUID, progress: @escaping (Double) -> Void) async throws -> SessionAudioAsset {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    @MainActor func testDisabledSynthesisCannotOverrideWithLegacyPreferencesOrInjectedService() async throws {
        let id = UUID(); defer { try? FileManager.default.removeItem(at: SessionAudioStore.directory(sessionID: id)) }
        let old = try await asset(id: id)
        let suite = "AudioIntegration.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "AllowAllSpeechSynthesis")
        let preferences = SpeechSynthesisPreferences(defaults: defaults)
        XCTAssertTrue(preferences.allowAll)
        var enumerations = 0
        let catalog = SpeechVoiceCatalog {
            enumerations += 1
            return [SpeechVoiceOption(id: "com.apple.siri.natural.Mock", name: "Mock", language: "en-US")]
        }
        let synth = DelayedSynthesizer()
        let model = SpeechAudioModel(sessionID: id, service: synth, catalog: catalog, preferences: preferences)
        model.restore(old)
        model.confirmedTextDigest = SynthesisInputSnapshot.digest("Nora")
        model.generate(model.input(text: "Nora"))
        await Task.yield()
        XCTAssertFalse(model.isGenerating)
        XCTAssertNil(synth.continuation)
        XCTAssertTrue(catalog.voices.isEmpty)
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(model.voiceIdentifier, "")
        XCTAssertEqual(model.asset, old)
        XCTAssertGreaterThan(model.player.duration, 0.9)
        XCTAssertNil(model.player.error)
        await model.cancelAndWait()
    }
    @MainActor func testSynthesizedAudioIsNotRestoredPlayedOrExportedAndFileIsRetained() async throws {
        let id = UUID(); defer { try? FileManager.default.removeItem(at: SessionAudioStore.directory(sessionID: id)) }
        let old = synthesized(try await asset(id: id))
        let originalURL = try SessionAudioStore.readableURL(old)
        try SessionAudioStore.save(old)
        let model = SpeechAudioModel(sessionID: id)
        model.restore(old)
        XCTAssertNil(model.asset)
        XCTAssertEqual(model.player.duration, 0)
        model.player.load(old)
        model.player.toggle()
        XCTAssertFalse(model.player.isPlaying)
        XCTAssertEqual(model.player.duration, 0)
        do {
            _ = try await CompanionExportCoordinator.export(data: Data("Text".utf8), format: .txt, name: "Text", asset: old, warning: "")
            XCTFail("Disabled synthesis export must be rejected before opening a save panel")
        } catch { if case SessionAudioError.synthesisUnavailable = error {} else { XCTFail("Unexpected error: \(error)") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }
    @MainActor func testOldSpeechRecoveryKeepsTextAndFilesWithoutWritingDuringLoad() async throws {
        let id = UUID(); defer { try? RecoveryStore.clear() }
        let audio = synthesized(try await asset(id: id))
        try SessionAudioStore.save(audio)
        let old = RecoverySnapshot(id: id, schemaVersion: 3, isTextToSpeech: true, audioAsset: audio,
                                   sourceTitle: "Speech", sourceKind: .recovered, localeIdentifier: "en", configuration: .init(engine: .apple),
                                   transcriptText: "Keep this old text", translatedText: "Preserve the translation too", segments: [], hasManualEdits: true,
                                   elapsed: 1, progress: 1, createdAt: Date(), updatedAt: Date().addingTimeInterval(10))
        try RecoveryStore.save(old)
        let recoveryURL = LocalScribePaths.applicationSupportDirectory.appendingPathComponent("声迹/Recovery/latest.json")
        let before = try Data(contentsOf: recoveryURL)
        let recovered = try XCTUnwrap(RecoveryStore.load())
        XCTAssertEqual(recovered.id, old.id)
        XCTAssertEqual(recovered.transcriptText, old.transcriptText)
        XCTAssertEqual(recovered.translatedText, old.translatedText)
        XCTAssertEqual(recovered.isTextToSpeech, false)
        XCTAssertNil(recovered.audioAsset)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), before)
        let model = TranscriptionSessionModel(snapshot: old)
        XCTAssertEqual(model.transcriptText, old.transcriptText)
        XCTAssertNil(model.audioAsset)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try SessionAudioStore.readableURL(audio).path))
        model.releaseAudioSession()
    }
    func testRecorderQueueFailureDoesNotStopRecognitionConsumer() async throws {
        let id = UUID(); defer { try? FileManager.default.removeItem(at: SessionAudioStore.directory(sessionID: id)) }
        let failure = expectation(description: "Raw recording reports its own failure")
        let recorder = try OriginalAudioRecorder(sessionID: id, quality: .quality, maximumPendingBytes: 1) { _ in failure.fulfill() }
        let gate = RealtimeAudioCaptureCallbackGate(), captureID = UUID()
        let recognized = expectation(description: "Recognition still receives audio")
        let pair = AsyncThrowingStream<Void, Error>.makeStream()
        gate.activate(sessionID: captureID, onBuffer: { _ in recognized.fulfill() }, onError: { _ in XCTFail("Saving must not fail recognition") }, firstBufferContinuation: pair.continuation)
        let buffer = pcm()
        gate.forwardOriginal(buffer, sessionID: captureID) { recorder.accept($0) }
        gate.accept(buffer: buffer, sessionID: captureID)
        await fulfillment(of: [failure, recognized], timeout: 2)
        gate.invalidate(sessionID: captureID)
        let none = await recorder.finish(); XCTAssertNil(none)
    }
    @MainActor func testRecoveryCompatibilityAndLateSaveCannotResurrectClearedAssets() async throws {
        let id = UUID(), old = try await asset(id: id)
        let snapshot = RecoverySnapshot(id: id, schemaVersion: 3, isTextToSpeech: false, audioAsset: old, timelineProvenance: .estimated,
                                        sourceTitle: "Text", sourceKind: .recovered, localeIdentifier: "en", configuration: .init(engine: .apple),
                                        transcriptText: "My saved text", segments: [], hasManualEdits: true, elapsed: 1, progress: 1, createdAt: Date(), updatedAt: Date().addingTimeInterval(10))
        let writer = RecoverySnapshotWriter(); await writer.save(snapshot)
        let restored = try XCTUnwrap(RecoveryStore.load())
        XCTAssertEqual(restored.audioAsset, old); XCTAssertEqual(restored.isTextToSpeech, false)
        let lease = SessionAudioLease(id)
        try RecoveryStore.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionAudioStore.directory(sessionID: id).path))
        await writer.save(snapshot)
        XCTAssertNil(RecoveryStore.load())
        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionAudioStore.directory(sessionID: id).path))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["isTextToSpeech", "audioAsset", "originalAudioEnabled", "timelineProvenance"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.audioAsset); XCTAssertNil(legacy.isTextToSpeech)
    }
    // Optional, expensive device-independent validation; enabled explicitly for the local validation run.
    func testOneHourRecordingPipelineWithBoundedMemory() async throws {
        guard ProcessInfo.processInfo.environment["LOCALSCRIBE_LONG_AUDIO_TESTS"] == "1" else { throw XCTSkip("Enable LOCALSCRIBE_LONG_AUDIO_TESTS for the one-hour signal fixture") }
        let id = UUID(); defer { try? FileManager.default.removeItem(at: SessionAudioStore.directory(sessionID: id)) }
        let recorder = try OriginalAudioRecorder(sessionID: id, quality: .quality) { message in XCTFail(message) }
        let tenSeconds = pcm(frames: 480_000)
        for _ in 0..<120 {
            for _ in 0..<3 { recorder.accept(tenSeconds) }
            await recorder.pauseBoundary()
        }
        let finished = await recorder.finish(), result = try XCTUnwrap(finished)
        XCTAssertFalse(result.isPartial); XCTAssertEqual(result.frames, 172_800_000)
        XCTAssertEqual(result.duration, 3_600, accuracy: 0.2)
        print("ONE_HOUR_AUDIO frames=\(result.frames) duration=\(result.duration)")
    }
    @MainActor func testDisabledSpeechServiceRejectsBeforeCreatingFiles() async throws {
        let suite = "AudioVoices.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = SpeechSynthesisPreferences(defaults: defaults); prefs.allowAll = true
        let service = SpeechSynthesisService(preferences: prefs)
        let id = UUID(), directory = SessionAudioStore.directory(sessionID: id)
        let input = SynthesisInputSnapshot(text: "The entire speech feature is disabled.", isTranslation: false,
                                          voiceIdentifier: "com.apple.voice.compact.en-US.Samantha", quality: .quality, usesTimeline: false, segments: [])
        do {
            _ = try await service.generate(input, sessionID: id) { _ in XCTFail("No synthesis progress is allowed") }
            XCTFail("TTS must be disabled even with allowAll true")
        } catch { if case SessionAudioError.synthesisUnavailable = error {} else { XCTFail("Unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

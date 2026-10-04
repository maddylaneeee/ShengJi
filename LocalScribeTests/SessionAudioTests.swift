import AVFoundation
import XCTest
@testable import LocalScribe

final class SessionAudioTests: XCTestCase {
    private func signal(channels: UInt32 = 1, frames: UInt32 = 4_800, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: channels == 4 ? kAudioChannelLayoutTag_Quadraphonic : (channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.1)) * Float(c + 1) * 0.1 } }
        return buffer
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pcmFile(_ buffer: AVAudioPCMBuffer, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).caf")
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file!.write(from: buffer); file = nil
        return url
    }
    func testVoicePolicyUsesIdentifierAndLanguageTogether() {
        XCTAssertTrue(SpeechVoiceOption.isAllowed(identifier: "com.apple.siri.natural.FutureEnglish", language: "en-GB", allowAll: false))
        XCTAssertFalse(SpeechVoiceOption.isAllowed(identifier: "com.apple.siri.natural.Linfei", language: "zh-CN", allowAll: false))
        XCTAssertFalse(SpeechVoiceOption.isAllowed(identifier: "com.apple.voice.enhanced.en-US.Alex", language: "en-US", allowAll: false))
        XCTAssertTrue(SpeechVoiceOption.isAllowed(identifier: "any", language: "zh-CN", allowAll: true))
    }
    @MainActor func testEntryPolicyAndPreferencePersistence() throws {
        for language in ["en", "zh-Hans", "ja"] {
            XCTAssertFalse(SpeechVoiceCatalog.independentEntryAllowed(allowAll: false, effectiveLanguage: language, hasVoices: true))
            XCTAssertFalse(SpeechVoiceCatalog.independentEntryAllowed(allowAll: true, effectiveLanguage: language, hasVoices: true))
        }
        XCTAssertFalse(SpeechVoiceCatalog.independentEntryAllowed(allowAll: true, effectiveLanguage: "en", hasVoices: false))
        let suite = "SpeechTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = SpeechSynthesisPreferences(defaults: defaults)
        XCTAssertFalse(prefs.allowAll)
        prefs.allowAll = true; prefs.lastVoiceIdentifier = "voice.id"
        let restored = SpeechSynthesisPreferences(defaults: defaults)
        XCTAssertTrue(restored.allowAll); XCTAssertEqual(restored.lastVoiceIdentifier, "voice.id")
    }
    func testLanguageDetectionDoesNotUseImportLanguageWhitelist() {
        XCTAssertEqual(SpeechTextLanguage.detect("This is a complete English paragraph about writing and reading on this computer."), .english)
        if case .other = SpeechTextLanguage.detect("这是一段完整的中文正文，用来确认其他语言不能被误认为英语。我们希望在本机生成声音。") {} else { XCTFail("Chinese must be non-English") }
        if case .other = SpeechTextLanguage.detect("Questo è un testo italiano completo che descrive il lavoro e la vita quotidiana delle persone.") {} else { XCTFail("Italian is outside the old import whitelist but remains non-English") }
        XCTAssertEqual(SpeechTextLanguage.detect("123 / Nora"), .uncertain)
        XCTAssertEqual(SpeechTextLanguage.detect("This is a clear English paragraph about writing and reading. 这是一段完整的中文正文，用来确认多语言混合不会被认为是纯英语。"), .uncertain)
        XCTAssertFalse(SpeechTextLanguage.uncertain.permits(allowAll: false, englishConfirmed: false))
        XCTAssertTrue(SpeechTextLanguage.uncertain.permits(allowAll: false, englishConfirmed: true))
        XCTAssertFalse(SpeechTextLanguage.other("zh").permits(allowAll: false, englishConfirmed: true))
    }
    func testLongChunkingPreservesEveryCharacter() {
        let text = String(repeating: "This paragraph must be spoken completely.\n", count: 1_000) + "Final unique sentence."
        let chunks = SpeechSynthesisService.chunks(text)
        XCTAssertGreaterThan(text.count, 20_000)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertLessThanOrEqual(chunks.map(\.count).max()!, 800)
    }
    func testTimelineRequiresCoverageProvenanceAndOrderedTimes() {
        let values = [TranscriptSegment(startTime: 1, endTime: 4, text: "One"), TranscriptSegment(startTime: 2, endTime: 3, text: "Two")]
        XCTAssertTrue(AudioTimeline.isReliable(text: "One\nTwo", segments: values, provenance: .subtitles))
        XCTAssertFalse(AudioTimeline.isReliable(text: "One\nTwo", segments: values, provenance: .estimated))
        XCTAssertFalse(AudioTimeline.isReliable(text: "Edited text", segments: values, provenance: .subtitles))
        XCTAssertFalse(AudioTimeline.isReliable(text: "Two\nOne", segments: values.reversed(), provenance: .subtitles))
        XCTAssertFalse(AudioTimeline.isReliable(text: "One", segments: [TranscriptSegment(startTime: .nan, endTime: 2, text: "One")], provenance: .json))
    }
    func testSubtitleAndPlainTextProvenanceSurvivesJSON() throws {
        let text = try TranscriptImporter.parse(data: Data("A complete English paragraph for reading.".utf8), fileName: "input.txt")
        XCTAssertEqual(text.timelineProvenance, .estimated)
        let json = try TranscriptExporter.makeData(format: .json, title: "Title", source: "Text", language: "en", duration: text.duration, text: text.text, segments: text.segments, hasManualEdits: true)
        let restored = try TranscriptImporter.parse(data: json, fileName: "input.json")
        XCTAssertEqual(restored.timelineProvenance, .estimated)
        let subtitle = try TranscriptImporter.parse(data: Data("1\n00:00:01,000 --> 00:00:02,000\nHello world.\n".utf8), fileName: "input.srt")
        XCTAssertEqual(subtitle.timelineProvenance, .subtitles)
        XCTAssertTrue(AudioTimeline.isReliable(text: subtitle.text, segments: subtitle.segments, provenance: subtitle.timelineProvenance))
    }
    func testFingerprintIncludesSettingsAndTranslationIdentity() {
        let base = SynthesisInputSnapshot(text: "Hello", isTranslation: false, voiceIdentifier: "Nora", quality: .quality, usesTimeline: false, segments: [])
        let changed = [SynthesisInputSnapshot(text: "Hello", isTranslation: true, voiceIdentifier: "Nora", quality: .quality, usesTimeline: false, segments: []),
                       SynthesisInputSnapshot(text: "Hello", isTranslation: false, voiceIdentifier: "Simone", quality: .quality, usesTimeline: false, segments: []),
                       SynthesisInputSnapshot(text: "Hello", isTranslation: false, voiceIdentifier: "Nora", quality: .lossless, usesTimeline: false, segments: [])]
        for value in changed { XCTAssertNotEqual(value.fingerprint, base.fingerprint) }
    }
    func testAllQualityFormatsReadBackWithCorrectChannelsAndFrames() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        for channels: UInt32 in [1, 2, 4] {
            let input = try pcmFile(signal(channels: channels, frames: 48_000), directory: dir)
            for quality in AudioQualityProfile.allCases {
                let output = dir.appendingPathComponent("\(channels)-\(quality.rawValue).m4a")
                let result = try SessionAudioEncoder.encode(inputs: [input], output: output, quality: quality)
                let read = try AVAudioFile(forReading: output)
                XCTAssertEqual(read.fileFormat.channelCount, quality.channels(for: channels))
                XCTAssertEqual(read.fileFormat.streamDescription.pointee.mFormatID, quality == .lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC)
                XCTAssertEqual(result.frames, 48_000)
                XCTAssertEqual(result.rate, 48_000)
            }
        }
    }
    func testALACRoundTripAndPauseConcatenationPreserveSignal() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = signal(frames: 48_000)
        let one = try pcmFile(source, directory: dir)
        let output = dir.appendingPathComponent("joined.m4a")
        let result = try SessionAudioEncoder.encode(inputs: [one, one], output: output, quality: .lossless)
        XCTAssertEqual(result.frames, 96_000)
        let reader = try AVAudioFile(forReading: output)
        let read = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 96_000)!
        try reader.read(into: read)
        for i in stride(from: 0, to: 48_000, by: 101) {
            XCTAssertEqual(read.floatChannelData![0][i], source.floatChannelData![0][i], accuracy: 0.000_001)
            XCTAssertEqual(read.floatChannelData![0][i + 48_000], source.floatChannelData![0][i], accuracy: 0.000_001)
        }
    }
    func testAdaptiveEncodingAcrossMicrophoneAndCompactVoiceFormats() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        for rate in [8_000.0, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 96_000] {
            for channels: UInt32 in [1, 2, 4] {
                let input = try pcmFile(signal(channels: channels, frames: UInt32(rate), rate: rate), directory: dir)
                for quality in AudioQualityProfile.allCases {
                    print("ADAPTIVE_ENCODING rate=\(rate) channels=\(channels) quality=\(quality)")
                    let output = dir.appendingPathComponent("\(rate)-\(channels)-\(quality).m4a")
                    let result = try SessionAudioEncoder.encode(inputs: [input, input], output: output, quality: quality)
                    XCTAssertEqual(Double(result.frames) / result.rate, 2, accuracy: 0.001, "\(rate)/\(channels)/\(quality)")
                    XCTAssertEqual(result.sourceRate, rate); XCTAssertEqual(result.sourceChannels, channels)
                    XCTAssertEqual(result.channels, quality.channels(for: channels))
                    if quality == .lossless { XCTAssertEqual(result.rate, rate); XCTAssertEqual(result.frames, Int64(rate * 2)) }
                    let read = try AVAudioFile(forReading: output)
                    XCTAssertEqual(read.fileFormat.streamDescription.pointee.mFormatID, quality == .lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC)
                }
            }
        }
    }
    func testEncodingCancellationRemovesHalfFinishedOutput() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try pcmFile(signal(), directory: dir), output = dir.appendingPathComponent("cancel.m4a")
        XCTAssertThrowsError(try SessionAudioEncoder.encode(inputs: [source], output: output, quality: .quality, cancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRawBufferCopyOwnsStorage() throws {
        let original = signal(), copy = try XCTUnwrap(OriginalAudioRecorder.copy(original))
        let before = copy.floatChannelData![0][100]
        original.floatChannelData![0][100] = 0
        XCTAssertEqual(copy.floatChannelData![0][100], before)
    }
    func testRecorderPauseFinishAndCheckpointRecovery() async throws {
        let id = UUID(), root = SessionAudioStore.directory(sessionID: id)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try OriginalAudioRecorder(sessionID: id, quality: .quality) { _ in XCTFail("Unexpected recorder failure") }
        recorder.accept(signal(frames: 48_000))
        await recorder.pauseBoundary()
        let recovered = try XCTUnwrap(SessionAudioEncoder.recoverOriginal(sessionID: id))
        XCTAssertTrue(recovered.isPartial); XCTAssertEqual(recovered.frames, 48_000)
        recorder.accept(signal(frames: 48_000))
        let finished = await recorder.finish()
        let asset = try XCTUnwrap(finished)
        XCTAssertFalse(asset.isPartial); XCTAssertEqual(asset.frames, 96_000)
        let again = await recorder.finish()
        XCTAssertEqual(again, asset)
        recorder.accept(signal()) // Finished recorders cannot append to a published asset.
        XCTAssertEqual(try AVAudioFile(forReading: SessionAudioStore.readableURL(asset)).length, 96_000)
    }
    func testRecorderFormatFailurePreservesPartialAudio() async throws {
        let id = UUID(); defer { try? FileManager.default.removeItem(at: SessionAudioStore.directory(sessionID: id)) }
        let recorder = try OriginalAudioRecorder(sessionID: id, quality: .lossless) { _ in }
        recorder.accept(signal(channels: 1, frames: 48_000)); await recorder.pauseBoundary()
        recorder.accept(signal(channels: 2)); await recorder.pauseBoundary()
        let finished = await recorder.finish()
        let asset = try XCTUnwrap(finished)
        XCTAssertTrue(asset.isPartial); XCTAssertEqual(asset.frames, 48_000)
    }
    func testTimelineAudioContainsSilenceAndDelaysOverlapsWithoutCuttingTail() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("timeline.caf"), assembler = AudioTimelineAssembler(url: url)
        try await assembler.append(signal(frames: 48_000), scheduledStart: 0.5)
        try await assembler.append(signal(frames: 48_000), scheduledStart: 0.6)
        try await assembler.finish(tail: 2)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 120_000) // .5 seconds opening silence + two complete 1-second utterances.
        let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 120_000)!
        try file.read(into: b)
        XCTAssertEqual(b.floatChannelData![0][12_000], 0)
        XCTAssertNotEqual(b.floatChannelData![0][24_100], 0)
        XCTAssertNotEqual(b.floatChannelData![0][72_100], 0)
    }
    func testAssetPathRejectsTraversalAbsoluteAndSymlinkEscapes() throws {
        let id = UUID(), dir = SessionAudioStore.directory(sessionID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["../secret.m4a", "/tmp/a.m4a", "sub/../../a", "a//b"] { XCTAssertThrowsError(try SessionAudioStore.resolve(sessionID: id, relativePath: path)) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try SessionAudioStore.resolve(sessionID: id, relativePath: "escape/audio.m4a"))
    }
    func testAllTextFormatsExportWithSameAudioBaseName() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try pcmFile(signal(), directory: dir)
        for format in TranscriptExportFormat.allCases {
            let result = try CompanionExportCoordinator.write(data: Data("Text".utf8), format: format, name: "Meeting", directory: dir, audio: source, overwrite: true)
            XCTAssertEqual(result.textURL.lastPathComponent, "Meeting." + format.fileExtension)
            XCTAssertEqual(result.audioURL?.lastPathComponent, "Meeting.m4a")
            XCTAssertTrue(result.isComplete)
        }
    }
    func testExportCollisionRequiresApprovalAndAudioFailureReportsTextSuccess() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try pcmFile(signal(), directory: dir), audio = dir.appendingPathComponent("Meeting.m4a")
        try Data("Old audio".utf8).write(to: audio)
        XCTAssertThrowsError(try CompanionExportCoordinator.write(data: Data("New text".utf8), format: .srt, name: "Meeting", directory: dir, audio: source, overwrite: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Meeting.srt").path))
        let result = try CompanionExportCoordinator.write(data: Data("New text".utf8), format: .srt, name: "Meeting", directory: dir, audio: source, overwrite: true, copyAudio: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(result.isComplete); XCTAssertNotNil(result.audioError)
        XCTAssertEqual(try String(contentsOf: result.textURL, encoding: .utf8), "New text")
        XCTAssertEqual(try String(contentsOf: audio, encoding: .utf8), "Old audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testFileNamesRejectPathInjectionAndStripOnlyTextExtension() throws {
        XCTAssertEqual(try CompanionExportCoordinator.baseName("Meeting.srt", format: .srt), "Meeting")
        for name in ["../a", "a/b", "a:b", "..", " ", "a\\b"] { XCTAssertThrowsError(try CompanionExportCoordinator.baseName(name, format: .txt)) }
    }
    @MainActor func testOriginalAudioScopeAndNewTaskDefaults() async {
        let mic = TranscriptionSessionModel(source: .microphone, locale: Locale(identifier: "en"), configuration: .init(engine: .apple))
        XCTAssertFalse(mic.saveOriginalAudio)
        mic.selectRealtimeAudioSource(.systemDefaultMicrophone)
        XCTAssertTrue(mic.canSaveOriginalAudio)
        mic.saveOriginalAudio = true; mic.selectRealtimeAudioSource(.systemAudio)
        XCTAssertFalse(mic.saveOriginalAudio); XCTAssertFalse(mic.canSaveOriginalAudio)
        let imported = ImportedTranscript(title: "Import", text: "Imported text", segments: [], duration: 1)
        let appended = TranscriptionSessionModel(imported: imported, continueWithMicrophone: true, locale: Locale(identifier: "en"), configuration: .init(engine: .apple))
        XCTAssertFalse(appended.canSaveOriginalAudio)
        await mic.cancel(); await appended.cancel()
        mic.releaseAudioSession(); appended.releaseAudioSession()
    }
}

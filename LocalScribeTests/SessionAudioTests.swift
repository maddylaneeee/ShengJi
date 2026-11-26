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
        // Cover codec resampling, mono/stereo, and multichannel preservation without a full cross product.
        let formats: [(Double, UInt32)] = [(8_000, 1), (24_000, 1), (44_100, 2), (48_000, 2), (96_000, 4)]
        for (rate, channels) in formats {
            let input = try pcmFile(signal(channels: channels, frames: UInt32(rate), rate: rate), directory: dir)
            for quality in AudioQualityProfile.allCases {
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
    func testAssetPathRejectsTraversalAbsoluteAndSymlinkEscapes() throws {
        let id = UUID(), dir = SessionAudioStore.directory(sessionID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["../secret.m4a", "/tmp/a.m4a", "sub/../../a", "a//b"] { XCTAssertThrowsError(try SessionAudioStore.resolve(sessionID: id, relativePath: path)) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try SessionAudioStore.resolve(sessionID: id, relativePath: "escape/audio.m4a"))
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

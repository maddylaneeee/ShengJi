import AVFoundation
import Foundation

private struct SpeechPCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer; let bytes: Int }

/// Offline synthesis can run faster than disk writes. A detached consumer drains the bounded
/// queue while its producer waits; neither the main actor nor microphone capture drains it.
private final class SpeechBufferBridge: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let stream: AsyncThrowingStream<SpeechPCM, Error>
    private let continuation: AsyncThrowingStream<SpeechPCM, Error>.Continuation
    private let condition = NSCondition()
    private var pendingCount = 0
    private var pendingBytes = 0
    private let maximumBytes = 8 * 1_024 * 1_024
    private var lastBuffer = Date()
    private var ended = false
    override init() {
        let pair = AsyncThrowingStream<SpeechPCM, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream; continuation = pair.continuation
        super.init()
    }
    func accept(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { finish(SessionAudioError.invalidFormat); return }
        if pcm.frameLength == 0 { finish(nil); return }
        let bytes = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        guard bytes > 0, bytes <= maximumBytes else { finish(SessionAudioError.queueOverflow); return }
        condition.lock()
        while !ended && (pendingCount >= 32 || pendingBytes + bytes > maximumBytes) { condition.wait() }
        guard !ended else { condition.unlock(); return }
        pendingCount += 1; pendingBytes += bytes; lastBuffer = Date()
        condition.unlock()
        guard let copy = OriginalAudioRecorder.copy(pcm) else {
            consumed(bytes: bytes); finish(SessionAudioError.invalidFormat); return
        }
        switch continuation.yield(SpeechPCM(buffer: copy, bytes: bytes)) {
        case .enqueued: break
        case .dropped: consumed(bytes: bytes); finish(SessionAudioError.queueOverflow)
        case .terminated: consumed(bytes: bytes)
        @unknown default: consumed(bytes: bytes); finish(SessionAudioError.queueOverflow)
        }
    }
    func consumed(bytes: Int) {
        condition.lock()
        pendingCount -= 1; pendingBytes -= bytes
        condition.broadcast(); condition.unlock()
    }
    func finish(_ error: Error?) {
        condition.lock()
        guard !ended else { condition.unlock(); return }
        ended = true; condition.broadcast(); condition.unlock()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
    func timedOut() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !ended && Date().timeIntervalSince(lastBuffer) > 30
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(CancellationError()) }
}

actor AudioTimelineAssembler {
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private(set) var frames: Int64 = 0
    private var hasSound = false
    private let url: URL
    init(url: URL) { self.url = url }
    func append(_ buffer: AVAudioPCMBuffer, scheduledStart: Double?) throws {
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            format = buffer.format
        }
        guard let format, buffer.format == format, let file else { throw SessionAudioError.formatChanged }
        if let start = scheduledStart { try silence(until: AudioTimeline.framePosition(time: start, sampleRate: format.sampleRate)) }
        try file.write(from: buffer)
        frames += Int64(buffer.frameLength)
        if let data = buffer.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) where abs(data[c][i]) > 0.000_001 { hasSound = true; break }
            }
        } else if AudioLevelEstimator.normalizedLevel(from: buffer) > 0 { hasSound = true }
    }
    private func silence(until target: Int64) throws {
        guard let format, let file, target > frames else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw SessionAudioError.invalidFormat }
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
        while frames < target {
            try Task.checkCancellation()
            buffer.frameLength = AVAudioFrameCount(min(8_192, target - frames))
            try file.write(from: buffer)
            frames += Int64(buffer.frameLength)
        }
    }
    func finish(tail: Double?) throws {
        if let tail, let format { try silence(until: AudioTimeline.framePosition(time: tail, sampleRate: format.sampleRate)) }
        file = nil
        guard frames > 0, hasSound else { throw SessionAudioError.silentOutput }
    }
    func close() { file = nil }
}

@MainActor
protocol SpeechSynthesizing: AnyObject {
    func cancel()
    func generate(_ input: SynthesisInputSnapshot, sessionID: UUID, progress: @escaping (Double) -> Void) async throws -> SessionAudioAsset
}

@MainActor
final class SpeechSynthesisService: SpeechSynthesizing {
    private let preferences: SpeechSynthesisPreferences
    init(preferences: SpeechSynthesisPreferences? = nil) { self.preferences = preferences ?? .shared }
    private var synthesizer: AVSpeechSynthesizer?
    private var bridge: SpeechBufferBridge?
    func cancel() {
        bridge?.finish(CancellationError())
        synthesizer?.stopSpeaking(at: .immediate)
    }
    nonisolated static func chunks(_ text: String, limit: Int = 800) -> [String] {
        var result: [String] = [], current = ""
        for character in text {
            current.append(character)
            if current.count >= limit || (current.count >= 200 && ".!?。！？\n".contains(character)) {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    func generate(_ input: SynthesisInputSnapshot, sessionID: UUID, progress: @escaping (Double) -> Void) async throws -> SessionAudioAsset {
        guard SessionAudioFeatures.speechSynthesisEnabled else { throw SessionAudioError.synthesisUnavailable }
        guard let voice = AVSpeechSynthesisVoice(identifier: input.voiceIdentifier),
              SpeechVoiceOption.isAllowed(identifier: voice.identifier, language: voice.language, allowAll: preferences.allowAll),
              !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionAudioError.synthesisUnavailable }
        let directory = SessionAudioStore.directory(sessionID: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("synthesis-\(UUID().uuidString).caf")
        let name = "speech-\(UUID().uuidString).m4a"
        let output = directory.appendingPathComponent(name)
        let assembler = AudioTimelineAssembler(url: temporary)
        let pieces: [(String, Double?)] = input.usesTimeline
            ? input.segments.flatMap { segment in Self.chunks(segment.text).enumerated().map { ($0.element, $0.offset == 0 ? segment.startTime : nil) } }
            : Self.chunks(input.text).map { ($0, nil) }
        var completed = 0
        do {
            for (text, start) in pieces {
                try Task.checkCancellation()
                let synth = AVSpeechSynthesizer()
                let bridge = SpeechBufferBridge()
                self.synthesizer = synth; self.bridge = bridge
                synth.delegate = bridge
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = voice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.pitchMultiplier = 1
                let watchdog = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if bridge.timedOut() { bridge.finish(SessionAudioError.synthesisTimedOut); return }
                    }
                }
                // Start before write(), which is allowed to deliver callbacks synchronously.
                // Waiting producers must always have a consumer independent of the main actor.
                let consumer = Task.detached(priority: .utility) {
                    var first = true
                    do {
                        for try await pcm in bridge.stream {
                            defer { bridge.consumed(bytes: pcm.bytes) }
                            try Task.checkCancellation()
                            try await assembler.append(pcm.buffer, scheduledStart: first ? start : nil)
                            first = false
                        }
                        return !first
                    } catch { bridge.finish(error); throw error }
                }
                synth.write(utterance) { bridge.accept($0) }
                do {
                    let receivedAudio = try await withTaskCancellationHandler {
                        try await consumer.value
                    } onCancel: { bridge.finish(CancellationError()); consumer.cancel() }
                    if !receivedAudio { throw SessionAudioError.noAudio }
                } catch { watchdog.cancel(); synth.stopSpeaking(at: .immediate); throw error }
                watchdog.cancel()
                synth.stopSpeaking(at: .immediate)
                self.synthesizer = nil; self.bridge = nil
                completed += text.count
                progress(min(0.95, Double(completed) / Double(max(1, input.text.count)) * 0.95))
            }
            try await assembler.finish(tail: input.usesTimeline ? input.segments.map(\.endTime).max() : nil)
            try Task.checkCancellation()
            let encoding = Task.detached(priority: .utility) {
                try SessionAudioEncoder.encode(inputs: [temporary], output: output, quality: input.quality, cancelled: { Task.isCancelled })
            }
            let result = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
            try Task.checkCancellation()
            let asset = SessionAudioAsset(id: UUID(), sessionID: sessionID, relativePath: name, kind: .synthesis, quality: input.quality,
                                          duration: Double(result.frames) / result.rate, sampleRate: result.rate, channels: result.channels,
                                          frames: result.frames, isPartial: false, fingerprint: input.fingerprint, createdAt: Date(), sourceSampleRate: result.sourceRate, sourceChannels: result.sourceChannels)
            try? FileManager.default.removeItem(at: temporary)
            progress(1)
            return asset
        } catch {
            cancel()
            await assembler.close()
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

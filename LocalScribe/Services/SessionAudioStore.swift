import AVFoundation
import Foundation

/// Internal assets never carry an absolute user-controlled path.
enum SessionAudioStore {
    private static let lock = NSLock()
    private static var leases: [UUID: Int] = [:]
    private static var retired: Set<UUID> = []
    static func directory(sessionID: UUID) -> URL {
        LocalScribePaths.applicationSupportDirectory.appendingPathComponent("声迹/Sessions/\(sessionID.uuidString)/Audio", isDirectory: true)
    }
    static func resolve(sessionID: UUID, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw SessionAudioError.invalidPath }
        let root = directory(sessionID: sessionID).resolvingSymlinksInPath().standardizedFileURL
        var candidate = root
        for component in relativePath.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            // Foundation leaves unresolved components when the final leaf does not exist.
            // Reject every symlink component before resolving, including a missing leaf below one.
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw SessionAudioError.invalidPath }
        }
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw SessionAudioError.invalidPath }
        return url
    }
    static func readableURL(_ asset: SessionAudioAsset) throws -> URL {
        let url = try resolve(sessionID: asset.sessionID, relativePath: asset.relativePath)
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw SessionAudioError.noAudio }
        return url
    }
    static func retain(_ id: UUID) { lock.withLock { leases[id, default: 0] += 1 } }
    static func release(_ id: UUID) {
        lock.withLock {
            leases[id] = max(0, (leases[id] ?? 1) - 1)
            collectLocked()
        }
    }
    static func retire(_ id: UUID) { lock.withLock { _ = retired.insert(id); collectLocked() } }
    private static func collectLocked() {
        let current = RecoveryStore.load()?.id
        for id in Array(retired) where leases[id, default: 0] == 0 && current != id {
            try? FileManager.default.removeItem(at: directory(sessionID: id))
            retired.remove(id)
        }
    }
    static func save(_ asset: SessionAudioAsset) throws {
        let dir = directory(sessionID: asset.sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(asset).write(to: dir.appendingPathComponent("asset.json"), options: .atomic)
    }
    static func load(sessionID: UUID) -> SessionAudioAsset? {
        let url = directory(sessionID: sessionID).appendingPathComponent("asset.json")
        guard let data = try? Data(contentsOf: url), let asset = try? JSONDecoder().decode(SessionAudioAsset.self, from: data), asset.sessionID == sessionID else { return nil }
        return asset
    }
}

struct AudioRecordingCheckpoint: Codable, Sendable {
    var chunks: [String] = []
    let quality: AudioQualityProfile
    let sessionID: UUID
}

/// Reads small PCM blocks and encodes exactly once; no AAC re-encoding or M4A byte concatenation.
enum SessionAudioEncoder {
    static func encode(inputs: [URL], output: URL, quality: AudioQualityProfile, cancelled: @Sendable () -> Bool = { false }) throws -> (frames: Int64, rate: Double, channels: UInt32, sourceRate: Double, sourceChannels: UInt32) {
        guard let first = inputs.first else { throw SessionAudioError.noAudio }
        let inputFormat = try AVAudioFile(forReading: first).processingFormat
        let channels = quality.channels(for: inputFormat.channelCount)
        // Float PCM has no more than 24 significant bits; ALAC uses 24-bit integers,
        // clips outside [-1,1], and uses the system converter's quantization. No upsampling.
        let fileFormat = try AVAudioFile(forReading: first).fileFormat
        let bitDepth = min(24, (fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 24)
        // AAC-LC uses a supported output rate; ALAC retains high-rate device PCM.
        let encodingRate = quality == .lossless ? inputFormat.sampleRate : min(inputFormat.sampleRate, 48_000)
        var writer: AVAudioFile?
        do {
            writer = try AVAudioFile(forWriting: output, settings: quality.settings(sampleRate: encodingRate, channels: channels, bitDepth: bitDepth))
        } catch {
            let encoderError = error as NSError
            guard quality != .lossless, encodingRate < 48_000,
                  (encoderError.userInfo["failed call"] as? String)?.contains("kAudioConverterEncodeBitRate") == true else {
                try? FileManager.default.removeItem(at: output)
                throw SessionAudioError.encodingFailed(rate: inputFormat.sampleRate, channels: channels, reason: error.localizedDescription)
            }
            // Some compact voices supply 22.05 kHz, which cannot encode 96 kbps AAC.
            // Keep the chosen codec/bitrate; rate conversion is internal metadata only.
            try? FileManager.default.removeItem(at: output)
            do { writer = try AVAudioFile(forWriting: output, settings: quality.settings(sampleRate: 48_000, channels: channels, bitDepth: bitDepth)) }
            catch { throw SessionAudioError.encodingFailed(rate: 48_000, channels: channels, reason: error.localizedDescription) }
        }
        let target = writer!.processingFormat
        do {
            if target.sampleRate != inputFormat.sampleRate {
                try resample(inputs: inputs, inputFormat: inputFormat, writer: writer!, cancelled: cancelled)
            } else {
            for url in inputs {
                let reader = try AVAudioFile(forReading: url)
                guard reader.processingFormat == inputFormat else { throw SessionAudioError.formatChanged }
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192) else { throw SessionAudioError.invalidFormat }
                let converter = inputFormat == target ? nil : AVAudioConverter(from: inputFormat, to: target)
                if inputFormat != target && converter == nil { throw SessionAudioError.invalidFormat }
                while reader.framePosition < reader.length {
                    if cancelled() { throw CancellationError() }
                    try reader.read(into: input)
                    guard input.frameLength > 0 else { break }
                    let converted: AVAudioPCMBuffer
                    if let converter {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength) else { throw SessionAudioError.invalidFormat }
                        // Same-rate PCM channel conversion has no resampler tail to lose.
                        try converter.convert(to: buffer, from: input)
                        converted = buffer
                    } else { converted = input }
                    try writer!.write(from: converted)
                }
            }
            }
            writer = nil
            let verified = try AVAudioFile(forReading: output)
            guard verified.length > 0 else { throw SessionAudioError.noAudio }
            return (verified.length, target.sampleRate, channels, inputFormat.sampleRate, inputFormat.channelCount)
        } catch {
            writer = nil
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
    private static func resample(inputs: [URL], inputFormat: AVAudioFormat, writer: AVAudioFile, cancelled: @Sendable () -> Bool) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: writer.processingFormat),
              let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192),
              let destination = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 8_192) else { throw SessionAudioError.invalidFormat }
        var index = 0
        var reader: AVAudioFile?
        var readError: Error?
        // Treat closed checkpoints as one continuous input; drain the converter only at
        // the final EOF so resampling does not discard tails or pad each pause/chunk.
        while true {
            if cancelled() { throw CancellationError() }
            var conversionError: NSError?
            let status = converter.convert(to: destination, error: &conversionError) { frames, status in
                do {
                    while reader == nil || reader!.framePosition >= reader!.length {
                        guard index < inputs.count else { status.pointee = .endOfStream; return nil }
                        reader = try AVAudioFile(forReading: inputs[index]); index += 1
                        guard reader!.processingFormat == inputFormat else { throw SessionAudioError.formatChanged }
                    }
                    try reader!.read(into: source, frameCount: min(frames, source.frameCapacity))
                    status.pointee = .haveData
                    return source
                } catch { readError = error; status.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if destination.frameLength > 0 { try writer.write(from: destination) }
            switch status {
            case .endOfStream: return
            case .haveData, .inputRanDry: continue
            case .error: throw SessionAudioError.invalidFormat
            @unknown default: throw SessionAudioError.invalidFormat
            }
        }
    }
    static func recoverOriginal(sessionID: UUID) throws -> SessionAudioAsset? {
        if let asset = SessionAudioStore.load(sessionID: sessionID), (try? SessionAudioStore.readableURL(asset)) != nil { return asset }
        let root = SessionAudioStore.directory(sessionID: sessionID)
        let manifest = root.appendingPathComponent("recording.json")
        guard let data = try? Data(contentsOf: manifest), let checkpoint = try? JSONDecoder().decode(AudioRecordingCheckpoint.self, from: data), checkpoint.sessionID == sessionID, !checkpoint.chunks.isEmpty else { return nil }
        let inputs = try checkpoint.chunks.map { try SessionAudioStore.resolve(sessionID: sessionID, relativePath: $0) }
        let name = "recovered-\(UUID().uuidString).m4a"
        let result = try encode(inputs: inputs, output: root.appendingPathComponent(name), quality: checkpoint.quality)
        let asset = SessionAudioAsset(id: UUID(), sessionID: sessionID, relativePath: name, kind: .original, quality: checkpoint.quality,
                                      duration: Double(result.frames) / result.rate, sampleRate: result.rate, channels: result.channels,
                                      frames: result.frames, isPartial: true, fingerprint: nil, createdAt: Date(), sourceSampleRate: result.sourceRate, sourceChannels: result.sourceChannels)
        try SessionAudioStore.save(asset)
        return asset
    }
}

/// One idempotent lease per owner; deallocation cannot accidentally release an export's lease.
final class SessionAudioLease: @unchecked Sendable {
    private let id: UUID
    private let lock = NSLock()
    private var released = false
    init(_ id: UUID) { self.id = id; SessionAudioStore.retain(id) }
    func release() {
        lock.withLock {
            guard !released else { return }
            released = true; SessionAudioStore.release(id)
        }
    }
    deinit { release() }
}

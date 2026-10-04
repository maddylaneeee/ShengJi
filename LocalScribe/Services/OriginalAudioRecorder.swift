import AVFoundation
import Foundation

/// Capture callback does only a bounded buffer copy/enqueue. PCM checkpoints survive crashes;
/// compressed output is produced once after capture stops. The last open checkpoint may be lost.
final class OriginalAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ca.lixinchen.localscribe.original-audio", qos: .utility)
    private var pendingBytes = 0
    private let maximumPendingBytes: Int
    private var accepting = true
    private var failure: Error?
    private var writer: AVAudioFile?
    private var format: AVAudioFormat?
    private var framesInChunk: Int64 = 0
    private var openChunk: String?
    private var checkpoint: AudioRecordingCheckpoint
    private let directory: URL
    private let onFailure: @Sendable (String) -> Void
    private var finalAsset: SessionAudioAsset?
    init(sessionID: UUID, quality: AudioQualityProfile, maximumPendingBytes: Int = 8 * 1_024 * 1_024, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.maximumPendingBytes = maximumPendingBytes
        checkpoint = AudioRecordingCheckpoint(quality: quality, sessionID: sessionID)
        directory = SessionAudioStore.directory(sessionID: sessionID)
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func accept(_ buffer: AVAudioPCMBuffer) {
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).reduce(0) { $0 + Int($1.mDataByteSize) }
        let permitted = lock.withLock { () -> Bool in
            guard accepting, failure == nil else { return false }
            guard pendingBytes + bytes <= maximumPendingBytes else {
                failure = SessionAudioError.queueOverflow; accepting = false
                return false
            }
            pendingBytes += bytes
            return true
        }
        guard permitted else {
            if lock.withLock({ failure is SessionAudioError }) { notifyFailureOnce() }
            return
        }
        guard let copy = Self.copy(buffer) else {
            lock.withLock { pendingBytes -= bytes }
            report(SessionAudioError.invalidFormat)
            return
        }
        queue.async { [self] in
            defer { lock.withLock { pendingBytes -= bytes } }
            guard lock.withLock({ failure == nil }) else { return }
            do { try append(copy) } catch { report(error) }
        }
    }
    private var notified = false
    private func notifyFailureOnce() {
        let message = lock.withLock { () -> String? in
            guard !notified, let failure else { return nil }
            notified = true
            return failure.localizedDescription
        }
        if let message { onFailure(message) }
    }
    private func report(_ error: Error) {
        lock.withLock { if failure == nil { failure = error }; accepting = false }
        notifyFailureOnce()
    }
    private func append(_ buffer: AVAudioPCMBuffer) throws {
        if let format, format != buffer.format { throw SessionAudioError.formatChanged }
        format = buffer.format
        if writer == nil {
            let name = "checkpoint-\(UUID().uuidString).caf"
            writer = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: buffer.format.settings,
                                     commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            openChunk = name
            framesInChunk = 0
        }
        try writer!.write(from: buffer)
        framesInChunk += Int64(buffer.frameLength)
        if Double(framesInChunk) >= buffer.format.sampleRate * 30 { try closeChunk() }
    }
    private func closeChunk() throws {
        writer = nil
        guard let name = openChunk, framesInChunk > 0 else { openChunk = nil; return }
        openChunk = nil
        // Only advertise closed, readable checkpoints.
        _ = try AVAudioFile(forReading: directory.appendingPathComponent(name))
        checkpoint.chunks.append(name)
        try JSONEncoder().encode(checkpoint).write(to: directory.appendingPathComponent("recording.json"), options: .atomic)
    }
    func pauseBoundary() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { try closeChunk() } catch { report(error) }
                continuation.resume()
            }
        }
    }
    func finish() async -> SessionAudioAsset? {
        lock.withLock { accepting = false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let finalAsset { continuation.resume(returning: finalAsset); return }
                do {
                    do { try closeChunk() } catch { report(error) }
                    guard !checkpoint.chunks.isEmpty else { continuation.resume(returning: nil); return }
                    let name = "original-\(UUID().uuidString).m4a"
                    let inputs = checkpoint.chunks.map { directory.appendingPathComponent($0) }
                    let result = try SessionAudioEncoder.encode(inputs: inputs, output: directory.appendingPathComponent(name), quality: checkpoint.quality)
                    let asset = SessionAudioAsset(id: UUID(), sessionID: checkpoint.sessionID, relativePath: name, kind: .original, quality: checkpoint.quality,
                                                  duration: Double(result.frames) / result.rate, sampleRate: result.rate, channels: result.channels,
                                                  frames: result.frames, isPartial: lock.withLock { failure != nil }, fingerprint: nil, createdAt: Date(), sourceSampleRate: result.sourceRate, sourceChannels: result.sourceChannels)
                    try SessionAudioStore.save(asset)
                    finalAsset = asset
                    for url in inputs { try? FileManager.default.removeItem(at: url) }
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("recording.json"))
                    continuation.resume(returning: asset)
                } catch { report(error); continuation.resume(returning: nil) }
            }
        }
    }
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.frameLength <= buffer.frameCapacity,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for i in source.indices {
            guard let src = source[i].mData, let dst = target[i].mData, source[i].mDataByteSize <= target[i].mDataByteSize else { return nil }
            memcpy(dst, src, Int(source[i].mDataByteSize))
        }
        return copy
    }
}

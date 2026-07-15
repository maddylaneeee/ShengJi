import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class AnalyzerInputBridge: @unchecked Sendable {
    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init() {
        // Roughly two seconds of headroom prevents short analyzer stalls from
        // punching holes into microphone input without allowing unbounded growth.
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(48))
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func yield(_ input: AnalyzerInput) -> Bool {
        switch continuation.yield(input) {
        case .enqueued: true
        case .dropped, .terminated: false
        @unknown default: false
        }
    }

    func yieldWhenReady(_ input: AnalyzerInput) async {
        while !Task.isCancelled {
            switch continuation.yield(input) {
            case .enqueued:
                return
            case .dropped:
                try? await Task.sleep(for: .milliseconds(8))
            case .terminated:
                return
            @unknown default:
                return
            }
        }
    }

    func finish() {
        continuation.finish()
    }
}

actor PauseGate {
    private var isPaused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitIfNeeded() async {
        guard isPaused else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

enum AudioPipelineError: LocalizedError {
    case unsupportedMedia
    case noAudioTrack
    case cannotCreateExporter
    case exportFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: "无法读取这个文件的音频。"
        case .noAudioTrack: "所选文件中没有可转录的音轨。"
        case .cannotCreateExporter: "无法创建音轨分离任务。"
        case .exportFailed(let message): "分离音轨失败：\(message)"
        case .conversionFailed(let message): "音频格式转换失败：\(message)"
        }
    }
}

enum MediaAudioPreparer {
    static func prepare(_ sourceURL: URL) async throws -> (url: URL, isTemporary: Bool) {
        if (try? AVAudioFile(forReading: sourceURL)) != nil {
            return (sourceURL, false)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioPipelineError.noAudioTrack }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribe-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioPipelineError.cannotCreateExporter
        }

        try await exporter.export(to: outputURL, as: .m4a)
        return (outputURL, true)
    }
}

enum AudioFileFeeder {
    @available(macOS 26.0, *)
    static func feed(
        url: URL,
        targetFormat: AVAudioFormat,
        bridge: AnalyzerInputBridge,
        gate: PauseGate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let totalFrames = max(file.length, 1)
        let inputCapacity: AVAudioFrameCount = 4_096
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        let progressClock = ContinuousClock()
        var lastProgressUpdate = progressClock.now - .seconds(1)
        var lastReportedProgress = -1.0

        while !Task.isCancelled {
            await gate.waitIfNeeded()
            guard !Task.isCancelled else { break }
            let remainingFrames = file.length - file.framePosition
            guard remainingFrames > 0 else { break }
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remainingFrames))

            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
                throw AudioPipelineError.unsupportedMedia
            }
            try file.read(into: input, frameCount: framesToRead)
            guard input.frameLength > 0 else { break }

            let output: AVAudioPCMBuffer
            if sourceFormat == targetFormat {
                output = input
            } else {
                guard let converter else { throw AudioPipelineError.unsupportedMedia }
                output = try convert(input, using: converter, to: targetFormat)
            }

            await bridge.yieldWhenReady(AnalyzerInput(buffer: output))

            // Long media can contain tens of thousands of buffers. Dispatching one
            // MainActor update per buffer can starve result collection and make the
            // editor appear frozen while the file is being fed much faster than real
            // time. Keep progress responsive without flooding the UI queue.
            let currentProgress = min(Double(file.framePosition) / Double(totalFrames), 1)
            let now = progressClock.now
            if currentProgress >= 1
                || (currentProgress - lastReportedProgress >= 0.0025
                    && lastProgressUpdate.duration(to: now) >= .milliseconds(100)) {
                progress(currentProgress)
                lastReportedProgress = currentProgress
                lastProgressUpdate = now
            }
        }

        if !Task.isCancelled, lastReportedProgress < 1 {
            progress(1)
        }
        bridge.finish()
    }

    static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioPipelineError.unsupportedMedia
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error || conversionError != nil {
            throw AudioPipelineError.conversionFailed(conversionError?.localizedDescription ?? "未知错误")
        }
        return output
    }
}

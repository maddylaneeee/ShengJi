import AVFoundation
import CoreImage
import Foundation
import Observation
import UniformTypeIdentifiers

enum SubtitleBurnError: LocalizedError, Equatable {
    case unreadableVideo
    case noVideoTrack
    case exportUnavailable
    case exportFailed(String)
    case verificationFailed
    case replaceFailed(String)
    case containerChangeRequiresCopy

    var errorDescription: String? {
        switch self {
        case .unreadableVideo:
            L10n.text("不支持：无法读取这个视频。请选择 MP4、MOV 或 M4V 等 macOS 可以播放的视频。")
        case .noVideoTrack:
            L10n.text("不支持：这个文件没有视频画面。")
        case .exportUnavailable:
            L10n.text("这台 Mac 无法导出这个视频。")
        case .exportFailed(let message):
            L10n.format("烧录失败：%@", message)
        case .verificationFailed:
            L10n.text("烧录结果校验失败，原视频未被修改。")
        case .replaceFailed(let message):
            L10n.format("无法替换原视频：%@", message)
        case .containerChangeRequiresCopy:
            L10n.text("这个视频的格式无法原样写回，请选择“创建副本”。")
        }
    }
}

struct SubtitleBurnVideoInfo: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let size: CGSize
    let isHEVC: Bool
    let outputFileType: AVFileType
    /// The output container matches the original extension, so the original can be replaced in place.
    let canReplaceOriginal: Bool

    var summary: String {
        let resolution = "\(Int(size.width))×\(Int(size.height))"
        return "\(duration.formattedDuration) · \(resolution)"
    }

    var suggestedCopyName: String {
        let base = url.deletingPathExtension().lastPathComponent
        return "\(base)-subtitled.\(outputExtension)"
    }

    var outputExtension: String {
        canReplaceOriginal ? url.pathExtension : (UTType(outputFileType.rawValue)?.preferredFilenameExtension ?? "mov")
    }
}

enum SubtitleBurnOutput: Equatable, Sendable {
    case copy(URL)
    case replaceOriginal
}

enum SubtitleBurner {
    static let videoContentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    static func inspect(videoURL: URL) async throws -> SubtitleBurnVideoInfo {
        let accessed = videoURL.startAccessingSecurityScopedResource()
        defer { if accessed { videoURL.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: videoURL)
        let isReadable: Bool
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            isReadable = try await asset.load(.isReadable)
            tracks = try await asset.loadTracks(withMediaType: .video)
            duration = try await asset.load(.duration)
        } catch {
            throw SubtitleBurnError.unreadableVideo
        }
        guard isReadable else { throw SubtitleBurnError.unreadableVideo }
        guard let track = tracks.first else { throw SubtitleBurnError.noVideoTrack }
        let (naturalSize, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let oriented = naturalSize.applying(transform)
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        let (fileType, preserved) = outputFileType(for: videoURL)
        return SubtitleBurnVideoInfo(
            url: videoURL,
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            size: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            isHEVC: isHEVC,
            outputFileType: fileType,
            canReplaceOriginal: preserved
        )
    }

    static func outputFileType(for url: URL) -> (AVFileType, Bool) {
        switch url.pathExtension.lowercased() {
        case "mp4": (.mp4, true)
        case "m4v": (.m4v, true)
        case "mov", "qt": (.mov, true)
        default: (.mov, false)
        }
    }

    /// Renders a still preview at `time` with the given cues and style.
    static func previewImage(videoURL: URL, cues: [SubtitleCue], style: SubtitleBurnStyle, at time: TimeInterval) async throws -> CGImage {
        let accessed = videoURL.startAccessingSecurityScopedResource()
        defer { if accessed { videoURL.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (frame, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let source = CIImage(cgImage: frame)
        let compositor = SubtitleFrameCompositor(cues: cues, style: style)
        let output = compositor.composite(source, at: time, renderSize: source.extent.size)
        guard let rendered = CIContext().createCGImage(output, from: source.extent) else {
            throw SubtitleBurnError.exportFailed("preview")
        }
        return rendered
    }

    /// Burns `cues` into the video and writes the verified result to `output`.
    /// The source file is untouched unless rendering and verification both succeed.
    static func burn(
        info: SubtitleBurnVideoInfo,
        cues: [SubtitleCue],
        style: SubtitleBurnStyle,
        output: SubtitleBurnOutput,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if output == .replaceOriginal, !info.canReplaceOriginal { throw SubtitleBurnError.containerChangeRequiresCopy }
        let source = info.url
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribeSubtitleBurn", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let rendered = workDirectory.appendingPathComponent("burned").appendingPathExtension(info.outputExtension)

        try await render(info: info, cues: cues, style: style, to: rendered, progress: progress)
        try await verify(rendered: rendered, expectedDuration: info.duration)
        progress(1)

        switch output {
        case .copy(let destination):
            let destinationAccess = destination.startAccessingSecurityScopedResource()
            defer { if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: destination.path) {
                // The save panel already confirmed replacing this file.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: rendered)
            } else {
                try FileManager.default.moveItem(at: rendered, to: destination)
            }
            return destination
        case .replaceOriginal:
            try replaceContents(of: source, with: rendered)
            return source
        }
    }

    private static func render(
        info: SubtitleBurnVideoInfo,
        cues: [SubtitleCue],
        style: SubtitleBurnStyle,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: info.url)
        let compositor = SubtitleFrameCompositor(cues: cues, style: style)
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            let image = compositor.composite(request.sourceImage.clampedToExtent().cropped(to: request.sourceImage.extent),
                                             at: request.compositionTime.seconds,
                                             renderSize: request.renderSize)
            request.finish(with: image, context: nil)
        }
        let preset = info.isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: info.outputFileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SubtitleBurnError.exportUnavailable
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = info.outputFileType != .mov

        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state {
                    progress(min(exportProgress.fractionCompleted, 0.99))
                }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: destination, as: info.outputFileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SubtitleBurnError.exportFailed(error.localizedDescription)
        }
    }

    private static func verify(rendered: URL, expectedDuration: TimeInterval) async throws {
        let asset = AVURLAsset(url: rendered)
        guard let duration = try? await asset.load(.duration).seconds,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              duration.isFinite,
              abs(duration - expectedDuration) <= max(0.5, expectedDuration * 0.01) else {
            throw SubtitleBurnError.verificationFailed
        }
    }

    /// Replaces the original file. Tries an atomic swap first; inside the sandbox
    /// the app may only hold access to the file itself, so fall back to rewriting
    /// its contents from the verified render.
    static func replaceContents(of original: URL, with rendered: URL) throws {
        if (try? FileManager.default.replaceItemAt(original, withItemAt: rendered)) != nil { return }
        do {
            let input = try FileHandle(forReadingFrom: rendered)
            defer { try? input.close() }
            let outputHandle = try FileHandle(forWritingTo: original)
            defer { try? outputHandle.close() }
            try outputHandle.truncate(atOffset: 0)
            while let chunk = try input.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
                try outputHandle.write(contentsOf: chunk)
            }
            try outputHandle.synchronize()
        } catch {
            throw SubtitleBurnError.replaceFailed(error.localizedDescription)
        }
    }
}

/// UI-facing job state for one burn run.
@MainActor
@Observable
final class SubtitleBurnJob {
    enum State: Equatable {
        case idle
        case running(Double)
        case finished(URL)
        case failed(String)
        case cancelled
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    func start(info: SubtitleBurnVideoInfo, cues: [SubtitleCue], style: SubtitleBurnStyle, output: SubtitleBurnOutput) {
        guard !isRunning else { return }
        state = .running(0)
        let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, case .running = self.state else { return }
                self.state = .running(value)
            }
        }
        task = Task { [weak self] in
            do {
                let url = try await SubtitleBurner.burn(info: info, cues: cues, style: style, output: output, progress: reportProgress)
                self?.state = .finished(url)
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
    }
}

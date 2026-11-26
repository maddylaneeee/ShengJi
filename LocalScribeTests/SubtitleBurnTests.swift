import AVFoundation
import CoreImage
import XCTest
@testable import LocalScribe

final class SubtitleBurnTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleBurnTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    @MainActor
    func testOutputModeIsNeverPersisted() throws {
        let suite = "SubtitleBurnTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SubtitleBurnPreferences(defaults: defaults)
        preferences.style.marginPercent = 10
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        XCTAssertEqual(keys, [SubtitleBurnPreferences.defaultsKey])
        let json = String(data: try XCTUnwrap(defaults.data(forKey: SubtitleBurnPreferences.defaultsKey)), encoding: .utf8) ?? ""
        XCTAssertFalse(json.localizedCaseInsensitiveContains("replace"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("copy"))
        XCTAssertEqual(SubtitleBurnOutputMode.allCases.first, .copy)
    }

    func testActiveCuesIncludeOverlapsAndRespectEndTimes() {
        let compositor = SubtitleFrameCompositor(cues: [
            SubtitleCue(startTime: 0, endTime: 10, text: "Long"),
            SubtitleCue(startTime: 2, endTime: 3, text: "Short"),
            SubtitleCue(startTime: 12, endTime: 13, text: "Late"),
        ], style: .default)
        XCTAssertEqual(compositor.activeCueIndices(at: 2.5), [0, 1])
        XCTAssertEqual(compositor.activeCueIndices(at: 3), [0])
        XCTAssertEqual(compositor.activeCueIndices(at: 11), [])
        XCTAssertEqual(compositor.activeCueIndices(at: 12.5), [2])
        XCTAssertEqual(compositor.activeCueIndices(at: -1), [])
    }

    func testCompositorCacheStaysBoundedAcrossThousandsOfCues() {
        let cues = (0..<3_000).map { SubtitleCue(startTime: Double($0), endTime: Double($0) + 0.9, text: "字幕 \($0)") }
        let compositor = SubtitleFrameCompositor(cues: cues, style: .default)
        let size = CGSize(width: 320, height: 180)
        let canvas = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        for second in 0..<3_000 {
            _ = compositor.composite(canvas, at: Double(second) + 0.5, renderSize: size)
            XCTAssertLessThanOrEqual(compositor.cachedImageCount, 12)
        }
    }

    func testBurnCopyRendersCaptionOnlyDuringCueAndLeavesSourceUntouched() async throws {
        let source = try await makeGrayVideo(named: "source.mp4")
        let sourceData = try Data(contentsOf: source)
        let info = try await SubtitleBurner.inspect(videoURL: source)
        XCTAssertTrue(info.canReplaceOriginal)
        XCTAssertEqual(info.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(info.suggestedCopyName, "source-subtitled.mp4")

        let destination = workDirectory.appendingPathComponent("copy.mp4")
        var style = SubtitleBurnStyle.default
        style.fontSizePercent = 10
        let result = try await SubtitleBurner.burn(
            info: info,
            cues: [SubtitleCue(startTime: 0.2, endTime: 1.2, text: "BURNED TEXT")],
            style: style,
            output: .copy(destination)
        ) { _ in }

        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: source), sourceData, "Copy mode must not modify the source")
        let output = AVURLAsset(url: destination)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(duration, info.duration, accuracy: 0.2)
        let videoTrack = try await output.loadTracks(withMediaType: .video).first
        let naturalSize = try await XCTUnwrap(videoTrack).load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))

        let during = try await deviatingPixelCount(in: destination, at: 0.7)
        let after = try await deviatingPixelCount(in: destination, at: 1.7)
        XCTAssertGreaterThan(during, 400, "Caption pixels should appear while the cue is active")
        XCTAssertLessThan(after, 40, "No caption pixels after the cue ends")
    }

    func testBurnReplaceOriginalOverwritesOnlyAfterSuccess() async throws {
        let source = try await makeGrayVideo(named: "inplace.mov")
        let before = try Data(contentsOf: source)
        let info = try await SubtitleBurner.inspect(videoURL: source)
        let result = try await SubtitleBurner.burn(
            info: info,
            cues: [SubtitleCue(startTime: 0, endTime: 2, text: "IN PLACE")],
            style: .default,
            output: .replaceOriginal
        ) { _ in }
        XCTAssertEqual(result, source)
        XCTAssertNotEqual(try Data(contentsOf: source), before)
        let deviating = try await deviatingPixelCount(in: source, at: 1)
        XCTAssertGreaterThan(deviating, 200)
    }

    func testCancelledBurnLeavesOriginalUntouched() async throws {
        let source = try await makeGrayVideo(named: "cancel.mp4", seconds: 6)
        let before = try Data(contentsOf: source)
        let info = try await SubtitleBurner.inspect(videoURL: source)
        let start = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in start.stream { break }
            return try await SubtitleBurner.burn(info: info, cues: [SubtitleCue(startTime: 0, endTime: 6, text: "X")],
                                                 style: .default, output: .replaceOriginal) { _ in }
        }
        task.cancel()
        start.continuation.finish()
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled burn must not replace the source")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    private func makeGrayVideo(named name: String, seconds: Double = 2, width: Int = 640, height: Int = 360,
                               fps: Int32 = 10) async throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        let fileType: AVFileType = url.pathExtension == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 128, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    /// Counts pixels in the frame that differ strongly from the uniform gray source.
    private func deviatingPixelCount(in url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
            if abs(luminance - 128) > 60 { count += 1 }
        }
        return count
    }
}

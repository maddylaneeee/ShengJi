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

    // MARK: Style persistence

    @MainActor
    func testStyleAndFontPersistAndResetToDefault() throws {
        let suite = "SubtitleBurnTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let family = try XCTUnwrap(SubtitleFontCatalog.families().first)
        let preferences = SubtitleBurnPreferences(defaults: defaults)
        XCTAssertEqual(preferences.style, .default)
        preferences.style.fontFamily = family
        preferences.style.fontSizePercent = 7.5
        preferences.style.position = .top
        preferences.style.shadowColor = SubtitleBurnColor(red: 1, green: 0, blue: 0)
        preferences.style.shadowWidth = 9

        let reloaded = SubtitleBurnPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.style.fontFamily, family)
        XCTAssertEqual(reloaded.style.fontSizePercent, 7.5)
        XCTAssertEqual(reloaded.style.position, .top)
        XCTAssertEqual(reloaded.style.shadowColor, SubtitleBurnColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(reloaded.style.shadowWidth, 9)

        reloaded.resetToDefault()
        XCTAssertEqual(SubtitleBurnPreferences(defaults: defaults).style, .default)
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

    @MainActor
    func testMissingFontFallsBackToSystemFontAndValuesAreClamped() throws {
        let suite = "SubtitleBurnTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = #"{"fontFamily":"No Such Font 1234","fontSizePercent":99,"shadowWidth":-3,"position":"sideways"}"#
        defaults.set(Data(stored.utf8), forKey: SubtitleBurnPreferences.defaultsKey)
        let preferences = SubtitleBurnPreferences(defaults: defaults)
        XCTAssertEqual(preferences.style.fontSizePercent, SubtitleBurnStyle.fontSizeRange.upperBound)
        XCTAssertEqual(preferences.style.shadowWidth, 0)
        XCTAssertEqual(preferences.style.position, .bottom)
        XCTAssertNil(preferences.effectiveStyle.fontFamily)
        XCTAssertEqual(preferences.effectiveStyle.font(size: 20).familyName, NSFont.systemFont(ofSize: 20).familyName)
    }

    // MARK: CLI

    func testCLIOptionsParseAndOverrideStyleWithoutPersisting() throws {
        let options = try SubtitleBurnCLIOptions.parse(
            ["--video", "/tmp/a.mp4", "--subtitles", "/tmp/a.srt", "--size", "6", "--position", "top",
             "--background", "50", "--shadow-color", "#FF0000", "--shadow-width", "3", "--overwrite"],
            baseStyle: .default
        )
        XCTAssertEqual(options.videoURL.path, "/tmp/a.mp4")
        XCTAssertFalse(options.inPlace)
        XCTAssertTrue(options.overwrite)
        XCTAssertEqual(options.style.fontSizePercent, 6)
        XCTAssertEqual(options.style.position, .top)
        XCTAssertTrue(options.style.backgroundEnabled)
        XCTAssertEqual(options.style.backgroundOpacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(options.style.shadowColor, SubtitleBurnColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(options.style.shadowWidth, 3)

        let inPlace = try SubtitleBurnCLIOptions.parse(["--video", "a.mov", "--subtitles", "a.vtt", "--in-place"], baseStyle: .default)
        XCTAssertTrue(inPlace.inPlace)
    }

    func testCLIOptionsRejectConflictsAndBadValues() {
        let cases: [[String]] = [
            ["--video", "a.mp4"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--in-place", "--output", "b.mp4"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--size", "40"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--position", "left"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--shadow-color", "red"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--font", "No Such Font 1234"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--bogus"],
            ["--video", "--subtitles", "a.srt"],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try SubtitleBurnCLIOptions.parse(arguments, baseStyle: .default), "\(arguments)")
        }
    }

    // MARK: Compositor

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

    func testRasterizerProducesImageForEveryPositionAndBackground() throws {
        var style = SubtitleBurnStyle.default
        for position in SubtitleBurnPosition.allCases {
            for background in [false, true] {
                style.position = position
                style.backgroundEnabled = background
                let image = try XCTUnwrap(SubtitleCueRasterizer.render(text: "字幕 Subtitle\n第二行", renderSize: CGSize(width: 1920, height: 1080), style: style))
                XCTAssertGreaterThan(image.width, 100)
                XCTAssertLessThan(image.width, 1920)
            }
        }
        style.shadowWidth = 0
        XCTAssertNotNil(SubtitleCueRasterizer.render(text: "No shadow", renderSize: CGSize(width: 640, height: 360), style: style))
    }

    func testBurnCuesMatchSubtitleExportSplitting() {
        let cues = TranscriptExporter.burnCues(
            text: "One\nTwo", duration: 4,
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "One"),
                       TranscriptSegment(startTime: 2, endTime: 3, text: "Two")],
            manuallyEdited: false
        )
        XCTAssertEqual(cues, [SubtitleCue(startTime: 0, endTime: 1, text: "One"), SubtitleCue(startTime: 2, endTime: 3, text: "Two")])
        XCTAssertFalse(TranscriptExporter.burnCues(text: "Edited sentence. Another one.", duration: 4, segments: [], manuallyEdited: true).isEmpty)
    }

    // MARK: End-to-end

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
        let task = Task {
            try await SubtitleBurner.burn(info: info, cues: [SubtitleCue(startTime: 0, endTime: 6, text: "X")],
                                          style: .default, output: .replaceOriginal) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            // Cancellation surfaces as an error; either way the source must be intact.
        }
        if (try? Data(contentsOf: source)) != before {
            // The export may finish before cancellation is observed; then it is a valid completed replace.
            let replaced = try await SubtitleBurner.inspect(videoURL: source)
            XCTAssertEqual(replaced.duration, info.duration, accuracy: 0.2)
        }
    }

    func testRejectsNonVideoAndUnwritableContainer() async throws {
        let audioOnly = workDirectory.appendingPathComponent("note.txt")
        try Data("not a video".utf8).write(to: audioOnly)
        do {
            _ = try await SubtitleBurner.inspect(videoURL: audioOnly)
            XCTFail("Expected failure")
        } catch {
            XCTAssertNotNil(error as? SubtitleBurnError)
        }
        XCTAssertEqual(SubtitleBurner.outputFileType(for: URL(fileURLWithPath: "/a.mkv")).1, false)
        XCTAssertEqual(SubtitleBurner.outputFileType(for: URL(fileURLWithPath: "/a.MP4")).1, true)
    }

    // MARK: Helpers

    private func makeGrayVideo(named name: String, seconds: Double = 2) async throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        let fileType: AVFileType = url.pathExtension == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 360,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
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

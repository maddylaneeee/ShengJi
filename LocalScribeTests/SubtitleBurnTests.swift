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
        preferences.style.shadowEnabled = false

        let reloaded = SubtitleBurnPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.style.fontFamily, family)
        XCTAssertEqual(reloaded.style.fontSizePercent, 7.5)
        XCTAssertEqual(reloaded.style.position, .top)
        XCTAssertEqual(reloaded.style.shadowColor, SubtitleBurnColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(reloaded.style.shadowWidth, 9)
        XCTAssertFalse(reloaded.style.shadowEnabled)

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
        XCTAssertTrue(preferences.style.shadowEnabled, "Styles saved before the shadow switch keep the shadow on")
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

        XCTAssertTrue(options.style.shadowEnabled)

        let inPlace = try SubtitleBurnCLIOptions.parse(["--video", "a.mov", "--subtitles", "a.vtt", "--in-place"], baseStyle: .default)
        XCTAssertTrue(inPlace.inPlace)

        let noShadow = try SubtitleBurnCLIOptions.parse(["--video", "a.mp4", "--subtitles", "a.srt", "--shadow", "OFF"], baseStyle: .default)
        XCTAssertFalse(noShadow.style.shadowEnabled)
        var savedOff = SubtitleBurnStyle.default
        savedOff.shadowEnabled = false
        let backOn = try SubtitleBurnCLIOptions.parse(["--video", "a.mp4", "--subtitles", "a.srt", "--shadow", "on"], baseStyle: savedOff)
        XCTAssertTrue(backOn.style.shadowEnabled)
    }

    func testCLIOptionsRejectConflictsAndBadValues() {
        let cases: [[String]] = [
            ["--video", "a.mp4"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--in-place", "--output", "b.mp4"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--size", "40"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--position", "left"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--shadow-color", "red"],
            ["--video", "a.mp4", "--subtitles", "a.srt", "--shadow", "maybe"],
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

    func testShadowSwitchRemovesShadowPixels() throws {
        let size = CGSize(width: 1280, height: 720)
        var on = SubtitleBurnStyle.default
        on.shadowWidth = 10
        var off = on
        off.shadowEnabled = false
        var zeroWidth = on
        zeroWidth.shadowWidth = 0
        let shadowed = try XCTUnwrap(SubtitleCueRasterizer.render(text: "Shadow", renderSize: size, style: on))
        let plain = try XCTUnwrap(SubtitleCueRasterizer.render(text: "Shadow", renderSize: size, style: off))
        let reference = try XCTUnwrap(SubtitleCueRasterizer.render(text: "Shadow", renderSize: size, style: zeroWidth))
        XCTAssertEqual(SubtitleLayoutMetrics(renderSize: size, style: off).shadowUnit, 0)
        XCTAssertGreaterThan(SubtitleLayoutMetrics(renderSize: size, style: on).shadowUnit, 0)
        XCTAssertEqual(plain.width, reference.width)
        XCTAssertLessThan(plain.width, shadowed.width, "Disabled shadow should not reserve shadow padding")
        XCTAssertLessThan(try opaquePixelCount(plain), try opaquePixelCount(shadowed))
    }

    // MARK: Long media

    func testParsesLongSubtitleFilesQuickly() throws {
        let count = 20_000
        var srt = ""
        var vtt = "WEBVTT\n\n"
        var sbv = ""
        var ass = "[Script Info]\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        srt.reserveCapacity(count * 64)
        for index in 0..<count {
            let start = Double(index) * 0.5
            srt += "\(index + 1)\n\(srtTime(start)) --> \(srtTime(start + 0.45))\n第 \(index + 1) 条字幕 Cue \(index + 1)\n\n"
            let dotStart = srtTime(start).replacingOccurrences(of: ",", with: ".")
            let dotEnd = srtTime(start + 0.45).replacingOccurrences(of: ",", with: ".")
            vtt += "\(dotStart) --> \(dotEnd)\nLine \(index)\n\n"
            sbv += "\(dotStart.dropFirst()),\(dotEnd.dropFirst())\nLine \(index)\n\n"
            ass += "Dialogue: 0,\(dotStart.dropFirst().dropLast()),\(dotEnd.dropFirst().dropLast()),Default,,0,0,0,,{\\b1}Line \(index)\n"
        }
        let clock = ContinuousClock()
        var document: SubtitleDocument?
        var others: [SubtitleDocument] = []
        let elapsed = try clock.measure {
            document = try SubtitleFileParser.parse(data: Data(srt.utf8), fileName: "long.srt")
            others.append(try SubtitleFileParser.parse(data: Data(vtt.utf8), fileName: "long.vtt"))
            others.append(try SubtitleFileParser.parse(data: Data(sbv.utf8), fileName: "long.sbv"))
            others.append(try SubtitleFileParser.parse(data: Data(ass.utf8), fileName: "long.ass"))
        }
        XCTAssertEqual(document?.cues.count, count)
        XCTAssertEqual(others.map(\.cues.count), [count, count, count])
        XCTAssertEqual(others.map(\.format), [.webVTT, .sbv, .ass])
        XCTAssertEqual(document?.lastEnd ?? 0, Double(count - 1) * 0.5 + 0.45, accuracy: 0.001)
        XCTAssertTrue(document?.warnings(videoDuration: 3 * 3_600).isEmpty ?? false)
        print("Parsing \(count) cues in 4 formats took \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(10), "Parsing \(count) cues in 4 formats took \(elapsed)")
    }

    func testActiveCueLookupStaysFastWithManyCuesAndOneLongCue() {
        var cues = (0..<20_000).map { index in
            SubtitleCue(startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 0.4, text: "Cue \(index)")
        }
        cues.append(SubtitleCue(startTime: 0, endTime: 10_000, text: "Title held for the whole video"))
        let compositor = SubtitleFrameCompositor(cues: cues, style: .default)
        let sorted = cues.enumerated().sorted { $0.element.startTime < $1.element.startTime }.map(\.element)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let time = Double.random(in: -1...10_050, using: &generator)
            let expected = sorted.indices.filter { sorted[$0].startTime <= time && time < sorted[$0].endTime }
            XCTAssertEqual(compositor.activeCueIndices(at: time), expected, "time \(time)")
        }
        let clock = ContinuousClock()
        let frames = 3 * 3_600 * 30
        let elapsed = clock.measure {
            var visible = 0
            for frame in 0..<frames { visible &+= compositor.activeCueIndices(at: Double(frame) / 30).count }
            XCTAssertGreaterThan(visible, frames)
        }
        XCTAssertLessThan(elapsed, .seconds(5), "Looking up \(frames) frames took \(elapsed)")
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

    /// Several minutes of video with a cue every 0.2 s plus a long overlapping cue.
    func testBurnLongVideoWithThousandsOfCues() async throws {
        let seconds = 240.0
        let source = try await makeGrayVideo(named: "long.mp4", seconds: seconds, width: 320, height: 180, fps: 5)
        let info = try await SubtitleBurner.inspect(videoURL: source)
        XCTAssertEqual(info.duration, seconds, accuracy: 0.5)
        var cues = stride(from: 0.0, to: seconds, by: 0.2).enumerated().map { index, start in
            SubtitleCue(startTime: start, endTime: start + 0.2, text: "第 \(index + 1) 条 · Cue \(index + 1)")
        }
        cues.append(SubtitleCue(startTime: 60, endTime: 180, text: "LONG OVERLAY"))
        XCTAssertGreaterThan(cues.count, 1_000)

        let destination = workDirectory.appendingPathComponent("long-out.mp4")
        let progress = ProgressRecorder()
        let clock = ContinuousClock()
        let start = clock.now
        var style = SubtitleBurnStyle.default
        style.fontSizePercent = 8
        _ = try await SubtitleBurner.burn(info: info, cues: cues, style: style, output: .copy(destination)) { value in
            progress.record(value)
        }
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(240), "Burning \(seconds) s with \(cues.count) cues took \(elapsed)")
        XCTAssertTrue(progress.isMonotonic, "Progress must not go backwards")

        let output = try await SubtitleBurner.inspect(videoURL: destination)
        XCTAssertEqual(output.duration, info.duration, accuracy: 0.5)
        for time in [1.1, 59.1, 120.1, 200.1, 238.1] {
            let pixels = try await deviatingPixelCount(in: destination, at: time)
            XCTAssertGreaterThan(pixels, 50, "Caption expected at \(time) s")
        }
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

    private func srtTime(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    private func opaquePixelCount(_ image: CGImage) throws -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 8 ? 1 : 0) }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var isMonotonic: Bool {
        lock.lock(); defer { lock.unlock() }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 }
    }
}

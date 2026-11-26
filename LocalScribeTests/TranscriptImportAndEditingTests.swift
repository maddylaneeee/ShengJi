import XCTest
@testable import LocalScribe

final class TranscriptImportAndEditingTests: XCTestCase {
    func testSRTImportPreservesTextAndTimestamps() throws {
        let source = """
        1
        00:00:01,000 --> 00:00:03,250
        第一段字幕

        2
        00:00:04,000 --> 00:00:06,500
        第二段字幕
        """
        let result = try TranscriptImporter.parse(data: Data(source.utf8), fileName: "sample.srt")
        XCTAssertEqual(result.text, "第一段字幕\n第二段字幕")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(result.duration, 6.5, accuracy: 0.001)
        XCTAssertEqual(result.detectedLocale?.language.languageCode?.identifier, "zh")
    }

    func testWebVTTImportRemovesMarkup() throws {
        let source = """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        <v Speaker>Hello world</v>
        """
        let result = try TranscriptImporter.parse(data: Data(source.utf8), fileName: "sample.vtt")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.detectedLocale?.language.languageCode?.identifier, "en")
    }

    func testNLLBProcessRegistryTerminatesRegisteredHelpers() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        NLLBProcessRegistry.register(process)
        XCTAssertEqual(NLLBProcessRegistry.activeProcessCount, 1)

        NLLBProcessRegistry.terminateAll()
        process.waitUntilExit()

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(NLLBProcessRegistry.activeProcessCount, 0)
    }

    func testLineStartIndexFindsLineNumbersByUTF16Offset() {
        let text = "第一行\n\n😀 third\nlast"
        let index = TranscriptLineStartIndex(text)
        XCTAssertEqual(index.lineCount, 4)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 0), 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 3), 1)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 4), 2)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: 5), 3)
        let lastStart = (text as NSString).range(of: "last").location
        XCTAssertEqual(index.lineNumber(atUTF16Offset: lastStart), 4)
        XCTAssertEqual(index.lineNumber(atUTF16Offset: (text as NSString).length), 4)
        XCTAssertEqual(TranscriptLineStartIndex("").lineCount, 1)
        XCTAssertEqual(TranscriptLineStartIndex("a\n").lineCount, 2)
    }
}

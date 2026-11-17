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

    func testInteractiveTranslationBatchPolicyStaysResponsive() {
        XCTAssertEqual(TranslationBatchPolicy.size(for: .apple), 4)
        XCTAssertEqual(TranslationBatchPolicy.size(for: .nllb), 4)
        XCTAssertEqual(TranslationBatchPolicy.nllbBeamSize, 1)
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

    @MainActor
    func testImportedTranscriptSourceLanguageCanBeCorrected() {
        let imported = ImportedTranscript(
            title: "sample",
            text: "这是中文稿件。",
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "这是中文稿件。")],
            duration: 1
        )
        let session = TranscriptionSessionModel(
            imported: imported,
            continueWithMicrophone: false,
            locale: Locale(identifier: "en_CA"),
            configuration: RecognitionConfiguration(engine: .apple)
        )

        session.updateImportedSourceLocale(Locale(identifier: "zh-Hans"))

        XCTAssertEqual(session.locale.language.languageCode?.identifier, "zh")
    }

    func testFindReplaceAndRangeDeletion() throws {
        let text = "alpha beta gamma delta"
        let found = try XCTUnwrap(TranscriptTextEditing.find("beta", in: text, after: NSRange(location: 0, length: 0)))
        XCTAssertEqual((text as NSString).substring(with: found), "beta")
        let replaced = try XCTUnwrap(TranscriptTextEditing.replacing(text, range: found, with: "B"))
        XCTAssertEqual(replaced.0, "alpha B gamma delta")

        let between = try XCTUnwrap(TranscriptTextEditing.deletingBetween(
            text,
            first: NSRange(location: 0, length: 5),
            second: NSRange(location: 17, length: 5)
        ))
        XCTAssertEqual(between.0, "alphadelta")
    }

    func testLiveCaptionSlidingWindowKeepsContinuousUnpunctuatedOutput() {
        let target = "这是一个没有任何标点并且会持续增长的实时字幕识别结果"
        var frame = ""
        var frames = 0
        while frame != target, frames < 100 {
            let next = LiveCaptionSlidingWindow.nextFrame(current: frame, target: target)
            XCTAssertTrue(next.hasPrefix(frame))
            XCTAssertLessThanOrEqual(next.count - frame.count, 6)
            frame = next
            frames += 1
        }
        XCTAssertEqual(frame, target)
        XCTAssertGreaterThan(frames, 1)
    }

    func testLiveCaptionSlidingWindowAcceptsModelRevision() {
        XCTAssertEqual(
            LiveCaptionSlidingWindow.nextFrame(current: "今天天气", target: "今天的天气很好"),
            "今天的天气很好"
        )
    }

    func testLiveCaptionCompletedSegmentIsHeldAtBoundary() {
        let completed = LiveCaptionLine(
            source: "麦克风",
            text: "这句话已经完成。",
            isFinal: true
        )
        let partial = LiveCaptionLine(
            source: "麦克风",
            text: "下一句话",
            isFinal: false
        )

        XCTAssertTrue(LiveCaptionReadabilityPolicy.shouldHoldPrevious(completed))
        XCTAssertFalse(LiveCaptionReadabilityPolicy.shouldHoldPrevious(partial))
        XCTAssertEqual(LiveCaptionReadabilityPolicy.completedSegmentHoldDuration, .seconds(2))
        XCTAssertEqual(
            LiveCaptionReadabilityPolicy.displayText(
                held: completed.text,
                current: "下一句话仍在继续"
            ),
            "这句话已经完成。  下一句话仍在继续"
        )
    }

    // MARK: - Long transcripts

    func testLineNumbersAreVerbatimAndColumnGrowsWithDigits() {
        XCTAssertEqual(TranscriptLineNumberFormatting.label(1215), "1215")
        XCTAssertEqual(TranscriptLineNumberFormatting.label(1_234_567), "1234567")
        XCTAssertEqual(TranscriptLineNumberFormatting.digitCount(999), 3)
        XCTAssertEqual(TranscriptLineNumberFormatting.digitCount(1215), 4)
        XCTAssertEqual(TranscriptLineNumberFormatting.columnWidth(maximumLineNumber: 12, fontSize: 13), 38)
        let fourDigits = TranscriptLineNumberFormatting.columnWidth(maximumLineNumber: 1215, fontSize: 13)
        let fiveDigits = TranscriptLineNumberFormatting.columnWidth(maximumLineNumber: 12_150, fontSize: 13)
        XCTAssertGreaterThanOrEqual(fourDigits, 4 * 13 * 0.62)
        XCTAssertGreaterThan(fiveDigits, fourDigits)
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

    func testLineStartIndexMatchesNaiveCountForLongTranscript() {
        let text = (1...2_000).map { "第 \($0) 行 line" }.joined(separator: "\n")
        let index = TranscriptLineStartIndex(text)
        XCTAssertEqual(index.lineCount, 2_000)
        let source = text as NSString
        for offset in stride(from: 0, through: source.length, by: 997) {
            let naive = source.substring(to: offset).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            XCTAssertEqual(index.lineNumber(atUTF16Offset: offset), naive)
        }
    }

    func testExportNamingForMicrophoneAndFileSources() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = 2026; components.month = 11; components.day = 17
        components.hour = 1; components.minute = 49; components.second = 5
        let date = try XCTUnwrap(components.date)
        XCTAssertEqual(
            TranscriptExportNaming.microphoneBaseName(startedAt: date, timeZone: timeZone),
            "2026-11-17_01-49-05_Transcription"
        )
        XCTAssertEqual(TranscriptExportNaming.fileBaseName(fileName: "Interview.final.m4a"), "Interview.final_Transcription")
        XCTAssertEqual(TranscriptExportNaming.fileBaseName(fileName: "会议录音.mp4"), "会议录音_Transcription")
        XCTAssertEqual(TranscriptExportNaming.fileBaseName(fileName: "a:b.wav"), "a-b_Transcription")
        XCTAssertNoThrow(try CompanionExportCoordinator.baseName(
            TranscriptExportNaming.microphoneBaseName(startedAt: date, timeZone: timeZone), format: .srt
        ))
    }

    @MainActor
    func testSessionDefaultExportNameFollowsSource() throws {
        let file = TranscriptionSessionModel(
            source: .file(URL(fileURLWithPath: "/tmp/Lecture 3.mov")),
            locale: Locale(identifier: "en_US"),
            configuration: .init(engine: .apple)
        )
        XCTAssertEqual(file.defaultExportBaseName, "Lecture 3_Transcription")

        let microphone = TranscriptionSessionModel(
            source: .microphone,
            locale: Locale(identifier: "en_US"),
            configuration: .init(engine: .apple)
        )
        XCTAssertTrue(microphone.defaultExportBaseName.hasSuffix("_Transcription"))
        XCTAssertNoThrow(try CompanionExportCoordinator.baseName(microphone.defaultExportBaseName, format: .srt))

        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = RecoverySnapshot(
            id: UUID(), sourceTitle: "Recorded.wav", sourceKind: .file, localeIdentifier: "en",
            configuration: .init(engine: .apple), transcriptText: "Saved", segments: [],
            hasManualEdits: false, elapsed: 1, progress: 1, createdAt: startedAt, updatedAt: startedAt,
            transcriptionStartedAt: startedAt
        )
        XCTAssertEqual(TranscriptionSessionModel(snapshot: snapshot).defaultExportBaseName, "Recorded_Transcription")

        var microphoneSnapshot = snapshot
        microphoneSnapshot.sourceKind = .microphone
        XCTAssertEqual(
            TranscriptionSessionModel(snapshot: microphoneSnapshot).defaultExportBaseName,
            TranscriptExportNaming.microphoneBaseName(startedAt: startedAt)
        )
    }

    func testFileRecognitionProgressStaysBelowCompletion() {
        XCTAssertEqual(FileRecognitionProgress.fraction(recognizedTime: 30, sourceDuration: 120), 0.25)
        XCTAssertEqual(FileRecognitionProgress.fraction(recognizedTime: 120, sourceDuration: 120), 0.99)
        XCTAssertEqual(FileRecognitionProgress.fraction(recognizedTime: 500, sourceDuration: 120), 0.99)
        XCTAssertEqual(FileRecognitionProgress.fraction(recognizedTime: 5, sourceDuration: 0), 0)
        XCTAssertEqual(FileRecognitionProgress.fraction(recognizedTime: .nan, sourceDuration: 10), 0)
    }
}

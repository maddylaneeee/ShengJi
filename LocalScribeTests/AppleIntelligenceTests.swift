import XCTest
@testable import LocalScribe

/// Scripted stand-in for the on-device model. Each call is answered by `respond`,
/// and the response is streamed in a few cumulative snapshots.
final class FakeGenerator: AppleIntelligenceGenerating, @unchecked Sendable {
    struct Call {
        let instructions: String
        let prompt: String
        let options: AFMGenerationOptions
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call, Int) throws -> String

    init(respond: @escaping @Sendable (Call, Int) throws -> String) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    func generate(
        instructions: String,
        prompt: String,
        options: AFMGenerationOptions,
        onSnapshot: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let call = Call(instructions: instructions, prompt: prompt, options: options)
        let index: Int = lock.withLock {
            recorded.append(call)
            return recorded.count - 1
        }
        let response = try respond(call, index)
        let characters = Array(response)
        for cut in [characters.count / 3, characters.count * 2 / 3, characters.count] where cut > 0 {
            onSnapshot(String(characters[..<cut]))
        }
        return response
    }
}

enum FakeModelError: Error {
    case exceededContextWindowSize(String)
    case guardrailViolation(String)
    case refusal(String, String)
    case unsupportedLanguageOrLocale(String)
    case rateLimited(String)
    case concurrentRequests
    case assetsUnavailable(String)
}

enum FakeLanguageModelError27: Error {
    case contextSizeExceeded(Int)
    case timeout(Int)
}

/// Numbered input lines of a prompt's LINES section.
func numberedLines(in prompt: String) -> [(Int, String)] {
    guard let range = prompt.range(of: "LINES:\n") else { return [] }
    return prompt[range.upperBound...].components(separatedBy: "\n").compactMap { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let number = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
        return (number, String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }
}

final class AppleIntelligenceTests: XCTestCase {
    override func tearDown() {
        AppleIntelligenceSupport.setStatusOverride(nil)
        super.tearDown()
    }

    func testMigrationDecisionCoversAvailabilityModeModelsAndVersion() {
        typealias D = AIEngineMigrationDecision
        func decide(_ status: AppleIntelligenceStatus, _ mode: AIEngineMode?, _ models: Bool, _ prompted: String?) -> D {
            AIEngine.migrationDecision(status: status, storedMode: mode, hasLegacyModels: models,
                                       promptedVersion: prompted, currentVersion: "1.9.0")
        }
        for status in AppleIntelligenceStatus.allCases where status != .available {
            for mode in [nil, AIEngineMode.legacy, .appleIntelligence] {
                XCTAssertEqual(decide(status, mode, true, nil), .none, "\(status)")
                XCTAssertEqual(decide(status, mode, false, nil), .none, "\(status)")
            }
        }
        XCTAssertEqual(decide(.available, nil, false, nil), .adoptSilently)
        XCTAssertEqual(decide(.available, nil, true, nil), .ask)
        XCTAssertEqual(decide(.available, .legacy, true, "1.8.1"), .ask)
        XCTAssertEqual(decide(.available, .legacy, true, "1.9.0"), .none)
        XCTAssertEqual(decide(.available, .legacy, false, nil), .ask)
        XCTAssertEqual(decide(.available, .appleIntelligence, true, nil), .none)
    }

    func testLegacyModelRemovalOnlyTouchesGivenDirectoriesAndReportsFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("GemmaModels", isDirectory: true)
        let neighbour = root.appendingPathComponent("SpeechModels", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: managed.appendingPathComponent("model.gguf"))
        try Data("y".utf8).write(to: neighbour.appendingPathComponent("keep.bin"))

        XCTAssertEqual(LegacyModelStore.removeAll(urls: [managed, root.appendingPathComponent("missing")]), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.appendingPathComponent("keep.bin").path))

        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("z".utf8).write(to: locked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        XCTAssertEqual(LegacyModelStore.removeAll(urls: [locked]).count, 1)
    }

    func testOldSnapshotsAndNewProviderDecode() throws {
        let id = UUID()
        let old = """
        {"id":"\(id)","sourceSegmentID":"\(id)","ordinal":0,"startTime":0,"endTime":1,
         "sourceText":"Hi","translatedText":"你好","state":"translated","errorMessage":null}
        """
        let decoded = try JSONDecoder().decode(SegmentTranslation.self, from: Data(old.utf8))
        XCTAssertNil(decoded.substituteProvider)

        let substituted = SegmentTranslation(
            id: id, sourceSegmentID: id, ordinal: 0, startTime: 0, endTime: 1,
            sourceText: "Hi", translatedText: "你好", state: .translated, errorMessage: nil,
            substituteProvider: .apple
        )
        let roundTrip = try JSONDecoder().decode(SegmentTranslation.self, from: JSONEncoder().encode(substituted))
        XCTAssertEqual(roundTrip.substituteProvider, .apple)

        let configuration = try JSONDecoder().decode(
            TranslationConfiguration.self,
            from: Data(#"{"provider":"appleIntelligence","targetLanguage":"english"}"#.utf8)
        )
        XCTAssertEqual(configuration.provider, .appleIntelligence)
        let legacy = try JSONDecoder().decode(TranslationConfiguration.self, from: Data(#"{"targetLanguage":"english"}"#.utf8))
        XCTAssertEqual(legacy.provider, .apple)
    }

    func testOversizedTextIsSplitIntoSentencePieces() {
        let sentence = "This sentence has several words in it. "
        let text = String(repeating: sentence, count: 60)
        let pieces = TokenBudget.pieces(of: text, limit: 120)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { TokenBudget.estimate($0) <= 120 })
        XCTAssertEqual(pieces.joined(separator: " ").filter { !$0.isWhitespace },
                       text.filter { !$0.isWhitespace })
        XCTAssertEqual(TokenBudget.pieces(of: "Short.", limit: 120), ["Short."])
    }

    func testNumberedParserHandlesStreamingVariantsAndTrailer() {
        let raw = """
        ```
        【1】 你好，世界。
        [２] 第二行
        继续第二行
        **[3]** 第三行
        TERMS:
        Tim Cook => 蒂姆·库克
        - Apple Park -> 苹果园区
        STYLE: formal, uses 您
        ```
        """
        let parsed = AFMNumberedLineParser.parse(raw, isFinal: true)
        XCTAssertEqual(parsed.lines[1], "你好，世界。")
        XCTAssertEqual(parsed.lines[2], "第二行 继续第二行")
        XCTAssertEqual(parsed.lines[3], "第三行")
        XCTAssertEqual(parsed.terms, [AFMTerm(source: "Tim Cook", target: "蒂姆·库克"), AFMTerm(source: "Apple Park", target: "苹果园区")])
        XCTAssertEqual(parsed.style, "formal, uses 您")
        XCTAssertNil(parsed.openLine)

        let partial = AFMNumberedLineParser.parse("[1] Hello\n[2] Wor", isFinal: false)
        XCTAssertEqual(partial.openLine, 2)
        XCTAssertEqual(partial.closedLines, [1: "Hello"])

        let duplicated = AFMNumberedLineParser.parse("[1] a\n[1] b\n[2] c", isFinal: true)
        XCTAssertEqual(duplicated.duplicates, [1])

        let refusal = AFMNumberedLineParser.parse("Sorry, I can't help with that.", isFinal: true)
        XCTAssertTrue(refusal.lines.isEmpty)
        XCTAssertTrue(AFMRefusalDetector.isRefusal(refusal.preamble, source: "How to make a cake"))
    }

    func testTranslatedTrailerMarkersAreNotKeptInLines() {
        let glued = AFMNumberedLineParser.parse("[1] 甲\n[2] 您的录音不会上传。 术语：\n(1) 声迹", isFinal: true)
        XCTAssertEqual(glued.lines, [1: "甲", 2: "您的录音不会上传。"])
        XCTAssertEqual(glued.nameTranslations, [1: "声迹"])
        let ownLine = AFMNumberedLineParser.parse("[1] 甲\n术语：\n风格：正式", isFinal: false)
        XCTAssertEqual(ownLine.lines, [1: "甲"])
        XCTAssertEqual(ownLine.style, "正式")
        XCTAssertNil(ownLine.openLine)
        XCTAssertEqual(AFMNumberedLineParser.strippingTrailingMarker("Hello **TERMS:**"), "Hello")
        XCTAssertEqual(AFMNumberedLineParser.strippingTrailingMarker("技术术语很多"), "技术术语很多")
    }

    func testFailuresFromBothSDKGenerationsAreClassified() {
        XCTAssertEqual(AFMFailure.classify(FakeModelError.exceededContextWindowSize("x")), .contextExceeded)
        XCTAssertEqual(AFMFailure.classify(FakeLanguageModelError27.contextSizeExceeded(1)), .contextExceeded)
        XCTAssertEqual(AFMFailure.classify(FakeModelError.guardrailViolation("x")), .guardrail)
        XCTAssertEqual(AFMFailure.classify(FakeModelError.refusal("a", "b")), .refusal)
        XCTAssertEqual(AFMFailure.classify(FakeModelError.unsupportedLanguageOrLocale("x")), .unsupportedLanguage)
        XCTAssertEqual(AFMFailure.classify(FakeModelError.rateLimited("x")), .rateLimited)
        XCTAssertEqual(AFMFailure.classify(FakeModelError.concurrentRequests), .busy)
        XCTAssertEqual(AFMFailure.classify(FakeLanguageModelError27.timeout(1)), .timeout)
        if case .unavailable = AFMFailure.classify(FakeModelError.assetsUnavailable("x")) {} else { XCTFail() }
        let policy = NSError(domain: "FoundationModels.ModelManagerError", code: 1046,
                             userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertEqual(AFMFailure.classify(policy), .unavailable("Operation not permitted"))
        XCTAssertNil(AFMFailure.classify(CancellationError()))
    }

    private func units(_ texts: [String]) -> [TranslationUnit] {
        texts.enumerated().map { index, text in
            TranslationUnit(segment: TranscriptSegment(startTime: Double(index), endTime: Double(index + 1), text: text), ordinal: index)
        }
    }

    private func engine(
        _ generator: FakeGenerator,
        context: Int = 8_192,
        supports: @escaping @Sendable (Locale) -> Bool = { _ in true },
        substitute: @escaping @Sendable ([String], Locale, TranslationTargetLanguage) async throws -> [String] = { texts, _, _ in
            texts.map { "APPLE:\($0)" }
        }
    ) -> AFMTranslationEngine {
        AFMTranslationEngine(
            generator: generator,
            windows: TokenBudget.Windows(contextSize: context),
            substitute: substitute,
            supportsLanguage: supports
        )
    }

    /// Echo translator: "[n] text" → "[n] ZH(text)".
    private func echo(_ call: FakeGenerator.Call) -> String {
        numberedLines(in: call.prompt).map { "[\($0.0)] ZH(\($0.1))" }.joined(separator: "\n")
    }

    func testTranslationUsesLargeWindowsStreamsAndPreservesOrder() async {
        let generator = FakeGenerator { call, _ in self.echo(call) }
        let partials = PartialCollector()
        let texts = (0..<30).map { "Sentence number \($0) about the project." }
        let input = units(texts)
        let output = await engine(generator).translate(
            units: input,
            sourceLocale: Locale(identifier: "en_US"),
            targetLanguage: .chineseSimplified,
            onPartialResult: { partials.append($0) }
        )
        XCTAssertEqual(generator.calls.count, 1, "30 short segments fit one window")
        XCTAssertEqual(output.map(\.translatedText), texts.map { "ZH(\($0))" })
        XCTAssertEqual(output.map(\.sourceSegmentID), input.map(\.sourceSegmentID))
        XCTAssertEqual(output.map(\.ordinal), input.map(\.ordinal))
        XCTAssertEqual(output.map(\.startTime), input.map(\.startTime))
        XCTAssertEqual(output.map(\.endTime), input.map(\.endTime))
        XCTAssertTrue(output.allSatisfy { $0.state == .translated && $0.substituteProvider == nil })
        XCTAssertGreaterThan(partials.count, texts.count, "partial lines stream before the window finishes")
        XCTAssertTrue(generator.calls[0].instructions.contains("from English into Simplified Chinese"))
    }

    func testGlossaryFromOneWindowIsInjectedIntoLaterWindows() async {
        let generator = FakeGenerator { call, index in
            let body = self.echo(call)
            return index == 0 ? body + "\nTERMS:\nZorblax Corp => 佐布拉克斯公司\nSTYLE: neutral news tone" : body
        }
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 30)
        let texts = ["Zorblax Corp opened. " + filler, filler, "Zorblax Corp closed. " + filler]
        _ = await engine(generator, context: 1_500).translate(
            units: units(texts), sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified
        )
        XCTAssertGreaterThanOrEqual(generator.calls.count, 3)
        XCTAssertFalse(generator.calls[0].prompt.contains("GLOSSARY"))
        let last = generator.calls.last!.prompt
        XCTAssertTrue(last.contains("GLOSSARY:\nZorblax Corp => 佐布拉克斯公司"))
        XCTAssertTrue(last.contains("STYLE: neutral news tone"))
        XCTAssertTrue(last.contains("CONTEXT (reference only, do not output):"))
        XCTAssertFalse(generator.calls[1].prompt.contains("GLOSSARY"), "only terms present in the window are injected")
    }

    func testGuardrailRejectionSplitsWindowAndSubstitutesOnlyTheRejectedSegment() async {
        let generator = FakeGenerator { call, _ in
            let lines = numberedLines(in: call.prompt)
            if lines.contains(where: { $0.1.contains("forbidden") }) {
                throw FakeModelError.guardrailViolation("blocked")
            }
            return self.echo(call)
        }
        let notices = PartialCollector()
        let texts = ["one", "two", "forbidden three", "four"]
        let output = await engine(generator).translate(
            units: units(texts), sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified,
            onNotice: { notices.appendNotice($0) }
        )
        XCTAssertEqual(output.map(\.translatedText), ["ZH(one)", "ZH(two)", "APPLE:forbidden three", "ZH(four)"])
        XCTAssertEqual(output.map(\.substituteProvider), [nil, nil, .apple, nil])
        XCTAssertEqual(notices.notices.count, 1)
    }

    func testRefusalTextIsNeverWrittenIntoTranslation() async {
        let generator = FakeGenerator { call, _ in
            numberedLines(in: call.prompt).map { number, text in
                text.contains("gun") ? "[\(number)] I'm sorry, but I can't help with that." : "[\(number)] ZH(\(text))"
            }.joined(separator: "\n")
        }
        let output = await engine(generator).translate(
            units: units(["The gun show opened.", "Weather is fine."]),
            sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified
        )
        XCTAssertEqual(output[0].translatedText, "APPLE:The gun show opened.")
        XCTAssertEqual(output[0].substituteProvider, .apple)
        XCTAssertEqual(output[1].translatedText, "ZH(Weather is fine.)")
    }

    func testMissingLinesAreRetriedOnce() async {
        let generator = FakeGenerator { call, index in
            let lines = numberedLines(in: call.prompt)
            if index == 0 { return lines.dropLast().map { "[\($0.0)] ZH(\($0.1))" }.joined(separator: "\n") }
            return self.echo(call)
        }
        let output = await engine(generator).translate(
            units: units(["a", "b", "c"]), sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified
        )
        XCTAssertEqual(output.map(\.translatedText), ["ZH(a)", "ZH(b)", "ZH(c)"])
        XCTAssertEqual(generator.calls.count, 2)
        XCTAssertEqual(numberedLines(in: generator.calls[1].prompt).map(\.1), ["c"])
    }

    func testUnsupportedLanguageUsesAppleTranslationForTheWholeRun() async {
        let generator = FakeGenerator { call, _ in self.echo(call) }
        let notices = PartialCollector()
        let output = await engine(generator, supports: { $0.language.languageCode?.identifier != "ru" }).translate(
            units: units(["Привет", "Пока"]), sourceLocale: Locale(identifier: "ru_RU"), targetLanguage: .english,
            onNotice: { notices.appendNotice($0) }
        )
        XCTAssertTrue(generator.calls.isEmpty)
        XCTAssertEqual(output.map(\.translatedText), ["APPLE:Привет", "APPLE:Пока"])
        XCTAssertEqual(notices.notices.count, 1)
    }

    func testSystemFailureBlocksAppleIntelligenceForRestOfRun() async {
        let generator = FakeGenerator { _, _ in
            throw NSError(domain: "ModelManagerError", code: 1046, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        }
        let filler = String(repeating: "word ", count: 300)
        let output = await engine(generator, context: 1_500).translate(
            units: units([filler, filler, filler]), sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified
        )
        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertTrue(output.allSatisfy { $0.substituteProvider == .apple })
        XCTAssertEqual(AppleIntelligenceSupport.status, .blocked)
    }

    func testContextOverflowHalvesTheWindow() async {
        let generator = FakeGenerator { call, _ in
            if numberedLines(in: call.prompt).count > 2 { throw FakeLanguageModelError27.contextSizeExceeded(9_000) }
            return self.echo(call)
        }
        let output = await engine(generator).translate(
            units: units(["a", "b", "c", "d"]), sourceLocale: Locale(identifier: "en"), targetLanguage: .english
        )
        XCTAssertEqual(output.map(\.translatedText), ["ZH(a)", "ZH(b)", "ZH(c)", "ZH(d)"])
        XCTAssertTrue(output.allSatisfy { $0.substituteProvider == nil })
    }

    func testProofreadAppliesValidatedLinesAndKeepsRejectedOnes() async throws {
        let generator = FakeGenerator { call, _ in
            numberedLines(in: call.prompt).map { number, text in
                if text.contains("45") { return "[\(number)] It cost 99 dollars." }
                return "[\(number)] " + text.replacingOccurrences(of: "um, ", with: "")
            }.joined(separator: "\n")
        }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "So um, we start now."),
            TranscriptSegment(startTime: 1, endTime: 2, text: "It cost 45 dollars."),
        ]
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "Prefer British spelling",
            progress: { _, _ in }, preview: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), ["So we start now.", "It cost 45 dollars."])
        // The changed number is rejected by the correction pass and put back
        // by the cleanup pass, so nothing is reported as failed.
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(generator.calls[0].prompt.contains("User preferences (style and terminology only):\nPrefer British spelling"))
    }

    func testProofreadJoinsFragmentsAndDropsFillerLines() async throws {
        // The model writes whole sentences and ignores the line numbers.
        let generator = FakeGenerator { _, _ in
            "1. So these are really important questions to ask. [n]\nWe start in May."
        }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "So, um, these are really"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "important questions"),
            TranscriptSegment(startTime: 2, endTime: 3, text: "to ask."),
            TranscriptSegment(startTime: 3, endTime: 4, text: "Um, uh,"),
            TranscriptSegment(startTime: 4, endTime: 5, text: "We start in May."),
        ]
        let previews = TextCollector()
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "",
            progress: { _, _ in }, preview: { previews.append($0) }
        )
        XCTAssertEqual(result.segments.map(\.text), ["So these are really important questions to ask.", "We start in May."])
        XCTAssertEqual(result.segments[0].id, segments[0].id)
        XCTAssertEqual(result.segments[0].startTime, 0)
        XCTAssertEqual(result.segments[0].endTime, 3)
        XCTAssertEqual(result.text, "So these are really important questions to ask.\nWe start in May.")
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(previews.values.last, result.text)
    }

    func testProofreadKeepsOriginalsWhenOutputCannotBeTraced() async throws {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "We need the budget."),
            TranscriptSegment(startTime: 1, endTime: 2, text: "Next we discuss hiring."),
            TranscriptSegment(startTime: 2, endTime: 3, text: "Thanks, um, everyone."),
        ]
        // An invented heading, a reordered merge, and one honest edit.
        let generator = FakeGenerator { _, _ in
            "UBC presentation: what you need.\nNext we discuss hiring and the budget.\nThanks everyone."
        }
        let previews = TextCollector()
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "",
            progress: { _, _ in }, preview: { previews.append($0) }
        )
        XCTAssertEqual(result.segments.map(\.text), ["We need the budget.", "Next we discuss hiring.", "Thanks everyone."])
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertTrue(previews.values.allSatisfy { !$0.contains("UBC") && !$0.contains("and the budget") })
    }

    func testProofreadCorrectsMisheardWordsBeforeCleanup() async throws {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "明天上午九点在三楼会议适开会"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "小明小明你给我回来"),
        ]
        let generator = FakeGenerator { call, _ in
            if call.instructions.contains("error corrector") {
                XCTAssertTrue(call.prompt.contains("User preferences"), "user terms reach the correction pass")
                // One honest fix, one unfaithful edit that must be ignored.
                return "[1] 明天上午九点在三楼会议室开会\n[2] 小明小明你回来"
            }
            return numberedLines(in: call.prompt).map { $0.1 + "。" }.joined(separator: "\n")
        }
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "会议室",
            progress: { _, _ in }, preview: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), ["明天上午九点在三楼会议室开会。", "小明小明你给我回来。"])
        XCTAssertTrue(generator.calls.last!.prompt.contains("会议室"), "cleanup sees the corrected text")
        XCTAssertEqual(AFMProofreadPlan.restoringSourceWords("王小东，王小东，您给我下来！", source: "王小东王小东你给我下来"),
                       "王小东，王小东，你给我下来！")
        XCTAssertEqual(AFMProofreadPlan.restoringSourceWords("So we're going to start, today.", source: "um so we're gonna start today"),
                       "So we're gonna start, today.")
        XCTAssertEqual(AFMProofreadPlan.restoringSourceWords("嗯，这个我们先看一下数据。", source: "嗯这个那个我们先看一下数据"),
                       "嗯，这个我们先看一下数据。", "dropped words are left to validation, not restored")
        XCTAssertEqual(AFMProofreadPlan.tighteningDenseSpaces("今天我们 主要讨论一下 明年的 预算。", source: "今天我们主要讨论一下明年的 预算"),
                       "今天我们主要讨论一下明年的 预算。")
        XCTAssertEqual(AFMProofreadPlan.tighteningDenseSpaces("常备 999 板蓝根 。So we go.", source: ""), "常备 999 板蓝根。So we go.")
        // Filler phrases may go; single function words may not.
        XCTAssertEqual(AFMProofreadPlan.unfaithfulEdits(output: AFMLineAlignment.tokens("我们先看一下"),
                                                        source: AFMLineAlignment.tokens("那个我们先看一下")), 0)
        XCTAssertEqual(AFMProofreadPlan.unfaithfulEdits(output: AFMLineAlignment.tokens("think it works"),
                                                        source: AFMLineAlignment.tokens("I think it works")), 1)
        XCTAssertTrue(AFMProofreadPlan.isRecognitionFix("今天去公园散步", of: "今天去公圆散步"))
        XCTAssertTrue(AFMProofreadPlan.isRecognitionFix("在三楼会议室开会", of: "在三楼会议适开会"))
        XCTAssertTrue(AFMProofreadPlan.isRecognitionFix("I put it over there now.", of: "I put it over their now."))
        // Replacements that do not sound alike are guesses, not fixes.
        XCTAssertFalse(AFMProofreadPlan.isRecognitionFix("about the Gateway Station project.", of: "about the Kessler Station project."))
        XCTAssertFalse(AFMProofreadPlan.isRecognitionFix("about 3.2 million dollars.", of: "about 3.2 million euros."))
        XCTAssertFalse(AFMProofreadPlan.isRecognitionFix("小明您给我回来", of: "小明你给我回来"))
        XCTAssertFalse(AFMProofreadPlan.isRecognitionFix("邀请您观看", of: "邀您观看"))
        XCTAssertFalse(AFMProofreadPlan.isRecognitionFix("完全不同的一句话", of: "今天去公圆散步"))
    }

    func testRollingSummarySeesWrittenSummaryAndPolishesAtTheEnd() async throws {
        let generator = FakeGenerator { call, _ in
            if call.instructions.contains("running summary") {
                let parts = call.prompt.components(separatedBy: "NEXT PART:\n")
                let soFar = parts[0], next = parts.last ?? ""
                if next.contains("The budget is 120 units."), !soFar.contains("budget") { return "- The budget is 120 units." }
                if next.contains("The launch moves to May.") { return "- The launch moves to May." }
                return "NONE"
            }
            return "The budget is 120 units and the launch moves to May."
        }
        let part = { (label: String, fact: String) in
            (0..<20).map { TranscriptSegment(startTime: 0, endTime: 1, text: "\(label) filler sentence number \($0) with ordinary words. \(fact)") }
        }
        let segments = part("Part one", "The budget is 120 units.") + part("Part two", "") + part("Part three", "The launch moves to May.")
        let previews = PartialCollector()
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 1_600)).optimize(
            segments: segments, fallbackText: "", kind: .summarize, prompt: "",
            progress: { _, _ in }, preview: { previews.appendNotice($0) }
        )
        let steps = generator.calls.filter { $0.instructions.contains("running summary") }
        XCTAssertGreaterThanOrEqual(steps.count, 2)
        XCTAssertTrue(steps[0].prompt.contains("SUMMARY SO FAR:\n(empty)"))
        XCTAssertTrue(steps.last!.prompt.contains("The budget is 120 units."), "later steps see the summary so far")
        let final = generator.calls.last!
        XCTAssertTrue(final.prompt.contains("NOTES:"))
        XCTAssertEqual(result.summary, "The budget is 120 units and the launch moves to May.")
        XCTAssertTrue(previews.notices.contains { $0.contains("The budget is 120 units.") })
    }

    func testUngroundedSummaryIsRejected() async {
        let generator = FakeGenerator { _, _ in "Revenue grew 95 percent." }
        let segments = [TranscriptSegment(startTime: 0, endTime: 5, text: String(repeating: "Our revenue grew 12 percent this quarter thanks to strong demand. ", count: 4))]
        do {
            _ = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
                segments: segments, fallbackText: "", kind: .summarize, prompt: "",
                progress: { _, _ in }, preview: { _ in }
            )
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(generator.calls.count, 2, "retries once before failing")
        }
    }
}

final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}

final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SegmentTranslation] = []
    private var messages: [String] = []
    func append(_ value: SegmentTranslation) { lock.withLock { values.append(value) } }
    func appendNotice(_ value: String) { lock.withLock { messages.append(value) } }
    var count: Int { lock.withLock { values.count } }
    var notices: [String] { lock.withLock { messages } }
}

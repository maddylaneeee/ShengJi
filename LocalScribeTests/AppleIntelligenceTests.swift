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

    // MARK: Engine mode and migration

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

    func testEffectiveEngineFallsBackWhenAppleIntelligenceIsUnavailable() {
        XCTAssertTrue(AIEngine.usesAppleIntelligence(storedMode: .appleIntelligence, status: .available))
        XCTAssertFalse(AIEngine.usesAppleIntelligence(storedMode: .appleIntelligence, status: .notEnabled))
        XCTAssertFalse(AIEngine.usesAppleIntelligence(storedMode: .appleIntelligence, status: .blocked))
        XCTAssertFalse(AIEngine.usesAppleIntelligence(storedMode: .legacy, status: .available))
        XCTAssertFalse(AIEngine.usesAppleIntelligence(storedMode: nil, status: .available))
    }

    func testTranslationPickerOffersAppleIntelligenceOrNLLB() {
        XCTAssertEqual(AIEngine.selectableProviders(usesAppleIntelligence: true, nllbReplaces: false), [.apple, .appleIntelligence])
        XCTAssertEqual(AIEngine.selectableProviders(usesAppleIntelligence: true, nllbReplaces: true), [.apple, .nllb])
        XCTAssertEqual(AIEngine.selectableProviders(usesAppleIntelligence: false, nllbReplaces: false), [.apple, .nllb])

        XCTAssertEqual(AIEngine.resolvedProvider(.nllb, usesAppleIntelligence: true, nllbReplaces: false), .appleIntelligence)
        XCTAssertEqual(AIEngine.resolvedProvider(.appleIntelligence, usesAppleIntelligence: true, nllbReplaces: true), .nllb)
        XCTAssertEqual(AIEngine.resolvedProvider(.appleIntelligence, usesAppleIntelligence: false, nllbReplaces: false), .nllb)
        XCTAssertEqual(AIEngine.resolvedProvider(.apple, usesAppleIntelligence: true, nllbReplaces: false), .apple)
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

    // MARK: Compatibility

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

    func testCLIAcceptsIntelligenceProviderAliases() throws {
        XCTAssertEqual(try CLIController.parseTranslationProvider(nil), .apple)
        for value in ["intelligence", "afm", "apple-intelligence", "AFM"] {
            XCTAssertEqual(try CLIController.parseTranslationProvider(value), .appleIntelligence)
        }
        XCTAssertEqual(try CLIController.parseTranslationProvider("nllb"), .nllb)
        XCTAssertThrowsError(try CLIController.parseTranslationProvider("gemma"))
    }

    // MARK: Prompt preferences

    @MainActor
    func testPersistentPromptsAreLimitedTo500AndOldValuesAreTruncated() throws {
        let suiteName = "AppleIntelligenceTests.Prompts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(AIPromptPreferences.maximumCustomInstructionLength, 500)
        XCTAssertEqual(AIPromptPreferences.maximumOneTimeInstructionLength, 500)

        defaults.set(String(repeating: "a", count: 900), forKey: "AIPromptPreferences.ProofreadInstructions")
        defaults.set(true, forKey: "AIPromptPreferences.PreserveAcrossUpdates")
        defaults.set("1.8.1", forKey: "AIPromptPreferences.RecordedVersion")
        let preferences = AIPromptPreferences(defaults: defaults, appVersion: "1.9.0")
        XCTAssertTrue(preferences.wasTruncated)
        XCTAssertEqual(preferences.proofreadInstructions.count, 500)
        XCTAssertEqual(defaults.string(forKey: "AIPromptPreferences.ProofreadInstructions")?.count, 500)

        let reloaded = AIPromptPreferences(defaults: defaults, appVersion: "1.9.0")
        XCTAssertFalse(reloaded.wasTruncated)
        defaults.set("Use Oxford spelling.", forKey: "AIPromptPreferences.SummaryInstructions")
        reloaded.reload()
        XCTAssertEqual(reloaded.summaryInstructions, "Use Oxford spelling.")
    }

    // MARK: Token budget

    func testTokenEstimatesAreConservativeForChineseAndEnglish() {
        let english = String(repeating: "The quick brown fox jumps. ", count: 40)
        let chinese = String(repeating: "敏捷的狐狸跳过了懒狗。", count: 40)
        // Measured: English ≈ 5.6 characters/token, Chinese ≈ 1.56 characters/token.
        XCTAssertGreaterThan(TokenBudget.estimate(english), Int(Double(english.count) / 5.6))
        XCTAssertGreaterThanOrEqual(TokenBudget.estimate(chinese), chinese.count)
        XCTAssertEqual(TokenBudget.estimate(""), 0)
    }

    func testWindowBudgetsScaleWithContextSize() {
        let large = TokenBudget.Windows(contextSize: 8_192)
        let small = TokenBudget.Windows(contextSize: 4_096)
        XCTAssertEqual(large.maximumSourceTokens, 3_031)
        XCTAssertEqual(large.targetSourceTokens, 1_818)
        XCTAssertEqual(small.targetSourceTokens, 909)
        XCTAssertEqual(large.summarySourceTokens, 4_096)
        XCTAssertEqual(small.summaryNotesTokens, 614)
    }

    func testWindowsNeverSplitItemsAndCoverEverything() {
        let ranges = TokenBudget.windows(costs: [400, 400, 400, 2_000, 10, 10], target: 1_000)
        XCTAssertEqual(ranges, [0..<2, 2..<3, 3..<4, 4..<6])
        XCTAssertEqual(TokenBudget.windows(costs: [], target: 10), [])
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

    // MARK: Parser and detection

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

    func testNameAnswersParseWithOrWithoutTermsMarker() {
        let implicit = AFMNumberedLineParser.parse("[1] 你好\n\n(1) 埃琳娜·瓦格拉：埃琳娜·瓦格拉\n(2) 瓦格拉 (Varga)", isFinal: true)
        XCTAssertEqual(implicit.lines, [1: "你好"])
        XCTAssertEqual(implicit.nameTranslations, [1: "埃琳娜·瓦格拉", 2: "瓦格拉 (Varga)"])
        XCTAssertEqual(TranslationMemory.strippingEcho("瓦格拉 (Varga)", source: "Varga"), "瓦格拉")
        XCTAssertEqual(TranslationMemory.strippingEcho("世界卫生组织（WHO）", source: "World Health Organization"), "世界卫生组织")
        XCTAssertEqual(TranslationMemory.strippingEcho("凯瑟勒站", source: "Kessler Station"), "凯瑟勒站")

        let marked = AFMNumberedLineParser.parse("[1] a\nTERMS:\n(1) Kessler => 凯瑟勒\n3) 北极圈\nSTYLE: formal", isFinal: true)
        XCTAssertEqual(marked.nameTranslations, [1: "凯瑟勒", 3: "北极圈"])
        XCTAssertEqual(marked.style, "formal")
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

    func testNameExtractorFindsPeopleOrganizationsAndSurnamesWithoutTitles() {
        let names = AFMNameExtractor.names(in: "Good morning, I am Dr. Elena Varga from the Halvorsen Institute. Marcus Oyelaran joined us.")
        XCTAssertTrue(names.contains("Elena Varga"))
        XCTAssertTrue(names.contains("Varga"))
        XCTAssertTrue(names.contains("Halvorsen Institute"))
        XCTAssertFalse(names.contains { ["dr", "good morning"].contains($0.lowercased()) })
    }

    func testGlossaryAnswersAreMappedToExtractedNames() async {
        let generator = FakeGenerator { call, index in
            let body = self.echo(call)
            return index == 0 ? body + "\n(1) 佐布拉克斯公司 (Zorblax Corp)" : body
        }
        var translator = engine(generator, context: 1_500)
        translator.extractNames = { $0.contains("Zorblax Corp") ? ["Zorblax Corp"] : [] }
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 30)
        _ = await translator.translate(
            units: units(["Zorblax Corp opened. " + filler, filler, "Zorblax Corp closed. " + filler]),
            sourceLocale: Locale(identifier: "en"), targetLanguage: .chineseSimplified
        )
        XCTAssertTrue(generator.calls[0].prompt.contains("NAMES:\n(1) Zorblax Corp"))
        XCTAssertTrue(generator.calls.last!.prompt.contains("GLOSSARY:\nZorblax Corp => 佐布拉克斯公司"))
        XCTAssertFalse(generator.calls.last!.prompt.contains("NAMES:"), "known names are not asked again")
    }

    func testRollingSummaryAdditionDropsEchoedHeadersAndKnownSentences() {
        let existing = "Kessler Station opened in 2019. It has 14 staff."
        let response = "SUMMARY SO FAR:\nKessler Station opened in 2019. It has 14 staff. The budget is 3.2 million euros.\nNEXT PART:\nNONE"
        XCTAssertEqual(AFMSummaryRun.cleanedAddition(response, existing: existing), "The budget is 3.2 million euros.")
        XCTAssertEqual(AFMSummaryRun.cleanedAddition("NONE", existing: existing), "")
        XCTAssertEqual(AFMSummaryRun.cleanedAddition("A new fact.", existing: ""), "A new fact.")
        XCTAssertEqual(AFMSummaryRun.cleanedAddition("A fact. B fact.\nA fact.", existing: ""), "A fact. B fact.")
        XCTAssertEqual(AFMSummaryRun.validatedSummary("Ice shrank 8%.", source: String(repeating: "The ice shrank by 8 percent this year. ", count: 5), target: 40), "Ice shrank 8%.")
        XCTAssertNil(AFMSummaryRun.validatedSummary("Ice shrank 9%.", source: String(repeating: "The ice shrank by 8 percent this year. ", count: 5), target: 40))
    }

    func testRefusalDetectionIgnoresApologiesPresentInSource() {
        XCTAssertTrue(AFMRefusalDetector.isRefusal("I'm sorry, but I can't assist with that.", source: "Discuss the shooting."))
        XCTAssertTrue(AFMRefusalDetector.isRefusal("抱歉，我无法提供帮助。", source: "The report covers drugs."))
        XCTAssertFalse(AFMRefusalDetector.isRefusal("对不起，我迟到了。", source: "Sorry, I'm late."))
        XCTAssertFalse(AFMRefusalDetector.isRefusal("会议九点开始。", source: "The meeting starts at nine."))
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

    // MARK: Translation memory

    func testTranslationMemoryKeepsFirstTranslationAndEvictsOldest() {
        var memory = TranslationMemory()
        memory.merge([AFMTerm(source: "Tim Cook", target: "蒂姆·库克"), AFMTerm(source: "Mars", target: "火星")],
                     windowText: "Tim Cook spoke.", windowIndex: 0)
        XCTAssertEqual(memory.entries.count, 1, "terms absent from the window are ignored")
        memory.merge([AFMTerm(source: "tim cook", target: "库克")], windowText: "Tim Cook again", windowIndex: 1)
        XCTAssertEqual(memory.entries["tim cook"]?.target, "蒂姆·库克")
        memory.merge([AFMTerm(source: "哈尔沃森研究所", target: "Halvorsen Institute")],
                     windowText: "The Halvorsen Institute", windowIndex: 1)
        XCTAssertEqual(memory.entries["halvorsen institute"]?.target, "哈尔沃森研究所", "reversed pairs are re-oriented")
        memory.merge([AFMTerm(source: "Kessler", target: "Kessler")], windowText: "Kessler", windowIndex: 1)
        XCTAssertNil(memory.entries["kessler"], "untranslated identity pairs are ignored")

        let many = (0..<20).map { AFMTerm(source: "term\($0)", target: "t\($0)") }
        let text = many.map(\.source).joined(separator: " ")
        memory.merge(many, windowText: text, windowIndex: 2)
        XCTAssertEqual(memory.entries.count, 2 + TranslationMemory.maximumNewEntriesPerWindow)

        for window in 3..<12 {
            let batch = (0..<8).map { AFMTerm(source: "w\(window)x\($0)", target: "v") }
            memory.merge(batch, windowText: batch.map(\.source).joined(separator: " "), windowIndex: window)
        }
        XCTAssertEqual(memory.entries.count, TranslationMemory.maximumEntries)
        XCTAssertNil(memory.entries["tim cook"], "least recently seen entries are evicted")

        let relevant = memory.relevant(to: "w11x0 and w11x1 only", tokenLimit: 200)
        XCTAssertEqual(Set(relevant.map(\.source)), ["w11x0", "w11x1"])
        XCTAssertTrue(memory.relevant(to: "w11x0 w11x1", tokenLimit: 3).isEmpty)
    }

    // MARK: Translation engine

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
        let output = await engine(generator).translate(
            units: units(texts),
            sourceLocale: Locale(identifier: "en_US"),
            targetLanguage: .chineseSimplified,
            onPartialResult: { partials.append($0) }
        )
        XCTAssertEqual(generator.calls.count, 1, "30 short segments fit one window")
        XCTAssertEqual(output.map(\.translatedText), texts.map { "ZH(\($0))" })
        XCTAssertTrue(output.allSatisfy { $0.state == .translated && $0.substituteProvider == nil })
        XCTAssertGreaterThan(partials.count, texts.count, "partial lines stream before the window finishes")
        XCTAssertEqual(generator.calls[0].options.temperature, nil)
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

    // MARK: Proofreading and summaries

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
        XCTAssertEqual(result.failures.map(\.id), [segments[1].id])
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

    func testProofreadSplitsWindowWhenAnswerDrifts() async throws {
        let segments = (0..<8).map {
            TranscriptSegment(startTime: Double($0), endTime: Double($0 + 1), text: "Point \(["one", "two", "three", "four", "five", "six", "seven", "eight"][$0]) about tuition fees.")
        }
        let generator = FakeGenerator { call, _ in
            let lines = numberedLines(in: call.prompt)
            if lines.count > 4 { return "Here is a short overview of the talk." }
            return lines.map(\.1).joined(separator: "\n")
        }
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "",
            progress: { _, _ in }, preview: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), segments.map(\.text))
        XCTAssertEqual(generator.calls.count, 3, "the drifting window is split once and retried")
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testProofreadPlanAlignsByContentNotNumbers() {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "We need"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "the budget of 120 units."),
            TranscriptSegment(startTime: 2, endTime: 3, text: "Next we discuss hiring."),
        ]
        // Dropping the number loses too much of the source to be accepted.
        var plan = AFMProofreadPlan.make(from: ["We need the budget.", "-"], editable: segments)
        XCTAssertTrue(plan.edits.isEmpty)
        XCTAssertEqual(plan.matchedLines, 0)
        // A long line split into two sentences becomes one segment.
        plan = AFMProofreadPlan.make(from: ["We need the budget of 120 units.", "Next, we discuss", "hiring."], editable: segments)
        XCTAssertEqual(plan.edits[segments[0].id], .text("We need the budget of 120 units.", through: segments[1].id))
        XCTAssertEqual(plan.edits[segments[1].id], .joined)
        XCTAssertEqual(plan.edits[segments[2].id], .text("Next, we discuss hiring.", through: segments[2].id))
        XCTAssertEqual(plan.matchedLines, 3)

        XCTAssertEqual(AFMProofreadPlan.outputLines("[1] euros. [n]  \n1. Good morning [1] [1] [1]\nLINES:\n- [n]\n[3] half", closedOnly: true),
                       ["euros.", "Good morning"])
        XCTAssertTrue(AFMProofreadPlan.isFillerOnly("Um, uh, you know,"))
        XCTAssertTrue(AFMProofreadPlan.isFillerOnly("嗯，那个，"))
        XCTAssertFalse(AFMProofreadPlan.isFillerOnly("it."))
        XCTAssertEqual(AFMProofreadPlan.joined(["我们需要", "预算。"]), "我们需要预算。")
        XCTAssertEqual(AFMProofreadPlan.joined(["We need", "a plan."]), "We need a plan.")
        XCTAssertEqual(AFMLineAlignment.tokens("你好, World!"), ["你", "好", "world"])
        XCTAssertNil(AFMProofreadPlan.acceptedOrder(output: ["next", "we", "discuss", "hiring", "and", "the", "budget"],
                                                    source: ["we", "need", "the", "budget", "next", "we", "discuss", "hiring"]))
    }

    func testProofreadWindowsEndOnSentenceBoundaries() {
        let texts = ["One two three.", "four five", "six seven.", "eight nine", "ten eleven", "twelve."]
        let ranges = AFMProofreadPlan.ranges(texts: texts, target: 10_000, maximumCount: 5)
        XCTAssertEqual(ranges, [0..<3, 3..<6])
        XCTAssertEqual(AFMProofreadPlan.ranges(texts: Array(repeating: "no end", count: 5), target: 10_000, maximumCount: 2),
                       [0..<2, 2..<4, 4..<5])
    }

    func testProofreadWindowsAreSmallAndSummaryContextIsCapped() {
        let large = TokenBudget.Windows(contextSize: 8_192)
        XCTAssertEqual(large.proofreadSourceTokens, 600)
        let ranges = TokenBudget.windows(costs: Array(repeating: 5, count: 60), target: 600, maximumCount: TokenBudget.Windows.proofreadMaximumLines)
        XCTAssertEqual(ranges.map(\.count), [24, 24, 12])
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(TokenBudget.Windows.summaryContextCap(operatingSystemMajor: 26, physicalMemory: 32 * gib), 3_000)
        XCTAssertEqual(TokenBudget.Windows.summaryContextCap(operatingSystemMajor: 26, physicalMemory: 8 * gib), 3_000)
        XCTAssertEqual(TokenBudget.Windows.summaryContextCap(operatingSystemMajor: 27, physicalMemory: 8 * gib), 4_000)
        XCTAssertEqual(TokenBudget.Windows.summaryContextCap(operatingSystemMajor: 27, physicalMemory: 9 * gib), 4_000)
        XCTAssertNil(TokenBudget.Windows.summaryContextCap(operatingSystemMajor: 27, physicalMemory: 16 * gib))
        XCTAssertEqual(large.limitedForSummary(operatingSystemMajor: 27, physicalMemory: 8 * gib).contextSize, 4_000)
        XCTAssertEqual(large.limitedForSummary(operatingSystemMajor: 26, physicalMemory: 16 * gib).summarySourceTokens, 1_500)
        XCTAssertEqual(large.limitedForSummary(operatingSystemMajor: 27, physicalMemory: 16 * gib).contextSize, 8_192)
        XCTAssertEqual(TokenBudget.Windows(contextSize: 1_600).limitedForSummary(operatingSystemMajor: 27, physicalMemory: 8 * gib).contextSize, 1_600)
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
        XCTAssertEqual(steps[0].options.temperature, 0.2)
        let final = generator.calls.last!
        XCTAssertTrue(final.prompt.contains("NOTES:"))
        XCTAssertEqual(final.options.temperature, 0.3)
        XCTAssertEqual(result.summary, "The budget is 120 units and the launch moves to May.")
        XCTAssertTrue(previews.notices.contains { $0.contains("The budget is 120 units.") })
    }

    func testShortTranscriptIsSummarizedInOneCall() async throws {
        let generator = FakeGenerator { _, _ in "Revenue grew 12 percent." }
        let segments = [TranscriptSegment(startTime: 0, endTime: 5, text: String(repeating: "Our revenue grew 12 percent this quarter thanks to strong demand in every region. ", count: 4))]
        let result = try await AFMOptimizer(generator: generator, windows: TokenBudget.Windows(contextSize: 8_192)).optimize(
            segments: segments, fallbackText: "", kind: .summarize, prompt: "",
            progress: { _, _ in }, preview: { _ in }
        )
        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertTrue(generator.calls[0].instructions.contains("Summarize the transcript in English"))
        XCTAssertEqual(result.summary, "Revenue grew 12 percent.")
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

    func testAFMPromptsAreShort() throws {
        for id in [AIPromptID.afmTranslate, .afmProofread, .afmSummarySingle, .afmSummaryStep, .afmSummaryFinal] {
            let words = try AIPromptLoader.load(id).split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(words, 80, id.rawValue)
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

/// Runs against the real on-device model. Opt in locally with
/// `TEST_RUNNER_LOCALSCRIBE_LIVE_AFM=1`; skipped in CI.
final class LiveAppleIntelligenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALSCRIBE_LIVE_AFM"] == "1", "live AFM tests are opt-in")
        AppleIntelligenceSupport.setStatusOverride(nil)
        try XCTSkipUnless(AppleIntelligenceSupport.refresh() == .available, "Apple Intelligence unavailable")
    }

    private let lecture = [
        "Good morning everyone, my name is Dr. Elena Varga and today we will talk about the Kessler Station project.",
        "Kessler Station is a research outpost that the Halvorsen Institute built in 2019 near the Arctic Circle.",
        "The station has 14 permanent staff members and its annual budget is about 3.2 million euros.",
        "Last winter, the team led by Marcus Oyelaran measured ice thickness at 27 locations.",
        "Their results showed that the ice shrank by 8 percent compared with 2015.",
        "Now, Kessler Station also runs an education program for local schools.",
        "Every spring, Dr. Varga and Marcus Oyelaran visit three villages to explain the measurements.",
        "The Halvorsen Institute plans to double the program by 2027.",
        "Finally, if you want to visit Kessler Station, please email the institute before March 1.",
        "Thank you, and let's move on to questions.",
    ]

    func testLiveMultiWindowTranslationKeepsNamesConsistent() async throws {
        let engine = AFMTranslationEngine(
            generator: LoggingGenerator(),
            windows: TokenBudget.Windows(contextSize: 700), // forces several windows
            substitute: { texts, _, _ in texts.map { "APPLE:\($0)" } },
            supportsLanguage: { AppleIntelligenceSupport.supportsLanguage(of: $0) }
        )
        let units = lecture.enumerated().map {
            TranslationUnit(segment: TranscriptSegment(startTime: Double($0.offset), endTime: Double($0.offset + 1), text: $0.element), ordinal: $0.offset)
        }
        let partials = PartialCollector()
        let start = Date()
        let output = await engine.translate(
            units: units, sourceLocale: Locale(identifier: "en_US"), targetLanguage: .chineseSimplified,
            onPartialResult: { partials.append($0) }
        )
        print("LIVE translate seconds:", Date().timeIntervalSince(start), "partials:", partials.count)
        output.forEach { print("LIVE ZH:", $0.translatedText, $0.substituteProvider.map { "[\($0)]" } ?? "") }
        XCTAssertEqual(output.count, lecture.count)
        XCTAssertTrue(output.allSatisfy { $0.state == .translated && !$0.translatedText.isEmpty })
        XCTAssertGreaterThan(partials.count, output.count)
    }

    func testLiveProofreadAndSummary() async throws {
        let optimizer = AFMOptimizer(generator: SystemAppleIntelligenceGenerator(), windows: .current)
        let noisy = lecture.map { "Um, so, " + $0.replacingOccurrences(of: "today we", with: "today we, we") }
        let segments = noisy.enumerated().map { TranscriptSegment(startTime: Double($0.offset), endTime: Double($0.offset + 1), text: $0.element) }
        var start = Date()
        let proofread = try await optimizer.optimize(segments: segments, fallbackText: "", kind: .proofread, prompt: "",
                                                     progress: { _, _ in }, preview: { _ in })
        print("LIVE proofread seconds:", Date().timeIntervalSince(start), "failures:", proofread.failures.count)
        proofread.segments.forEach { print("LIVE PR:", $0.text) }
        XCTAssertLessThan(proofread.failures.count, segments.count / 2)

        start = Date()
        let long = (0..<4).flatMap { _ in segments }
        let small = AFMOptimizer(generator: LoggingGenerator(), windows: TokenBudget.Windows(contextSize: 1_600))
        let summary = try await small.optimize(segments: long, fallbackText: "", kind: .summarize, prompt: "",
                                               progress: { print("LIVE summary progress", $0, $1) }, preview: { _ in })
        print("LIVE summary seconds:", Date().timeIntervalSince(start))
        print("LIVE SUMMARY:", summary.summary ?? "nil", summary.notice ?? "")
        XCTAssertNotNil(summary.summary)
    }

    func testLiveProofreadCompressesFragments() async throws {
        // Speech recognisers often emit hundreds of 3–6 word fragments.
        var fragments: [String] = []
        for (index, sentence) in lecture.enumerated() {
            let words = sentence.split(separator: " ").map(String.init)
            fragments += stride(from: 0, to: words.count, by: 5).map { words[$0..<min($0 + 5, words.count)].joined(separator: " ") }
            if index.isMultiple(of: 3) { fragments.append("Um, uh,") }
        }
        let segments = fragments.enumerated().map { TranscriptSegment(startTime: Double($0.offset), endTime: Double($0.offset + 1), text: $0.element) }
        let optimizer = AFMOptimizer(generator: LoggingGenerator(), windows: .current)
        let previews = TextCollector()
        let start = Date()
        let result = try await optimizer.optimize(segments: segments, fallbackText: "", kind: .proofread, prompt: "",
                                                  progress: { _, _ in }, preview: { previews.append($0) })
        print("LIVE fragments seconds:", Date().timeIntervalSince(start), "in:", segments.count, "out:", result.segments.count,
              "failures:", result.failures.count)
        result.segments.forEach { print("LIVE FR:", String(format: "%.0f-%.0f", $0.startTime, $0.endTime), $0.text) }
        XCTAssertLessThan(result.segments.count, segments.count, "fragments are joined into sentences")
        XCTAssertEqual(previews.values.last, result.text)
        // Every number in the lecture survives, in order.
        let numbers = { (text: String) in text.split(whereSeparator: { !$0.isNumber && $0 != "." }).filter { $0.contains(where: \.isNumber) } }
        XCTAssertEqual(numbers(result.text).count, numbers(fragments.joined(separator: " ")).count)
        // Time ranges stay ordered and cover the whole recording.
        XCTAssertEqual(result.segments.first?.startTime, 0)
        XCTAssertEqual(result.segments.last?.endTime, segments.last { !AFMProofreadPlan.isFillerOnly($0.text) }?.endTime)
        XCTAssertTrue(zip(result.segments, result.segments.dropFirst()).allSatisfy { $0.endTime <= $1.startTime })
    }

    func testLiveProofreadCompressesChineseFragments() async throws {
        let fragments = ["嗯，今天我们", "主要讨论一下", "明年的预算", "嗯，那个，", "预算总额大概是", "三百二十万元", "其中研发占", "百分之四十", "然后呢", "市场推广", "大概占百分之二十五。"]
        let segments = fragments.enumerated().map { TranscriptSegment(startTime: Double($0.offset), endTime: Double($0.offset + 1), text: $0.element) }
        let result = try await AFMOptimizer(generator: LoggingGenerator(), windows: .current).optimize(
            segments: segments, fallbackText: "", kind: .proofread, prompt: "", progress: { _, _ in }, preview: { _ in })
        print("LIVE ZH fragments in:", segments.count, "out:", result.segments.count, "failures:", result.failures.count)
        result.segments.forEach { print("LIVE ZHFR:", String(format: "%.0f-%.0f", $0.startTime, $0.endTime), $0.text) }
        XCTAssertLessThan(result.segments.count, segments.count)
        XCTAssertTrue(result.text.contains("三百二十万") || result.text.contains("320万"))
    }
}

struct LoggingGenerator: AppleIntelligenceGenerating {
    func generate(instructions: String, prompt: String, options: AFMGenerationOptions,
                  onSnapshot: @escaping @Sendable (String) -> Void) async throws -> String {
        let response = try await SystemAppleIntelligenceGenerator().generate(
            instructions: instructions, prompt: prompt, options: options, onSnapshot: onSnapshot)
        if ProcessInfo.processInfo.environment["LOCALSCRIBE_LIVE_AFM_LOG"] == "1" {
            print("LIVE PROMPT>>>\n\(prompt)\nLIVE RESPONSE>>>\n\(response)\n<<<")
        }
        return response
    }
}

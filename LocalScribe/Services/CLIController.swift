import AVFoundation
import Darwin
import Foundation

enum CLIController {
    static func runIfRequested() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let first = arguments.first, first == "--cli" || first == "cli" else { return }
        arguments.removeFirst()

        var exitCode: Int32 = 0
        var finished = false
        Task {
            exitCode = await run(arguments)
            finished = true
        }
        while !finished {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return 0
        }
        let rest = Array(arguments.dropFirst())

        do {
            switch command {
            case "help", "-h", "--help":
                printHelp()
            case "models":
                try printModels(rest)
            case "download":
                try await downloadModel(rest)
            case "remove", "uninstall":
                try removeModel(rest)
            case "transcribe":
                try await transcribe(rest)
            case "translate":
                try await translate(rest)
            default:
                throw CLIError.badArguments(L10n.format("未知命令：%@", command))
            }
            return 0
        } catch {
            fputs(L10n.format("错误：%@\n", error.localizedDescription), stderr)
            return 1
        }
    }

    private static func printHelp() {
        print(L10n.text("cli.help"))
    }

    private static func printModels(_ arguments: [String]) throws {
        let asJSON = arguments.contains("--json")
        let installed = SpeechModelStore.installedModels()
        let rows = ManagedSpeechModel.allModels.map {
            CLIModelRow(
                id: $0.id,
                engine: $0.engine.rawValue,
                title: $0.title,
                size: $0.sizeLabel,
                installed: installed.contains($0),
                path: SpeechModelStore.url(for: $0).path
            )
        }
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(data: try encoder.encode(rows), encoding: .utf8) ?? "[]")
            return
        }

        for row in rows {
            let mark = row.installed ? "✓" : " "
            print("[\(mark)] \(row.id) · \(row.title) · \(row.size)")
        }
    }

    private static func downloadModel(_ arguments: [String]) async throws {
        guard let id = arguments.first else {
            throw CLIError.badArguments(L10n.text("请提供有效 model-id。可用 `models` 查看。"))
        }
        guard let model = ManagedSpeechModel.find(id) else {
            throw CLIError.badArguments(L10n.text("请提供有效 model-id。可用 `models` 查看。"))
        }
        let progressPrinter = CLIProgressPrinter(modelID: model.id)
        try await SpeechModelStore.install(model) { progress in
            progressPrinter.print(progress: progress)
        }
        print(L10n.format("已安装：%@", model.id))
    }

    private static func removeModel(_ arguments: [String]) throws {
        guard let id = arguments.first else {
            throw CLIError.badArguments(L10n.text("请提供有效 model-id。可用 `models` 查看。"))
        }
        guard let model = ManagedSpeechModel.find(id) else {
            throw CLIError.badArguments(L10n.text("请提供有效 model-id。可用 `models` 查看。"))
        }
        try SpeechModelStore.remove(model)
        print(L10n.format("已卸载：%@", model.id))
    }

    private static func transcribe(_ arguments: [String]) async throws {
        guard let input = arguments.first, !input.hasPrefix("--") else {
            throw CLIError.badArguments(L10n.text("请提供音频或视频路径。"))
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        let inputURL = URL(fileURLWithPath: input)
        let engine = try parseEngine(options["engine"]) ?? .whisper
        let computeBackend = try parseComputeBackend(options["compute"])
        let language = Locale(identifier: options["language"] ?? "zh_CN")
        let format = TranscriptExportFormat.cliValue(options["format"] ?? "txt")
        let title = inputURL.deletingPathExtension().lastPathComponent

        var result = try await transcribeFile(
            url: inputURL,
            engine: engine,
            modelID: options["model"],
            locale: language,
            computeBackend: computeBackend
        )
        if let status = result.backendStatus {
            let fallback = status.fallbackReason.map { L10n.format("（%@）", $0) } ?? ""
            fputs(L10n.format("计算后端：%@%@\n", status.detail, fallback), stderr)
        }
        var outputLanguage = Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier
        if let targetValue = options["translate-to"] {
            let target = try parseTranslationTarget(targetValue)
            let provider = try parseTranslationProvider(options["translation-provider"])
            let translations = try await translateSegments(
                result.segments,
                sourceLocale: language,
                targetLanguage: target,
                provider: provider
            )
            let segments = translations.map(\.transcriptSegment)
            result = CLITranscriptResult(
                text: translations.map(\.displayText).joined(separator: "\n"),
                duration: result.duration,
                segments: segments,
                backendStatus: result.backendStatus
            )
            outputLanguage = target.title
        }
        let data = try TranscriptExporter.makeData(
            format: format,
            title: title,
            source: inputURL.lastPathComponent,
            language: outputLanguage,
            duration: result.duration,
            text: result.text,
            segments: result.segments,
            hasManualEdits: false
        )

        if let output = options["output"] {
            let outputURL = URL(fileURLWithPath: output)
            try data.write(to: outputURL, options: [.atomic])
            print(L10n.format("已保存：%@", outputURL.path))
        } else {
            if format == .txt || format == .markdown || format == .json || format == .srt || format == .webVTT {
                print(String(data: data, encoding: .utf8) ?? result.text)
            } else {
                throw CLIError.badArguments(L10n.text("PDF 输出请使用 --output 指定保存路径。"))
            }
        }
    }

    private static func translate(_ arguments: [String]) async throws {
        guard let text = arguments.first, !text.hasPrefix("--") else {
            throw CLIError.badArguments(L10n.text("请提供要翻译的文字。"))
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        let source = Locale(identifier: options["source"] ?? "zh_CN")
        let target = try parseTranslationTarget(options["target"] ?? "en")
        let provider = try parseTranslationProvider(options["provider"])
        let segment = TranscriptSegment(startTime: 0, endTime: 0.05, text: text)
        let output = try await translateSegments(
            [segment],
            sourceLocale: source,
            targetLanguage: target,
            provider: provider
        )
        print(output.first?.displayText ?? "")
    }

    private static func translateSegments(
        _ segments: [TranscriptSegment],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        provider: TranslationProvider
    ) async throws -> [SegmentTranslation] {
        if provider == .apple {
            guard #available(macOS 26.0, *) else {
                throw CLIError.badArguments(L10n.text("Apple Translation 的无界面 CLI 会话需要 macOS 26；macOS 15.5–25 请使用 --provider nllb。"))
            }
            let values = try await AppleTranslationCLI.translate(
                texts: segments.map(\.text),
                sourceLocale: sourceLocale,
                targetLanguage: targetLanguage
            )
            guard values.count == segments.count else { throw AppleTranslationError.invalidResponse }
            return segments.indices.map { index in
                let source = segments[index]
                return SegmentTranslation(
                    id: source.id,
                    sourceSegmentID: source.id,
                    ordinal: index,
                    startTime: source.startTime,
                    endTime: source.endTime,
                    sourceText: source.text,
                    translatedText: values[index],
                    state: .translated,
                    errorMessage: nil
                )
            }
        }

        let units = segments.enumerated().map { index, segment in
            TranslationUnit(segment: segment, ordinal: index)
        }
        return await TranslationService.translate(
            units: units,
            sourceLocale: sourceLocale,
            configuration: TranslationConfiguration(provider: .nllb, targetLanguage: targetLanguage)
        )
    }

    private static func parseTranslationTarget(_ value: String) throws -> TranslationTargetLanguage {
        if let direct = TranslationTargetLanguage(rawValue: value) { return direct }
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "zh", "zh-cn", "zh-hans": return .chineseSimplified
        case "zh-tw", "zh-hk", "zh-hant": return .chineseTraditional
        case "en", "en-us", "en-gb": return .english
        case "ja", "jp": return .japanese
        case "ko", "kr": return .korean
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "pt": return .portuguese
        case "ru": return .russian
        default: throw CLIError.badArguments(L10n.format("不支持的翻译目标语言：%@", value))
        }
    }

    private static func transcribeFile(
        url: URL,
        engine: RecognitionEngine,
        modelID: String?,
        locale: Locale,
        computeBackend: ComputeBackendPreference
    ) async throws -> CLITranscriptResult {
        switch engine {
        case .apple:
            throw CLIError.badArguments(L10n.text("Apple Speech CLI 转录暂未开放；请在图形界面使用 Apple 本地识别。"))
        case .whisper:
            let model = try resolveWhisperModel(modelID)
            let managed: ManagedSpeechModel = .whisper(model)
            guard SpeechModelStore.isInstalled(managed) else { throw ModelStorageError.modelNotInstalled(managed.title) }
            let prepared = try await MediaAudioPreparer.prepare(url)
            defer { if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) } }
            let file = try AVAudioFile(forReading: prepared.url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let context = try WhisperModelContext(
                model: model,
                modelURL: SpeechModelStore.url(for: managed),
                preference: computeBackend
            )
            let gate = PauseGate()
            let segments = try await WhisperFileProcessor.process(
                url: prepared.url,
                context: context,
                languageCode: locale.language.languageCode?.identifier ?? "auto",
                gate: gate,
                incrementalSegmentHandler: { _ in },
                stageHandler: { _ in },
                progressHandler: { _, _ in }
            )
            let text = segments.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return CLITranscriptResult(
                text: text,
                duration: duration,
                segments: segments.isEmpty ? TranscriptSegment.sentenceSegments(from: text, duration: duration) : segments,
                backendStatus: context.backendStatus
            )
        case .senseVoice:
            let model = try resolveSenseVoiceModel(modelID)
            let configuration = RecognitionConfiguration(
                engine: .senseVoice,
                senseVoiceModel: model,
                computeBackend: computeBackend
            )
            let result = try await SherpaOnnxFileProcessor.process(
                sourceURL: url,
                configuration: configuration,
                locale: locale,
                progressHandler: { _, _ in }
            )
            return CLITranscriptResult(
                text: result.segments.map(\.text).joined(separator: "\n"),
                duration: result.segments.last?.endTime ?? 0,
                segments: result.segments,
                backendStatus: result.backendStatus
            )
        case .parakeet:
            let model = try resolveParakeetModel(modelID)
            let configuration = RecognitionConfiguration(
                engine: .parakeet,
                parakeetModel: model,
                computeBackend: computeBackend
            )
            let result = try await SherpaOnnxFileProcessor.process(
                sourceURL: url,
                configuration: configuration,
                locale: locale,
                progressHandler: { _, _ in }
            )
            return CLITranscriptResult(
                text: result.segments.map(\.text).joined(separator: "\n"),
                duration: result.segments.last?.endTime ?? 0,
                segments: result.segments,
                backendStatus: result.backendStatus
            )
        }
    }

    private static func resolveWhisperModel(_ id: String?) throws -> WhisperModel {
        if let id, let model = ManagedSpeechModel.find(id), case .whisper(let whisper) = model { return whisper }
        if let id, let whisper = WhisperModel(rawValue: id) { return whisper }
        if let installed = SpeechModelStore.installedModels().first(where: { $0.engine == .whisper }),
           case .whisper(let whisper) = installed { return whisper }
        return .largeV3TurboQ5
    }

    private static func resolveSenseVoiceModel(_ id: String?) throws -> SenseVoiceModel {
        if let id, let model = ManagedSpeechModel.find(id), case .senseVoice(let senseVoice) = model { return senseVoice }
        if let id, let senseVoice = SenseVoiceModel(rawValue: id) { return senseVoice }
        return .int8_2025
    }

    private static func resolveParakeetModel(_ id: String?) throws -> ParakeetModel {
        if let id, let model = ManagedSpeechModel.find(id), case .parakeet(let parakeet) = model { return parakeet }
        if let id, let parakeet = ParakeetModel(rawValue: id) { return parakeet }
        return .tdt06bV3Int8
    }

    private static func parseEngine(_ value: String?) throws -> RecognitionEngine? {
        guard let value else { return nil }
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased() {
        case "apple", "applespeech", "speech":
            return .apple
        case "whisper":
            return .whisper
        case "sensevoice":
            return .senseVoice
        case "parakeet", "nvidiaparakeet", "nemo":
            return .parakeet
        case "":
            return nil
        default:
            throw CLIError.badArguments(L10n.format("未知识别引擎：%@", value))
        }
    }

    private static func parseComputeBackend(_ value: String?) throws -> ComputeBackendPreference {
        guard let value else { return .automatic }
        switch value.lowercased() {
        case "auto", "automatic": return .automatic
        case "coreml", "ane": return .coreMLANEPreferred
        case "metal", "gpu": return .metal
        case "cpu": return .cpu
        default: throw CLIError.badArguments(L10n.format("未知计算后端：%@", value))
        }
    }

    private static func parseTranslationProvider(_ value: String?) throws -> TranslationProvider {
        guard let value else { return .apple }
        switch value.lowercased() {
        case "apple": return .apple
        case "nllb": return .nllb
        default: throw CLIError.badArguments(L10n.format("未知翻译提供方：%@", value))
        }
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var output: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key.hasPrefix("--"), index + 1 < arguments.count {
                output[String(key.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return output
    }
}

private struct CLIModelRow: Codable {
    let id: String
    let engine: String
    let title: String
    let size: String
    let installed: Bool
    let path: String
}

private struct CLITranscriptResult {
    let text: String
    let duration: TimeInterval
    let segments: [TranscriptSegment]
    let backendStatus: ComputeBackendStatus?
}

private final class CLIProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let modelID: String
    private var lastBucket = -1

    init(modelID: String) {
        self.modelID = modelID
    }

    func print(progress: Double) {
        lock.withLock {
            let bucket = Int(progress * 100) / 5
            guard bucket != lastBucket else { return }
            lastBucket = bucket
            Swift.print(L10n.format("下载 %@：%lld%%", modelID, Int(progress * 100)))
        }
    }
}

private enum CLIError: LocalizedError {
    case badArguments(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let message): message
        }
    }
}

private extension TranscriptExportFormat {
    static func cliValue(_ value: String) -> TranscriptExportFormat {
        switch value.lowercased() {
        case "md", "markdown": .markdown
        case "json": .json
        case "pdf": .pdf
        case "srt": .srt
        case "vtt", "webvtt": .webVTT
        default: .txt
        }
    }
}

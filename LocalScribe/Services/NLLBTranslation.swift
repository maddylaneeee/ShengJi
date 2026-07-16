import Foundation

enum TranslationService {
    private static let batchSize = 64

    static func translate(
        texts: [String],
        sourceLocale: Locale,
        configuration: TranslationConfiguration
    ) async throws -> [String] {
        switch configuration.provider {
        case .apple:
            return try await AppleTranslationCoordinator.shared.translate(
                texts: texts,
                sourceLocale: sourceLocale,
                targetLanguage: configuration.targetLanguage,
                quality: .highFidelity
            )
        case .nllb:
            return try await NLLBTranslationRuntime.shared.translate(
                texts: texts,
                sourceLocale: sourceLocale,
                targetLanguage: configuration.targetLanguage
            )
        }
    }

    static func translate(
        units: [TranslationUnit],
        sourceLocale: Locale,
        configuration: TranslationConfiguration
    ) async -> [SegmentTranslation] {
        if configuration.targetLanguage.isEquivalent(to: sourceLocale) {
            return units.map {
                SegmentTranslation(
                    id: $0.id,
                    sourceSegmentID: $0.sourceSegmentID,
                    ordinal: $0.ordinal,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    sourceText: $0.sourceText,
                    translatedText: $0.sourceText,
                    state: .sourceLanguage,
                    errorMessage: nil
                )
            }
        }

        var output: [SegmentTranslation] = []
        output.reserveCapacity(units.count)
        var cursor = 0
        while cursor < units.count {
            let end = min(cursor + batchSize, units.count)
            let batch = Array(units[cursor..<end])
            output.append(contentsOf: await translateBatchWithFallback(
                batch,
                sourceLocale: sourceLocale,
                configuration: configuration
            ))
            cursor = end
        }
        return output.sorted { $0.ordinal < $1.ordinal }
    }

    private static func translateBatchWithFallback(
        _ units: [TranslationUnit],
        sourceLocale: Locale,
        configuration: TranslationConfiguration
    ) async -> [SegmentTranslation] {
        var batchError: Error?
        for attempt in 0..<2 {
            do {
                let translations = try await translateUnitsPreservingIdentity(
                    units,
                    sourceLocale: sourceLocale,
                    configuration: configuration
                )
                guard translations.count == units.count else {
                    throw TranslationBatchError.invalidCount(expected: units.count, actual: translations.count)
                }
                return await completeEmptyTranslations(
                    units: units,
                    translations: translations,
                    sourceLocale: sourceLocale,
                    configuration: configuration
                )
            } catch is CancellationError {
                return units.map { fallback($0, error: L10n.text("翻译已取消")) }
            } catch {
                batchError = error
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }

        var recovered: [SegmentTranslation] = []
        recovered.reserveCapacity(units.count)
        for unit in units {
            do {
                let values = try await translateUnitsPreservingIdentity(
                    [unit],
                    sourceLocale: sourceLocale,
                    configuration: configuration
                )
                guard let value = values.first,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslationBatchError.emptyTranslation
                }
                recovered.append(success(unit, value: value))
            } catch {
                recovered.append(fallback(unit, error: batchError?.localizedDescription ?? error.localizedDescription))
            }
        }
        return recovered
    }

    private static func completeEmptyTranslations(
        units: [TranslationUnit],
        translations: [String],
        sourceLocale: Locale,
        configuration: TranslationConfiguration
    ) async -> [SegmentTranslation] {
        var output: [SegmentTranslation] = []
        output.reserveCapacity(units.count)
        for index in units.indices {
            let unit = units[index]
            let value = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                output.append(success(unit, value: value))
                continue
            }
            do {
                let retry = try await translateUnitsPreservingIdentity(
                    [unit],
                    sourceLocale: sourceLocale,
                    configuration: configuration
                )
                guard let retried = retry.first,
                      !retried.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslationBatchError.emptyTranslation
                }
                output.append(success(unit, value: retried))
            } catch {
                output.append(fallback(unit, error: error.localizedDescription))
            }
        }
        return output
    }

    private static func success(_ unit: TranslationUnit, value: String) -> SegmentTranslation {
        SegmentTranslation(
            id: unit.id,
            sourceSegmentID: unit.sourceSegmentID,
            ordinal: unit.ordinal,
            startTime: unit.startTime,
            endTime: unit.endTime,
            sourceText: unit.sourceText,
            translatedText: value.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .translated,
            errorMessage: nil
        )
    }

    private static func fallback(_ unit: TranslationUnit, error: String) -> SegmentTranslation {
        SegmentTranslation(
            id: unit.id,
            sourceSegmentID: unit.sourceSegmentID,
            ordinal: unit.ordinal,
            startTime: unit.startTime,
            endTime: unit.endTime,
            sourceText: unit.sourceText,
            translatedText: unit.sourceText,
            state: .fallback,
            errorMessage: error
        )
    }

    private static func translateUnitsPreservingIdentity(
        _ units: [TranslationUnit],
        sourceLocale: Locale,
        configuration: TranslationConfiguration
    ) async throws -> [String] {
        switch configuration.provider {
        case .apple:
            return try await AppleTranslationCoordinator.shared.translate(
                texts: units.map(\.sourceText),
                sourceLocale: sourceLocale,
                targetLanguage: configuration.targetLanguage,
                quality: .highFidelity
            )
        case .nllb:
            return try await NLLBTranslationRuntime.shared.translate(
                units: units,
                sourceLocale: sourceLocale,
                targetLanguage: configuration.targetLanguage
            )
        }
    }
}

private enum TranslationBatchError: LocalizedError {
    case invalidCount(expected: Int, actual: Int)
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .invalidCount(let expected, let actual):
            L10n.format("翻译结果数量不匹配（预期 %lld，实际 %lld）。", expected, actual)
        case .emptyTranslation:
            L10n.text("翻译服务返回了空译文。")
        }
    }
}

enum NLLBTranslationRuntime {
    static let shared = NLLBTranslationProcess()

    static var isRuntimeBundled: Bool {
        runtimeExecutableURL != nil
    }

    static var installedModelURL: URL? {
        modelCandidateURLs.first { isUsableModelDirectory($0) }
    }

    static var modelInstallHint: String {
        modelCandidateURLs.first?.path ?? LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/NLLBModels/nllb-200-distilled-600M-int8", isDirectory: true)
            .path
    }

    fileprivate static var runtimeExecutableURL: URL? {
        let candidates = Bundle.main.urls(
            forResourcesWithExtension: nil,
            subdirectory: "NLLBTranslator/runtime/LocalScribeNLLB"
        ) ?? []
        if let bundled = candidates.first(where: { $0.lastPathComponent == "LocalScribeNLLB" }) {
            return bundled
        }
        let direct = Bundle.main.resourceURL?
            .appendingPathComponent("NLLBTranslator/runtime/LocalScribeNLLB/LocalScribeNLLB")
        if let direct, FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }
        return nil
    }

    private static var modelCandidateURLs: [URL] {
        var candidates: [URL] = []
        let support = LocalScribePaths.applicationSupportDirectory
        candidates.append(support.appendingPathComponent("声迹/NLLBModels/nllb-200-distilled-600M-int8", isDirectory: true))
        candidates.append(support.appendingPathComponent("声迹/Models/nllb-200-distilled-600M-int8", isDirectory: true))
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("NLLBTranslator/model", isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent("NLLBTranslator/nllb-200-distilled-600M-int8", isDirectory: true))
        }
        return candidates
    }

    private static func isUsableModelDirectory(_ url: URL) -> Bool {
        let requiredFiles = ["model.bin", "config.json"]
        guard requiredFiles.allSatisfy({
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }) else { return false }
        guard ["shared_vocabulary.json", "shared_vocabulary.txt"].contains(where: {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }) else { return false }
        return ["sentencepiece.bpe.model", "flores200_sacrebleu_tokenizer_spm.model"].contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
}

actor NLLBTranslationProcess {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var outputBuffer = Data()

    func translate(
        texts: [String],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage
    ) async throws -> [String] {
        let units = texts.enumerated().map { index, text in
            TranslationUnit(
                segment: TranscriptSegment(startTime: Double(index), endTime: Double(index + 1), text: text),
                ordinal: index
            )
        }
        return try await translate(units: units, sourceLocale: sourceLocale, targetLanguage: targetLanguage)
    }

    func translate(
        units: [TranslationUnit],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage
    ) async throws -> [String] {
        let lineBatch = NLLBLineBatch(units: units)
        guard !lineBatch.sourceTexts.isEmpty else { return [] }
        guard let modelURL = NLLBTranslationRuntime.installedModelURL else {
            throw NLLBTranslationError.modelNotInstalled(NLLBTranslationRuntime.modelInstallHint)
        }
        let source = try NLLBLanguage.floresCode(for: sourceLocale)
        let target = try NLLBLanguage.floresCode(for: targetLanguage.locale)
        if source == target { return lineBatch.sourceTexts }
        guard !lineBatch.requestTexts.isEmpty else { return lineBatch.sourceTexts }

        try ensureRunning()
        let request = NLLBRequest(
            command: "translate",
            modelPath: modelURL.path,
            texts: lineBatch.requestTexts,
            unitIDs: lineBatch.requestIDs,
            sourceLanguage: source,
            targetLanguage: target,
            beamSize: 4
        )
        let response: NLLBResponse = try send(request)
        guard response.ok else {
            throw NLLBTranslationError.runtime(response.error ?? L10n.text("NLLB 返回了无效响应。"))
        }
        let translations: [String]
        if let results = response.results {
            let indexed = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.text) })
            translations = try lineBatch.requestIDs.map { id in
                guard let value = indexed[id] else {
                    throw NLLBTranslationError.runtime(L10n.format("NLLB 返回的译文缺少请求 ID：%@", id))
                }
                return value
            }
        } else if let positional = response.translations {
            translations = positional
        } else {
            throw NLLBTranslationError.runtime(L10n.text("NLLB 返回了无效响应。"))
        }
        guard translations.count == lineBatch.requestTexts.count else {
            throw NLLBTranslationError.runtime(L10n.text("NLLB 返回的译文数量不完整。"))
        }
        return try lineBatch.reconstruct(translations: translations)
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard let executableURL = NLLBTranslationRuntime.runtimeExecutableURL else {
            throw NLLBTranslationError.runtimeNotBundled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.stderr = errorPipe.fileHandleForReading

        let ready: NLLBResponse = try readResponse()
        guard ready.ok else {
            throw NLLBTranslationError.runtime(ready.error ?? L10n.text("NLLB 运行时启动失败。"))
        }
    }

    private func send<T: Encodable>(_ request: T) throws -> NLLBResponse {
        guard let input else { throw NLLBTranslationError.runtime(L10n.text("NLLB 运行时未启动。")) }
        let data = try JSONEncoder.nllb.encode(request)
        input.write(data)
        input.write(Data([0x0A]))
        return try readResponse()
    }

    private func readResponse() throws -> NLLBResponse {
        guard let output else { throw NLLBTranslationError.runtime(L10n.text("NLLB 运行时没有输出管道。")) }
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let data = outputBuffer.prefix(upTo: newline)
                outputBuffer.removeSubrange(...newline)
                return try JSONDecoder().decode(NLLBResponse.self, from: Data(data))
            }
            // `read(upToCount:)` may wait for the requested byte count on a
            // pipe, which deadlocks on short JSON-lines responses such as the
            // helper's initial `ready` message. `availableData` blocks only
            // until at least one byte (or EOF) and therefore remains suitable
            // for the incremental line buffer above.
            let chunk = output.availableData
            if chunk.isEmpty {
                let message = readStderr()
                terminate()
                throw NLLBTranslationError.runtime(message.isEmpty ? L10n.text("NLLB 运行时提前退出。") : message)
            }
            outputBuffer.append(chunk)
        }
    }

    private func readStderr() -> String {
        guard let stderr else { return "" }
        let data = stderr.availableData
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func terminate() {
        try? input?.close()
        try? output?.close()
        try? stderr?.close()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        stderr = nil
        outputBuffer.removeAll(keepingCapacity: false)
    }
}

/// Expands each stable translation unit into non-empty line requests while
/// retaining empty-line slots locally.  The frozen NLLB helper used by older
/// packages flattens embedded newlines, so this adapter preserves structure
/// without requiring a risky Python/CTranslate2 runtime rebuild.
struct NLLBLineBatch: Sendable {
    let sourceTexts: [String]
    let requestTexts: [String]
    let requestIDs: [String]
    private let translationSlots: [[Int?]]

    init(units: [TranslationUnit]) {
        var sourceTexts: [String] = []
        var requestTexts: [String] = []
        var requestIDs: [String] = []
        var translationSlots: [[Int?]] = []

        sourceTexts.reserveCapacity(units.count)
        translationSlots.reserveCapacity(units.count)
        for unit in units {
            let normalized = unit.sourceText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            sourceTexts.append(normalized)

            let lines = normalized.components(separatedBy: "\n")
            var slots: [Int?] = []
            slots.reserveCapacity(lines.count)
            for (lineIndex, line) in lines.enumerated() {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else {
                    slots.append(nil)
                    continue
                }
                slots.append(requestTexts.count)
                requestTexts.append(cleaned)
                requestIDs.append("\(unit.id.uuidString)#\(lineIndex)")
            }
            translationSlots.append(slots)
        }

        self.sourceTexts = sourceTexts
        self.requestTexts = requestTexts
        self.requestIDs = requestIDs
        self.translationSlots = translationSlots
    }

    func reconstruct(translations: [String]) throws -> [String] {
        guard translations.count == requestTexts.count else {
            throw NLLBTranslationError.runtime(L10n.text("NLLB 行级译文数量不完整。"))
        }
        return translationSlots.map { slots in
            slots.map { slot in
                guard let slot else { return "" }
                return translations[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n")
        }
    }
}

private enum NLLBLanguage {
    static func floresCode(for locale: Locale) throws -> String {
        let language = locale.language
        guard let code = language.languageCode?.identifier else {
            throw NLLBTranslationError.unsupportedLanguage(locale.identifier)
        }
        switch code {
        case "zh":
            if language.script?.identifier == "Hant" { return "zho_Hant" }
            return "zho_Hans"
        case "en": return "eng_Latn"
        case "ja": return "jpn_Jpan"
        case "ko": return "kor_Hang"
        case "es": return "spa_Latn"
        case "fr": return "fra_Latn"
        case "de": return "deu_Latn"
        case "pt": return "por_Latn"
        case "ru": return "rus_Cyrl"
        default:
            throw NLLBTranslationError.unsupportedLanguage(locale.identifier)
        }
    }
}

private struct NLLBRequest: Encodable {
    let command: String
    let modelPath: String
    let texts: [String]
    let unitIDs: [String]
    let sourceLanguage: String
    let targetLanguage: String
    let beamSize: Int

    private enum CodingKeys: String, CodingKey {
        case command
        case modelPath = "model_path"
        case texts
        case unitIDs = "unit_ids"
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case beamSize = "beam_size"
    }
}

private struct NLLBResponse: Decodable {
    let ok: Bool
    let ready: Bool?
    let runtime: String?
    let translations: [String]?
    let results: [NLLBUnitResult]?
    let error: String?
}

private struct NLLBUnitResult: Decodable {
    let id: String
    let text: String
}

enum NLLBTranslationError: LocalizedError {
    case runtimeNotBundled
    case modelNotInstalled(String)
    case unsupportedLanguage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotBundled:
            L10n.text("NLLB 运行时未包含在当前应用中。")
        case .modelNotInstalled(let path):
            L10n.format("尚未安装 NLLB 模型。请将 CTranslate2 格式模型放到：%@", path)
        case .unsupportedLanguage(let language):
            L10n.format("NLLB 暂不支持当前语言：%@。", language)
        case .runtime(let message):
            message
        }
    }
}

private extension JSONEncoder {
    static var nllb: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

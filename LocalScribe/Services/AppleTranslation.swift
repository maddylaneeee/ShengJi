import Foundation
import Observation
import Translation

enum TranslationTargetLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case chineseSimplified
    case chineseTraditional
    case english
    case japanese
    case korean
    case spanish
    case french
    case german
    case portuguese
    case russian

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .portuguese: "Português"
        case .russian: "Русский"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .current
        case .chineseSimplified: Locale(identifier: "zh-Hans")
        case .chineseTraditional: Locale(identifier: "zh-Hant")
        case .english: Locale(identifier: "en")
        case .japanese: Locale(identifier: "ja")
        case .korean: Locale(identifier: "ko")
        case .spanish: Locale(identifier: "es")
        case .french: Locale(identifier: "fr")
        case .german: Locale(identifier: "de")
        case .portuguese: Locale(identifier: "pt")
        case .russian: Locale(identifier: "ru")
        }
    }

    var language: Locale.Language { Locale.Language(identifier: locale.identifier) }

    func isEquivalent(to sourceLocale: Locale) -> Bool {
        let source = Locale.Language(identifier: sourceLocale.identifier)
        let target = language
        return source.languageCode == target.languageCode
            && (source.script == target.script || source.script == nil || target.script == nil)
    }
}

enum TranslationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple
    case nllb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple 翻译"
        case .nllb: "NLLB"
        }
    }

    var detail: String {
        switch self {
        case .apple: "默认；使用 macOS Translation Framework，本机完成。"
        case .nllb: "可选；使用本机 NLLB 模型，适合离线批量翻译。"
        }
    }

    var inspectorName: String {
        switch self {
        case .apple: "Apple Translation"
        case .nllb: "NLLB"
        }
    }

    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .nllb: "translate"
        }
    }
}

/// Codable-compatible with recovery snapshots written by older Apple-only and former NLLB builds.
struct TranslationConfiguration: Codable, Hashable, Sendable {
    let provider: TranslationProvider
    let targetLanguage: TranslationTargetLanguage

    private enum CodingKeys: String, CodingKey {
        case provider
        case targetLanguage
        case model
    }

    init(provider: TranslationProvider = .apple, targetLanguage: TranslationTargetLanguage) {
        self.provider = provider
        self.targetLanguage = targetLanguage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? .apple
        targetLanguage = try container.decode(TranslationTargetLanguage.self, forKey: .targetLanguage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(targetLanguage, forKey: .targetLanguage)
    }
}

@MainActor
@Observable
final class AppleTranslationPreferences {
    var provider: TranslationProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey) }
    }

    var targetLanguage: TranslationTargetLanguage {
        didSet { UserDefaults.standard.set(targetLanguage.rawValue, forKey: Self.targetKey) }
    }

    private static let providerKey = "TranslationProvider"
    private static let targetKey = "AppleTranslationTargetLanguage"
    private static let legacyTargetKey = "NLLBTargetLanguage"

    init() {
        provider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(TranslationProvider.init(rawValue:)) ?? .apple
        let stored = UserDefaults.standard.string(forKey: Self.targetKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyTargetKey)
        targetLanguage = stored.flatMap(TranslationTargetLanguage.init(rawValue:)) ?? .english
    }
}

enum AppleTranslationQuality: Sendable {
    case highFidelity
    case lowLatency
}

@MainActor
@Observable
final class AppleTranslationCoordinator {
    static let shared = AppleTranslationCoordinator()

    private(set) var configuration: TranslationSession.Configuration?
    private(set) var isBusy = false

    @ObservationIgnored private var currentJob: TranslationJob?
    @ObservationIgnored private var queuedJobs: [TranslationJob] = []
    @ObservationIgnored private weak var activeSession: TranslationSession?

    func prepare(
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        quality: AppleTranslationQuality
    ) async throws {
        _ = try await enqueue(
            texts: [],
            sourceLocale: sourceLocale,
            targetLanguage: targetLanguage,
            quality: quality
        )
    }

    func translate(
        texts: [String],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        quality: AppleTranslationQuality = .highFidelity
    ) async throws -> [String] {
        let cleaned = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !cleaned.isEmpty else { return [] }
        return try await enqueue(
            texts: cleaned,
            sourceLocale: sourceLocale,
            targetLanguage: targetLanguage,
            quality: quality
        )
    }

    func run(session: TranslationSession) async {
        guard let job = currentJob else { return }
        activeSession = session
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()

            let output: [String]
            if job.texts.isEmpty {
                output = []
            } else {
                let requests = job.texts.enumerated().map { index, text in
                    TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
                }
                let responses = try await session.translations(from: requests)
                var indexed: [Int: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let index = Int(identifier) else { continue }
                    indexed[index] = response.targetText
                }
                guard indexed.count == job.texts.count else {
                    throw AppleTranslationError.invalidResponse
                }
                output = job.texts.indices.compactMap { indexed[$0] }
            }
            finish(jobID: job.id, result: .success(output))
        } catch is CancellationError {
            finish(jobID: job.id, result: .failure(CancellationError()))
        } catch {
            finish(jobID: job.id, result: .failure(error))
        }
    }

    private func enqueue(
        texts: [String],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage,
        quality: AppleTranslationQuality
    ) async throws -> [String] {
        let source = Locale.Language(identifier: sourceLocale.identifier)
        let target = targetLanguage.language
        if source.languageCode == target.languageCode,
           source.script == target.script || source.script == nil || target.script == nil {
            return texts
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queuedJobs.append(TranslationJob(
                    id: id,
                    texts: texts,
                    source: source,
                    target: target,
                    quality: quality,
                    continuation: continuation
                ))
                activateNextJobIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(jobID: id) }
        }
    }

    private func activateNextJobIfNeeded() {
        guard currentJob == nil, !queuedJobs.isEmpty else { return }
        let job = queuedJobs.removeFirst()
        currentJob = job
        isBusy = true

        if #available(macOS 26.4, *) {
            let strategy: TranslationSession.Strategy = job.quality == .lowLatency ? .lowLatency : .highFidelity
            configuration = TranslationSession.Configuration(
                source: job.source,
                target: job.target,
                preferredStrategy: strategy
            )
        } else {
            configuration = TranslationSession.Configuration(source: job.source, target: job.target)
        }
    }

    private func cancel(jobID: UUID) {
        if currentJob?.id == jobID {
            if #available(macOS 26.0, *) {
                activeSession?.cancel()
            }
            finish(jobID: jobID, result: .failure(CancellationError()))
            return
        }
        guard let index = queuedJobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = queuedJobs.remove(at: index)
        job.continuation.resume(throwing: CancellationError())
    }

    private func finish(jobID: UUID, result: Result<[String], Error>) {
        guard let job = currentJob, job.id == jobID else { return }
        currentJob = nil
        activeSession = nil
        configuration = nil
        isBusy = false
        job.continuation.resume(with: result)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.activateNextJobIfNeeded()
        }
    }
}

private final class TranslationJob {
    let id: UUID
    let texts: [String]
    let source: Locale.Language
    let target: Locale.Language
    let quality: AppleTranslationQuality
    let continuation: CheckedContinuation<[String], Error>

    init(
        id: UUID,
        texts: [String],
        source: Locale.Language,
        target: Locale.Language,
        quality: AppleTranslationQuality,
        continuation: CheckedContinuation<[String], Error>
    ) {
        self.id = id
        self.texts = texts
        self.source = source
        self.target = target
        self.quality = quality
        self.continuation = continuation
    }
}

@available(macOS 26.0, *)
enum AppleTranslationCLI {
    static func translate(
        texts: [String],
        sourceLocale: Locale,
        targetLanguage: TranslationTargetLanguage
    ) async throws -> [String] {
        let source = Locale.Language(identifier: sourceLocale.identifier)
        let target = targetLanguage.language
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            throw AppleTranslationError.languageAssetsNotInstalled
        case .unsupported:
            throw AppleTranslationError.unsupportedPair(sourceLocale.identifier, targetLanguage.title)
        @unknown default:
            throw AppleTranslationError.unsupportedPair(sourceLocale.identifier, targetLanguage.title)
        }

        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        let indexed = Dictionary(uniqueKeysWithValues: responses.compactMap { response -> (Int, String)? in
            guard let identifier = response.clientIdentifier, let index = Int(identifier) else { return nil }
            return (index, response.targetText)
        })
        guard indexed.count == texts.count else { throw AppleTranslationError.invalidResponse }
        return texts.indices.compactMap { indexed[$0] }
    }
}

enum AppleTranslationError: LocalizedError {
    case invalidResponse
    case languageAssetsNotInstalled
    case unsupportedPair(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Apple Translation 返回了不完整的翻译结果。"
        case .languageAssetsNotInstalled:
            "所需 Apple 翻译语言包尚未安装；请先在声迹图形界面中翻译一次，并按系统提示下载。"
        case .unsupportedPair(let source, let target):
            "本机 Apple Translation 不支持从 \(source) 翻译为 \(target)。"
        }
    }
}

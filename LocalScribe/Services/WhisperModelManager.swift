import Foundation
import Observation

@MainActor
@Observable
final class RecognitionPreferences {
    var engine: RecognitionEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey) }
    }

    var selectedWhisperModel: WhisperModel {
        didSet { UserDefaults.standard.set(selectedWhisperModel.rawValue, forKey: Self.whisperModelKey) }
    }

    var selectedSenseVoiceModel: SenseVoiceModel {
        didSet { UserDefaults.standard.set(selectedSenseVoiceModel.rawValue, forKey: Self.senseVoiceModelKey) }
    }

    var selectedParakeetModel: ParakeetModel {
        didSet { UserDefaults.standard.set(selectedParakeetModel.rawValue, forKey: Self.parakeetModelKey) }
    }

    private(set) var installedModels: Set<ManagedSpeechModel> = []
    private(set) var downloadState: ModelDownloadState = .idle

    private var downloadTask: Task<Void, Never>?
    private static let engineKey = "RecognitionEngine"
    private static let whisperModelKey = "WhisperModel"
    private static let senseVoiceModelKey = "SenseVoiceModel"
    private static let parakeetModelKey = "ParakeetModel"
    private static let lastThirdPartyEngineKey = "LastThirdPartyRecognitionEngine"
    private var lastThirdPartyEngine: RecognitionEngine

    init() {
        let savedWhisper = UserDefaults.standard.string(forKey: Self.whisperModelKey)
            .flatMap(WhisperModel.init(rawValue:)) ?? .largeV3TurboQ5
        let savedSenseVoice = UserDefaults.standard.string(forKey: Self.senseVoiceModelKey)
            .flatMap(SenseVoiceModel.init(rawValue:)) ?? .int8_2025
        let savedParakeet = UserDefaults.standard.string(forKey: Self.parakeetModelKey)
            .flatMap(ParakeetModel.init(rawValue:)) ?? .tdt06bV3Int8

        let detectedInstalledModels = SpeechModelStore.installedModels()
        selectedWhisperModel = savedWhisper
        selectedSenseVoiceModel = savedSenseVoice
        selectedParakeetModel = savedParakeet
        lastThirdPartyEngine = UserDefaults.standard.string(forKey: Self.lastThirdPartyEngineKey)
            .flatMap(RecognitionEngine.init(rawValue:))
            .flatMap { $0 == .apple ? nil : $0 } ?? .whisper
        installedModels = detectedInstalledModels

        let savedEngine = UserDefaults.standard.string(forKey: Self.engineKey)
            .flatMap(RecognitionEngine.init(rawValue:))

        // A fresh install always starts with Apple's framework. Third-party
        // recognition is restored only after the user has explicitly selected it.
        engine = savedEngine ?? .apple
    }

    var selectedModel: WhisperModel { selectedWhisperModel }
    var installedWhisperModels: Set<WhisperModel> {
        Set(installedModels.compactMap {
            if case .whisper(let model) = $0 { return model }
            return nil
        })
    }
    var selectedModelIsInstalled: Bool { installedModels.contains(selectedManagedModel) }
    var selectedManagedModel: ManagedSpeechModel { model(for: engine) }
    var isReady: Bool { engine == .apple || installedModels.contains(selectedManagedModel) }
    var supportsRealtimeMicrophone: Bool { engine.supportsRealtimeMicrophone && isReady }

    var configuration: RecognitionConfiguration {
        RecognitionConfiguration(
            engine: engine,
            whisperModel: engine == .whisper ? selectedWhisperModel : nil,
            senseVoiceModel: engine == .senseVoice ? selectedSenseVoiceModel : nil,
            parakeetModel: engine == .parakeet ? selectedParakeetModel : nil,
            computeBackend: .automatic
        )
    }

    func chooseEngine(_ newEngine: RecognitionEngine) {
        engine = newEngine
        if newEngine != .apple {
            lastThirdPartyEngine = newEngine
            UserDefaults.standard.set(newEngine.rawValue, forKey: Self.lastThirdPartyEngineKey)
        }
    }

    func chooseDefault() {
        chooseEngine(.apple)
    }

    func chooseThirdParty(fallback: RecognitionEngine = .whisper) {
        let selected = lastThirdPartyEngine == .apple ? fallback : lastThirdPartyEngine
        chooseEngine(selected)
    }

    func chooseModel(_ model: ManagedSpeechModel) {
        switch model {
        case .whisper(let whisper):
            selectedWhisperModel = whisper
            chooseEngine(.whisper)
        case .senseVoice(let senseVoice):
            selectedSenseVoiceModel = senseVoice
            chooseEngine(.senseVoice)
        case .parakeet(let parakeet):
            selectedParakeetModel = parakeet
            chooseEngine(.parakeet)
        }

        if !installedModels.contains(model) {
            download(model)
        }
    }

    func download(_ model: ManagedSpeechModel, select: Bool = true) {
        downloadTask?.cancel()
        if select { chooseModelWithoutDownloading(model) }
        downloadState = .downloading(model: model, progress: 0)

        let progressObserver = DownloadProgressObserver(preferences: self, model: model)
        downloadTask = Task { [weak self, progressObserver] in
            do {
                try await SpeechModelStore.install(model) { progress in
                    Task { @MainActor in progressObserver.update(progress: progress) }
                }
                guard !Task.isCancelled else { return }
                self?.installedModels.insert(model)
                self?.downloadState = .idle
                self?.downloadTask = nil
                if select { self?.chooseModelWithoutDownloading(model) }
            } catch is CancellationError {
                if self?.selectedManagedModel == model { self?.downloadState = .idle }
            } catch {
                self?.downloadState = .failed(model: model, message: error.localizedDescription)
                self?.downloadTask = nil
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .idle
    }

    func remove(_ model: ManagedSpeechModel) throws {
        downloadTask?.cancel()
        try SpeechModelStore.remove(model)
        installedModels.remove(model)
        if selectedManagedModel == model { downloadState = .idle }
    }

    func refreshInstalledModels() {
        installedModels = SpeechModelStore.installedModels()
    }

    fileprivate func updateDownloadProgress(for model: ManagedSpeechModel, progress: Double) {
        downloadState = .downloading(model: model, progress: progress)
    }

    static func url(for model: WhisperModel) -> URL {
        SpeechModelStore.url(for: .whisper(model))
    }

    private func model(for engine: RecognitionEngine) -> ManagedSpeechModel {
        switch engine {
        case .apple:
            return .whisper(selectedWhisperModel)
        case .whisper:
            return .whisper(selectedWhisperModel)
        case .senseVoice:
            return .senseVoice(selectedSenseVoiceModel)
        case .parakeet:
            return .parakeet(selectedParakeetModel)
        }
    }

    private func chooseModelWithoutDownloading(_ model: ManagedSpeechModel) {
        switch model {
        case .whisper(let whisper):
            selectedWhisperModel = whisper
            chooseEngine(.whisper)
        case .senseVoice(let senseVoice):
            selectedSenseVoiceModel = senseVoice
            chooseEngine(.senseVoice)
        case .parakeet(let parakeet):
            selectedParakeetModel = parakeet
            chooseEngine(.parakeet)
        }
    }
}

private final class DownloadProgressObserver: @unchecked Sendable {
    private weak var preferences: RecognitionPreferences?
    private let model: ManagedSpeechModel

    init(preferences: RecognitionPreferences, model: ManagedSpeechModel) {
        self.preferences = preferences
        self.model = model
    }

    @MainActor
    func update(progress: Double) {
        preferences?.updateDownloadProgress(for: model, progress: progress)
    }
}

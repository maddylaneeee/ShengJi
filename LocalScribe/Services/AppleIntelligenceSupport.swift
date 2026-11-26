import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability of the on-device Apple Foundation Model on this Mac.
enum AppleIntelligenceStatus: String, Equatable, Sendable, CaseIterable {
    case available
    case notEnabled
    case notReady
    case deviceNotEligible
    case osTooOld
    /// A call failed in this app session with a system error (for example a
    /// remotely changed signing policy). AFM stays disabled until relaunch.
    case blocked

    var isAvailable: Bool { self == .available }

    /// The device could run Apple Intelligence once the user enables it or the
    /// model finishes downloading.
    var isPotentiallyAvailable: Bool { self == .notEnabled || self == .notReady }

    var message: String {
        switch self {
        case .available:
            L10n.text("Apple 智能可用")
        case .notEnabled:
            L10n.text("Apple 智能未开启。可在“系统设置 > Apple 智能与 Siri”中开启。")
        case .notReady:
            L10n.text("Apple 智能模型尚未就绪，系统可能仍在下载。")
        case .deviceNotEligible:
            L10n.text("这台 Mac 不支持 Apple 智能。")
        case .osTooOld:
            L10n.text("Apple 智能需要 macOS 26 或更高版本。")
        case .blocked:
            L10n.text("Apple 智能暂时无法被声迹调用，本次运行期间已改用原有方式。")
        }
    }
}

enum AppleIntelligenceSupport {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedStatus: AppleIntelligenceStatus?
    private nonisolated(unsafe) static var blockedReason: String?
    private nonisolated(unsafe) static var statusOverride: AppleIntelligenceStatus?

    /// Current status, cached until `refresh()`.
    static var status: AppleIntelligenceStatus {
        lock.lock()
        if let statusOverride { lock.unlock(); return statusOverride }
        if blockedReason != nil { lock.unlock(); return .blocked }
        if let cachedStatus { lock.unlock(); return cachedStatus }
        lock.unlock()
        let value = systemStatus()
        lock.withLock { cachedStatus = value }
        return value
    }

    static var isAvailable: Bool { status.isAvailable }

    static var blockedDescription: String? { lock.withLock { blockedReason } }

    @discardableResult
    static func refresh() -> AppleIntelligenceStatus {
        lock.withLock { cachedStatus = nil }
        return status
    }

    /// Called when the system refuses a request in a way that will not recover
    /// within this app session.
    static func markBlocked(reason: String) {
        lock.withLock { blockedReason = reason }
    }

    /// Test and debug hook. `nil` restores the real system status.
    static func setStatusOverride(_ value: AppleIntelligenceStatus?) {
        lock.withLock {
            statusOverride = value
            blockedReason = nil
            cachedStatus = nil
        }
    }

    private static func systemStatus() -> AppleIntelligenceStatus {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LOCALSCRIBE_AFM_STATUS"],
           let value = AppleIntelligenceStatus(rawValue: raw) {
            return value
        }
#endif
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                case .deviceNotEligible: return .deviceNotEligible
                @unknown default: return .notReady
                }
            }
        }
#endif
        return .osTooOld
    }

    /// Context window shared by prompt and response, in tokens.
    static var contextSize: Int {
#if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 26.0, *) {
            let value = SystemLanguageModel.default.contextSize
            if value > 0 { return value }
        }
#endif
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 8_192 : 4_096
    }

    static func supportsLanguage(of locale: Locale) -> Bool {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.supportsLocale(locale)
        }
#endif
        return false
    }
}

/// Persisted user choice between the original local models and Apple Intelligence.
enum AIEngineMode: String, Sendable {
    case legacy
    case appleIntelligence
}

enum AIEngineMigrationDecision: Equatable, Sendable {
    case none
    case adoptSilently
    case ask
}

enum AIEngine {
    static let modeKey = "AIEngineMode.v1"
    static let promptedVersionKey = "AIEngineMigrationPromptedVersion"
    static let nllbReplacesKey = "AIEngine.NLLBReplacesAppleIntelligence"

    static func storedMode(defaults: UserDefaults = .standard) -> AIEngineMode? {
        defaults.string(forKey: modeKey).flatMap(AIEngineMode.init(rawValue:))
    }

    static func setStoredMode(_ mode: AIEngineMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// Whether Apple Intelligence powers translation and AI optimization now.
    static func usesAppleIntelligence(
        storedMode: AIEngineMode?,
        status: AppleIntelligenceStatus
    ) -> Bool {
        storedMode == .appleIntelligence && status.isAvailable
    }

    static var usesAppleIntelligence: Bool {
        usesAppleIntelligence(storedMode: storedMode(), status: AppleIntelligenceSupport.status)
    }

    static var nllbReplacesAppleIntelligence: Bool {
        UserDefaults.standard.bool(forKey: nllbReplacesKey)
    }

    static func migrationDecision(
        status: AppleIntelligenceStatus,
        storedMode: AIEngineMode?,
        hasLegacyModels: Bool,
        promptedVersion: String?,
        currentVersion: String
    ) -> AIEngineMigrationDecision {
        guard status.isAvailable, storedMode != .appleIntelligence else { return .none }
        if storedMode == nil && !hasLegacyModels { return .adoptSilently }
        return promptedVersion == currentVersion ? .none : .ask
    }

    /// The providers offered by translation pickers.
    static func selectableProviders(usesAppleIntelligence: Bool, nllbReplaces: Bool) -> [TranslationProvider] {
        if usesAppleIntelligence && !nllbReplaces { return [.apple, .appleIntelligence] }
        return [.apple, .nllb]
    }

    /// Maps a stored provider onto the item the current pickers offer.
    static func resolvedProvider(
        _ provider: TranslationProvider,
        usesAppleIntelligence: Bool,
        nllbReplaces: Bool
    ) -> TranslationProvider {
        switch provider {
        case .apple:
            return .apple
        case .nllb, .appleIntelligence:
            return usesAppleIntelligence && !nllbReplaces ? .appleIntelligence : .nllb
        }
    }
}

/// A model that the migration can delete.
struct LegacyModelItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let byteCount: Int64

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}

enum LegacyModelStore {
    static func installedItems(fileManager: FileManager = .default) -> [LegacyModelItem] {
        var items: [LegacyModelItem] = []
        for model in GemmaModel.allCases {
            let url = GemmaModelStore.url(for: model)
            if fileManager.fileExists(atPath: url.path) {
                items.append(LegacyModelItem(id: "gemma.\(model.rawValue)", title: model.title, byteCount: byteCount(at: url)))
            }
        }
        let nllbBytes = nllbDirectories.filter { fileManager.fileExists(atPath: $0.path) }
            .reduce(Int64(0)) { $0 + byteCount(at: $1) }
        if nllbBytes > 0 {
            items.append(LegacyModelItem(id: "nllb", title: NLLBModelStore.title, byteCount: nllbBytes))
        }
        return items
    }

    /// Only directories that the app itself creates and manages.
    static var managedURLs: [URL] {
        let caches = LocalScribePaths.cachesDirectory
        return [GemmaModelStore.modelsDirectory]
            + nllbDirectories
            + [
                caches.appendingPathComponent("声迹/GemmaModelDownloads", isDirectory: true),
                caches.appendingPathComponent("声迹/NLLBModelDownloads", isDirectory: true),
            ]
    }

    static var nllbDirectories: [URL] {
        let support = LocalScribePaths.applicationSupportDirectory
        return [
            NLLBModelStore.installDirectory,
            support.appendingPathComponent("声迹/Models/nllb-200-distilled-600M-int8", isDirectory: true),
        ]
    }

    /// Deletes every managed directory. Returns the paths that could not be removed.
    static func removeAll(urls: [URL] = managedURLs, fileManager: FileManager = .default) -> [String] {
        var failures: [String] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    static func byteCount(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

extension Notification.Name {
    /// Posted after the migration deletes Gemma/NLLB so model managers refresh.
    static let legacyModelsRemoved = Notification.Name("LocalScribe.legacyModelsRemoved")
    static let aiEngineChanged = Notification.Name("LocalScribe.aiEngineChanged")
}

/// UI-facing engine state and the one-time migration flow.
@MainActor
@Observable
final class AIEngineController {
    static let shared = AIEngineController()

    enum Presenter: Equatable { case mainWindow, settings }

    private(set) var status: AppleIntelligenceStatus
    private(set) var storedMode: AIEngineMode?
    var nllbReplacesAppleIntelligence: Bool {
        didSet {
            UserDefaults.standard.set(nllbReplacesAppleIntelligence, forKey: AIEngine.nllbReplacesKey)
            NotificationCenter.default.post(name: .aiEngineChanged, object: nil)
        }
    }

    private(set) var promptPresenter: Presenter?
    /// Where the latest switch was requested; errors are shown there.
    private(set) var lastPresenter: Presenter = .mainWindow
    private(set) var pendingItems: [LegacyModelItem] = []
    private(set) var isRemoving = false
    var migrationError: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = AppleIntelligenceSupport.status
        storedMode = AIEngine.storedMode(defaults: defaults)
        nllbReplacesAppleIntelligence = defaults.bool(forKey: AIEngine.nllbReplacesKey)
    }

    var usesAppleIntelligence: Bool {
        AIEngine.usesAppleIntelligence(storedMode: storedMode, status: status)
    }

    /// Stored AFM mode whose model is currently unavailable.
    var isAppleIntelligencePaused: Bool {
        storedMode == .appleIntelligence && !status.isAvailable
    }

    var selectableTranslationProviders: [TranslationProvider] {
        AIEngine.selectableProviders(
            usesAppleIntelligence: usesAppleIntelligence,
            nllbReplaces: nllbReplacesAppleIntelligence
        )
    }

    func resolvedProvider(_ provider: TranslationProvider) -> TranslationProvider {
        AIEngine.resolvedProvider(
            provider,
            usesAppleIntelligence: usesAppleIntelligence,
            nllbReplaces: nllbReplacesAppleIntelligence
        )
    }

    func refresh() {
        let previous = usesAppleIntelligence
        status = AppleIntelligenceSupport.refresh()
        storedMode = AIEngine.storedMode(defaults: defaults)
        if previous != usesAppleIntelligence {
            NotificationCenter.default.post(name: .aiEngineChanged, object: nil)
        }
    }

    /// Runs once the main window appears.
    func evaluateAtLaunch(currentVersion: String = AppInfo.version) {
        refresh()
        let items = LegacyModelStore.installedItems()
        let decision = AIEngine.migrationDecision(
            status: status,
            storedMode: storedMode,
            hasLegacyModels: !items.isEmpty,
            promptedVersion: defaults.string(forKey: AIEngine.promptedVersionKey),
            currentVersion: currentVersion
        )
        switch decision {
        case .none:
            break
        case .adoptSilently:
            setMode(.appleIntelligence)
        case .ask:
            defaults.set(currentVersion, forKey: AIEngine.promptedVersionKey)
            pendingItems = items
            lastPresenter = .mainWindow
            promptPresenter = .mainWindow
        }
    }

    /// The Settings entry point for the same confirmation.
    func requestSwitch(from presenter: Presenter) {
        refresh()
        guard status.isAvailable else { return }
        pendingItems = LegacyModelStore.installedItems()
        lastPresenter = presenter
        promptPresenter = presenter
    }

    func dismissPrompt() {
        promptPresenter = nil
        pendingItems = []
    }

    func keepLegacyModels() {
        if storedMode == nil { setMode(.legacy) }
        dismissPrompt()
    }

    func switchToAppleIntelligence() {
        guard !isRemoving else { return }
        isRemoving = true
        promptPresenter = nil
        Task {
            GemmaModelManager.shared.cancelDownload()
            NotificationCenter.default.post(name: .legacyModelsRemoved, object: nil)
            await AIOptimizationService.shared.cancelAll()
            await GemmaRuntime.shared.shutdown()
            await NLLBTranslationRuntime.shutdown()
            let failures = await Task.detached { LegacyModelStore.removeAll() }.value
            GemmaModelManager.shared.refresh()
            NotificationCenter.default.post(name: .legacyModelsRemoved, object: nil)
            if failures.isEmpty {
                nllbReplacesAppleIntelligence = false
                setMode(.appleIntelligence)
            } else {
                migrationError = L10n.format("未能删除部分旧模型，仍使用原有方式：%@", failures.joined(separator: "\n"))
            }
            pendingItems = []
            isRemoving = false
        }
    }

    private func setMode(_ mode: AIEngineMode) {
        AIEngine.setStoredMode(mode, defaults: defaults)
        storedMode = mode
        NotificationCenter.default.post(name: .aiEngineChanged, object: nil)
    }
}

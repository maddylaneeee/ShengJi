import Foundation
import Observation
import Security

enum AIServiceProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case lmStudio, openAI, deepSeek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }
    var isCloud: Bool { self != .lmStudio }
    var defaultURL: String {
        switch self {
        case .lmStudio: "http://127.0.0.1:1234/v1"
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        }
    }
    var privacyDescription: String {
        switch self {
        case .lmStudio: L10n.text("文字稿发送到本机 LM Studio；服务的其他联网行为由其设置决定。")
        case .openAI: L10n.text("AI 优化会将任务所需文字稿和附加指令发送到 OpenAI，可能产生费用。音视频不会上传。")
        case .deepSeek: L10n.text("AI 优化会将任务所需文字稿和附加指令发送到 DeepSeek，可能产生费用。音视频不会上传。")
        }
    }
}

struct AIServiceConfiguration: Codable, Equatable, Sendable {
    var provider: AIServiceProvider = .lmStudio
    var localURL = AIServiceProvider.lmStudio.defaultURL
    var modelID = ""
    var stream = true
    var cloudConsent = false

    func baseURL() throws -> URL {
        if provider.isCloud { return URL(string: provider.defaultURL)! }
        guard let parts = URLComponents(string: localURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              ["", "/", "/v1", "/v1/"].contains(parts.path),
              var normalized = URLComponents(string: localURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AIServiceError.invalidLocalURL
        }
        normalized.path = "/v1"
        guard let url = normalized.url else { throw AIServiceError.invalidLocalURL }
        return url
    }

    func modelListBlocker(key: String?) -> String? {
        do { try validate(key: key, needsModel: false, needsConsent: false); return nil }
        catch { return error.localizedDescription }
    }

    func validate(key: String?, needsModel: Bool = true, needsConsent: Bool = true) throws {
        _ = try baseURL()
        if needsModel && modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIServiceError.missingModel
        }
        if provider.isCloud && (key?.isEmpty ?? true) { throw AIServiceError.missingKey }
        if provider.isCloud && needsConsent && !cloudConsent { throw AIServiceError.consentRequired }
    }
}

enum AIServiceError: LocalizedError, Equatable {
    case invalidLocalURL, missingModel, missingKey, consentRequired, customMode, busy
    case authentication, modelUnavailable, rateLimited, timedOut, unreachable, invalidOutput, redirect
    case http(Int), keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidLocalURL: L10n.text("LM Studio 地址必须是本机回环地址，例如 http://127.0.0.1:1234/v1。")
        case .missingModel: L10n.text("请配置模型 ID。")
        case .missingKey: L10n.text("缺少 API key；请在设置中配置。")
        case .consentRequired: L10n.text("请在配置中确认云端文字稿处理及费用说明。")
        case .customMode: L10n.text("正在使用自定义服务源，不会下载或加载 Gemma。")
        case .busy: L10n.text("另一窗口正在使用 AI；请等待或在该窗口取消。")
        case .authentication: L10n.text("API 鉴权失败，请检查 key 或 LM Studio Token。")
        case .modelUnavailable: L10n.text("模型不可用或请求参数不受支持，请检查模型 ID。")
        case .rateLimited: L10n.text("API 请求受限或额度不足，请稍后重试。")
        case .timedOut: L10n.text("AI 请求超时，已保留原文。")
        case .unreachable: L10n.text("无法连接 AI 服务。请检查网络或启动本机 LM Studio 服务。")
        case .invalidOutput: L10n.text("AI 返回不完整、被拒绝或无法验证的结果，已保留原文。")
        case .redirect: L10n.text("AI 服务重定向被拒绝，请使用允许的服务地址。")
        case .http(let status): L10n.format("AI 服务请求失败（HTTP %d）。", status)
        case .keychain(let status): L10n.format("无法访问本机 Keychain（%d），配置未保存。", status)
        }
    }
}

protocol AIKeyStore {
    func read(_ provider: AIServiceProvider) throws -> String?
    func write(_ key: String?, for provider: AIServiceProvider) throws
}

struct AIKeychainStore: AIKeyStore {
    var service = "ca.lixinchen.localscribe.ai-services"
    private func query(_ provider: AIServiceProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue, kSecAttrSynchronizable as String: false]
    }
    func read(_ provider: AIServiceProvider) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AIServiceError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }
    func write(_ key: String?, for provider: AIServiceProvider) throws {
        let request = query(provider)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AIServiceError.keychain(status) }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var addition = request.merging(values) { _, new in new }
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIServiceError.keychain(status) }
    }
}

/// Serializes mode changes with the final model-install/process-start boundary.
/// Never stores credentials. All UI writes go through AIServicePreferences.
enum AIServiceMode {
    static let defaultsKey = "UseCustomAIService"
    private static let lock = NSLock()
    static var usesCustomService: Bool { lock.withLock { UserDefaults.standard.bool(forKey: defaultsKey) } }
    static func setEnabled(_ enabled: Bool) { lock.withLock { UserDefaults.standard.set(enabled, forKey: defaultsKey) } }
    static func withBuiltInAllowed<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard !UserDefaults.standard.bool(forKey: defaultsKey) else { throw AIServiceError.customMode }
            return try operation()
        }
    }
}

@MainActor @Observable
final class AIServicePreferences {
    static let shared = AIServicePreferences()
    static let configurationsKey = "AIServiceConfigurations.v1"
    private let defaults: UserDefaults
    private let keys: any AIKeyStore
    private let controlsRuntime: Bool
    private let downloads: GemmaModelManager?
    private(set) var isEnabled: Bool
    private(set) var provider: AIServiceProvider
    private(set) var revision = UUID()
    private var configurations: [String: AIServiceConfiguration]
    init(defaults: UserDefaults = .standard, keys: any AIKeyStore = AIKeychainStore(), controlsRuntime: Bool = true, downloads: GemmaModelManager? = nil) {
        self.defaults = defaults
        self.keys = keys
        self.controlsRuntime = controlsRuntime
        self.downloads = downloads
        isEnabled = defaults.bool(forKey: AIServiceMode.defaultsKey)
        provider = AIServiceProvider(rawValue: defaults.string(forKey: "AIServiceProvider") ?? "") ?? .lmStudio
        configurations = defaults.data(forKey: Self.configurationsKey)
            .flatMap { try? JSONDecoder().decode([String: AIServiceConfiguration].self, from: $0) } ?? [:]
    }
    var configuration: AIServiceConfiguration { configuration(for: provider) }
    func configuration(for provider: AIServiceProvider) -> AIServiceConfiguration {
        configurations[provider.rawValue] ?? AIServiceConfiguration(provider: provider)
    }
    func key(for provider: AIServiceProvider) throws -> String? { try keys.read(provider) }
    var readinessError: String? {
        do { try configuration.validate(key: key(for: provider)); return nil }
        catch { return error.localizedDescription }
    }
    var privacyDescription: String {
        isEnabled ? provider.privacyDescription : L10n.text("AI 在本机运行，文字稿不会发送给云端 AI 服务。")
    }
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        if controlsRuntime { AIServiceMode.setEnabled(enabled) }
        else { defaults.set(enabled, forKey: AIServiceMode.defaultsKey) }
        isEnabled = enabled
        invalidateTasks()
    }
    /// nil preserves an existing key; an empty string explicitly deletes it.
    func save(_ configuration: AIServiceConfiguration, replacementKey: String? = nil) throws {
        _ = try configuration.baseURL()
        var updated = configurations
        updated[configuration.provider.rawValue] = configuration
        let encoded = try JSONEncoder().encode(updated)
        if let replacementKey { try keys.write(replacementKey.trimmingCharacters(in: .whitespacesAndNewlines), for: configuration.provider) }
        defaults.set(encoded, forKey: Self.configurationsKey)
        defaults.set(configuration.provider.rawValue, forKey: "AIServiceProvider")
        configurations = updated
        provider = configuration.provider
        invalidateTasks()
    }
    func makeClient() throws -> OpenAICompatibleClient {
        guard isEnabled else { throw AIServiceError.customMode }
        let key = try key(for: provider)
        try configuration.validate(key: key)
        return OpenAICompatibleClient(configuration: configuration, key: key)
    }
    private func invalidateTasks() {
        let obsoleteRevision = revision
        revision = UUID()
        if controlsRuntime {
            (downloads ?? GemmaModelManager.shared).cancelDownload()
            // Terminate only processes owned by LocalScribe, never LM Studio.
            GemmaProcessRegistry.terminateAll()
            Task { await AIOptimizationService.shared.cancelConfiguration(revision: obsoleteRevision) }
        }
    }
}

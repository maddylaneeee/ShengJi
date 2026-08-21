import Foundation

enum RealtimeAudioSourceID: Hashable, Codable, Sendable, Identifiable {
    case systemAudio
    case systemDefaultMicrophone
    case inputDevice(uid: String)

    var id: String {
        switch self {
        case .systemAudio: "system-audio"
        case .systemDefaultMicrophone: "system-default-microphone"
        case .inputDevice(let uid): "input-device:\(uid)"
        }
    }

    var requiresInputDevice: Bool {
        switch self {
        case .systemDefaultMicrophone, .inputDevice: true
        case .systemAudio: false
        }
    }
}

struct AudioInputDevice: Hashable, Sendable, Identifiable {
    let uid: String
    let systemID: UInt32
    let name: String
    let manufacturer: String?
    let inputChannelCount: Int
    let isAlive: Bool
    let isHidden: Bool
    var displayName: String

    var id: String { uid }

    init(
        uid: String,
        systemID: UInt32,
        name: String,
        manufacturer: String? = nil,
        inputChannelCount: Int,
        isAlive: Bool = true,
        isHidden: Bool = false,
        displayName: String? = nil
    ) {
        self.uid = uid
        self.systemID = systemID
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannelCount = inputChannelCount
        self.isAlive = isAlive
        self.isHidden = isHidden
        self.displayName = displayName ?? name
    }

    var isEligibleInput: Bool {
        isAlive && !isHidden && inputChannelCount > 0 && !uid.isEmpty
    }
}

struct RealtimeAudioSourcePreferenceResolution: Equatable, Sendable {
    let selectedSource: RealtimeAudioSourceID
    let didFallBackFromUnavailableDevice: Bool
}

enum RealtimeAudioSourcePreferencePolicy {
    static func resolve(
        persistedSource: RealtimeAudioSourceID?,
        availableDevices: [AudioInputDevice]
    ) -> RealtimeAudioSourcePreferenceResolution {
        guard let persistedSource else {
            return .init(selectedSource: .systemDefaultMicrophone, didFallBackFromUnavailableDevice: false)
        }

        if case .inputDevice(let uid) = persistedSource,
           !availableDevices.contains(where: { $0.uid == uid && $0.isEligibleInput }) {
            return .init(selectedSource: .systemDefaultMicrophone, didFallBackFromUnavailableDevice: true)
        }

        return .init(selectedSource: persistedSource, didFallBackFromUnavailableDevice: false)
    }
}

protocol RealtimeAudioSourcePreferenceStoring: Sendable {
    func load() -> RealtimeAudioSourceID?
    func saveSuccessfullyStartedSource(_ source: RealtimeAudioSourceID)
}

final class UserDefaultsRealtimeAudioSourcePreferenceStore: RealtimeAudioSourcePreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "RealtimeAudioSourceID") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> RealtimeAudioSourceID? {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(RealtimeAudioSourceID.self, from: data)
        }
    }

    func saveSuccessfullyStartedSource(_ source: RealtimeAudioSourceID) {
        guard let data = try? JSONEncoder().encode(source) else { return }
        lock.withLock { defaults.set(data, forKey: key) }
    }
}

enum RealtimeAudioPermission: Equatable, Sendable {
    case microphone
    case screenAndSystemAudioRecording
}

enum RealtimeAudioPermissionDecision {
    static func requiredPermission(for source: RealtimeAudioSourceID) -> RealtimeAudioPermission {
        switch source {
        case .systemAudio: .screenAndSystemAudioRecording
        case .systemDefaultMicrophone, .inputDevice: .microphone
        }
    }

    static func mayRequestMicrophone(for source: RealtimeAudioSourceID) -> Bool {
        requiredPermission(for: source) == .microphone
    }

    static func mayStartScreenCapture(for source: RealtimeAudioSourceID) -> Bool {
        requiredPermission(for: source) == .screenAndSystemAudioRecording
    }
}

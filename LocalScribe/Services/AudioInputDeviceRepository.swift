import CoreAudio
import Foundation

enum AudioInputDeviceRepositoryError: LocalizedError {
    case coreAudio(OSStatus, String)
    case missingDefaultInputDevice
    case unavailableDevice(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status, let operation):
            "\(operation) failed (CoreAudio \(status))."
        case .missingDefaultInputDevice:
            "No system default input device is available."
        case .unavailableDevice:
            "The selected input device is unavailable."
        }
    }
}

protocol AudioDeviceChangeObservation: AnyObject, Sendable {
    func cancel()
}

protocol AudioDeviceHardwareProviding: Sendable {
    func allDevices() throws -> [AudioInputDevice]
    func defaultInputDeviceSystemID() throws -> UInt32?
    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) throws -> any AudioDeviceChangeObservation
}

final class AudioInputDeviceRepository: @unchecked Sendable {
    private let hardware: any AudioDeviceHardwareProviding

    init(hardware: any AudioDeviceHardwareProviding = CoreAudioDeviceHardwareProvider()) {
        self.hardware = hardware
    }

    func availableInputDevices() throws -> [AudioInputDevice] {
        Self.filteredSortedAndDisambiguated(try hardware.allDevices())
    }

    func resolveSystemID(for source: RealtimeAudioSourceID) throws -> UInt32 {
        switch source {
        case .systemAudio:
            throw AudioInputDeviceRepositoryError.unavailableDevice(source.id)
        case .systemDefaultMicrophone:
            guard let id = try hardware.defaultInputDeviceSystemID(),
                  try availableInputDevices().contains(where: { $0.systemID == id }) else {
                throw AudioInputDeviceRepositoryError.missingDefaultInputDevice
            }
            return id
        case .inputDevice(let uid):
            guard let device = try availableInputDevices().first(where: { $0.uid == uid }) else {
                throw AudioInputDeviceRepositoryError.unavailableDevice(uid)
            }
            return device.systemID
        }
    }

    func observeChanges(_ handler: @escaping @Sendable ([AudioInputDevice]) -> Void) throws -> any AudioDeviceChangeObservation {
        try hardware.observeDeviceChanges { [weak self] in
            guard let self, let devices = try? self.availableInputDevices() else { return }
            handler(devices)
        }
    }

    static func filteredSortedAndDisambiguated(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        let eligible = devices
            .filter(\.isEligibleInput)
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return $0.uid.localizedStandardCompare($1.uid) == .orderedAscending
            }

        let groups = Dictionary(grouping: eligible.indices) {
            eligible[$0].name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        var output = eligible

        for indices in groups.values where indices.count > 1 {
            let manufacturers = Set(indices.compactMap { normalizedManufacturer(eligible[$0].manufacturer) })
            let canUseManufacturer = manufacturers.count == indices.count
            for (ordinal, index) in indices.enumerated() {
                if canUseManufacturer, let manufacturer = normalizedManufacturer(eligible[index].manufacturer) {
                    output[index].displayName = "\(eligible[index].name) — \(manufacturer)"
                } else {
                    output[index].displayName = "\(eligible[index].name) (\(ordinal + 1))"
                }
            }
        }
        return output
    }

    private static func normalizedManufacturer(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

final class CoreAudioDeviceHardwareProvider: AudioDeviceHardwareProviding, @unchecked Sendable {
    func allDevices() throws -> [AudioInputDevice] {
        try readDeviceIDs().compactMap { id in
            guard let uid = try readString(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID,
                operation: "Read audio device UID"
            ), let name = try readString(
                objectID: id,
                selector: kAudioObjectPropertyName,
                operation: "Read audio device name"
            ) else {
                return nil
            }

            let manufacturer = try readString(
                objectID: id,
                selector: kAudioObjectPropertyManufacturer,
                operation: "Read audio device manufacturer",
                required: false
            )
            let isAlive = try readUInt32(
                objectID: id,
                selector: kAudioDevicePropertyDeviceIsAlive,
                defaultValue: 1
            ) != 0
            let isHidden = try readUInt32(
                objectID: id,
                selector: kAudioDevicePropertyIsHidden,
                defaultValue: 0
            ) != 0
            let channels = try inputChannelCount(deviceID: id)
            return AudioInputDevice(
                uid: uid,
                systemID: id,
                name: name,
                manufacturer: manufacturer,
                inputChannelCount: channels,
                isAlive: isAlive,
                isHidden: isHidden
            )
        }
    }

    func defaultInputDeviceSystemID() throws -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else { return nil }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        try check(status, operation: "Read default input device")
        return id == kAudioObjectUnknown ? nil : id
    }

    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) throws -> any AudioDeviceChangeObservation {
        let queue = DispatchQueue(label: "ca.lixinchen.localscribe.audio-device-observer")
        let devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveRegistrations: [(AudioObjectID, AudioObjectPropertyAddress)] = try readDeviceIDs().compactMap { deviceID in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return nil }
            return (deviceID, address)
        }
        let observation = CoreAudioChangeObservation(
            registrations: [
                (AudioObjectID(kAudioObjectSystemObject), devicesAddress),
                (AudioObjectID(kAudioObjectSystemObject), defaultAddress)
            ] + aliveRegistrations,
            queue: queue,
            handler: handler
        )
        try observation.start()
        return observation
    }

    private func readDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
            operation: "Read audio device list size"
        )
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
            operation: "Read audio device list"
        )
        return ids
    }

    private func inputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "Read input stream configuration size"
        )
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list),
            operation: "Read input stream configuration"
        )
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: UInt32
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return defaultValue }
        var value = defaultValue
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "Read audio device property \(selector)"
        )
        return value
    }

    private func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String,
        required: Bool = true
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            if required { throw AudioInputDeviceRepositoryError.coreAudio(kAudioHardwareUnknownPropertyError, operation) }
            return nil
        }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        if status != noErr, !required { return nil }
        try check(status, operation: operation)
        return value?.takeRetainedValue() as String?
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw AudioInputDeviceRepositoryError.coreAudio(status, operation) }
    }
}

private final class CoreAudioChangeObservation: AudioDeviceChangeObservation, @unchecked Sendable {
    private let registrations: [(AudioObjectID, AudioObjectPropertyAddress)]
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var isStarted = false

    init(
        registrations: [(AudioObjectID, AudioObjectPropertyAddress)],
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.registrations = registrations
        self.queue = queue
        self.listener = { _, _ in handler() }
    }

    func start() throws {
        try lock.withLock {
            guard !isStarted else { return }
            var installed: [(AudioObjectID, AudioObjectPropertyAddress)] = []
            do {
                for (objectID, storedAddress) in registrations {
                    var address = storedAddress
                    let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
                    guard status == noErr else {
                        throw AudioInputDeviceRepositoryError.coreAudio(status, "Observe audio device changes")
                    }
                    installed.append((objectID, address))
                }
                isStarted = true
            } catch {
                for (objectID, storedAddress) in installed {
                    var address = storedAddress
                    AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
                }
                throw error
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard isStarted else { return }
            for (objectID, storedAddress) in registrations {
                var address = storedAddress
                AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
            }
            isStarted = false
        }
    }

    deinit { cancel() }
}

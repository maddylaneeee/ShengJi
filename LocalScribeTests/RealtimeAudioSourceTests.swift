import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import LocalScribe

final class RealtimeAudioSourceTests: XCTestCase {
    func testDeviceRepositoryFiltersOutputsHiddenAndDeadDevices() throws {
        let hardware = FakeAudioDeviceHardware(devices: [
            device(uid: "good", id: 1, name: "USB Mic", channels: 2),
            device(uid: "output", id: 2, name: "HDMI", channels: 0),
            device(uid: "dead", id: 3, name: "Old Mic", channels: 1, isAlive: false),
            device(uid: "hidden", id: 4, name: "Hidden Mic", channels: 1, isHidden: true),
            device(uid: "", id: 5, name: "Missing UID", channels: 1)
        ])

        let devices = try AudioInputDeviceRepository(hardware: hardware).availableInputDevices()

        XCTAssertEqual(devices.map(\.uid), ["good"])
    }

    func testDeviceRepositorySortsNamesAndDisambiguatesDuplicates() throws {
        let hardware = FakeAudioDeviceHardware(devices: [
            device(uid: "z", id: 3, name: "zoom", manufacturer: "Zeta", channels: 1),
            device(uid: "a", id: 2, name: "Studio Mic", manufacturer: "Acme", channels: 1),
            device(uid: "b", id: 1, name: "studio mic", manufacturer: "Beta", channels: 1)
        ])

        let devices = try AudioInputDeviceRepository(hardware: hardware).availableInputDevices()

        XCTAssertEqual(devices.map(\.uid), ["a", "b", "z"])
        XCTAssertEqual(devices[0].displayName, "Studio Mic — Acme")
        XCTAssertEqual(devices[1].displayName, "studio mic — Beta")
        XCTAssertEqual(devices[2].displayName, "zoom")
    }

    func testDuplicateNamesFallBackToStableOrdinalsWhenManufacturerCannotDisambiguate() throws {
        let hardware = FakeAudioDeviceHardware(devices: [
            device(uid: "b", id: 2, name: "Microphone", manufacturer: "Same", channels: 1),
            device(uid: "a", id: 1, name: "Microphone", manufacturer: "Same", channels: 1)
        ])

        let devices = try AudioInputDeviceRepository(hardware: hardware).availableInputDevices()

        XCTAssertEqual(devices.map(\.uid), ["a", "b"])
        XCTAssertEqual(devices.map(\.displayName), ["Microphone (1)", "Microphone (2)"])
    }

    func testDefaultAndSpecifiedDeviceResolutionUsesCurrentHardwareState() throws {
        let hardware = FakeAudioDeviceHardware(
            devices: [device(uid: "mic-a", id: 41, name: "Mic A", channels: 1)],
            defaultID: 41
        )
        let repository = AudioInputDeviceRepository(hardware: hardware)

        XCTAssertEqual(try repository.resolveSystemID(for: .systemDefaultMicrophone), 41)
        XCTAssertEqual(try repository.resolveSystemID(for: .inputDevice(uid: "mic-a")), 41)
        XCTAssertThrowsError(try repository.resolveSystemID(for: .inputDevice(uid: "missing")))
    }

    func testPreferencePolicyDefaultsAndFallsBackOnlyForUnavailableSpecificDevice() {
        let devices = [device(uid: "mic-a", id: 1, name: "Mic A", channels: 1)]

        XCTAssertEqual(
            RealtimeAudioSourcePreferencePolicy.resolve(persistedSource: nil, availableDevices: devices),
            .init(selectedSource: .systemDefaultMicrophone, didFallBackFromUnavailableDevice: false)
        )
        XCTAssertEqual(
            RealtimeAudioSourcePreferencePolicy.resolve(
                persistedSource: .inputDevice(uid: "mic-a"),
                availableDevices: devices
            ),
            .init(selectedSource: .inputDevice(uid: "mic-a"), didFallBackFromUnavailableDevice: false)
        )
        XCTAssertEqual(
            RealtimeAudioSourcePreferencePolicy.resolve(
                persistedSource: .inputDevice(uid: "missing"),
                availableDevices: devices
            ),
            .init(selectedSource: .systemDefaultMicrophone, didFallBackFromUnavailableDevice: true)
        )
        XCTAssertEqual(
            RealtimeAudioSourcePreferencePolicy.resolve(persistedSource: .systemAudio, availableDevices: []),
            .init(selectedSource: .systemAudio, didFallBackFromUnavailableDevice: false)
        )
    }

    func testPermissionDecisionNeverCrossRequestsSourcePermission() {
        XCTAssertEqual(
            RealtimeAudioPermissionDecision.requiredPermission(for: .systemAudio),
            .screenAndSystemAudioRecording
        )
        XCTAssertFalse(RealtimeAudioPermissionDecision.mayRequestMicrophone(for: .systemAudio))
        XCTAssertTrue(RealtimeAudioPermissionDecision.mayStartScreenCapture(for: .systemAudio))

        for source in [RealtimeAudioSourceID.systemDefaultMicrophone, .inputDevice(uid: "mic-a")] {
            XCTAssertEqual(RealtimeAudioPermissionDecision.requiredPermission(for: source), .microphone)
            XCTAssertTrue(RealtimeAudioPermissionDecision.mayRequestMicrophone(for: source))
            XCTAssertFalse(RealtimeAudioPermissionDecision.mayStartScreenCapture(for: source))
        }
    }

    func testCallbackGateDropsLateAndWrongSessionBuffers() throws {
        let gate = RealtimeAudioCaptureCallbackGate()
        let expectedSession = UUID()
        let wrongSession = UUID()
        let received = LockedValues<UUID>()
        let (_, continuation) = makeFirstBufferStream()
        gate.activate(
            sessionID: expectedSession,
            onBuffer: { received.append($0.sessionID) },
            onError: { _ in },
            firstBufferContinuation: continuation
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        gate.accept(buffer: buffer, sessionID: wrongSession)
        gate.accept(buffer: buffer, sessionID: expectedSession)
        gate.invalidate(sessionID: expectedSession)
        gate.accept(buffer: buffer, sessionID: expectedSession)

        XCTAssertEqual(received.values, [expectedSession])
    }

    @MainActor
    func testDefaultMicrophoneCaptureDoesNotBindSpecificCoreAudioDevice() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let builder = DefaultRealtimeAudioCaptureBuilder()

        let defaultCapture = try XCTUnwrap(
            builder.makeDefaultInputCapture(targetFormat: format) as? InputDeviceAudioCapture
        )
        let specificCapture = try XCTUnwrap(
            builder.makeSpecificInputCapture(systemID: 42, targetFormat: format) as? InputDeviceAudioCapture
        )

        XCTAssertTrue(defaultCapture.usesSystemDefaultDeviceForTesting)
        XCTAssertFalse(specificCapture.usesSystemDefaultDeviceForTesting)
    }

    func testScreenCaptureErrorsKeepPermissionAndStartupCategories() throws {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let missingEntitlement = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.missingEntitlements.rawValue
        )
        let failedAudio = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStartAudioCapture.rawValue
        )

        XCTAssertEqual(
            SystemAudioCapture.classifiedError(denied) as? RealtimeAudioCaptureError,
            .screenRecordingPermissionDenied
        )
        XCTAssertEqual(
            SystemAudioCapture.classifiedError(missingEntitlement) as? RealtimeAudioCaptureError,
            .missingScreenCaptureEntitlement
        )
        XCTAssertEqual(
            SystemAudioCapture.classifiedError(failedAudio) as? RealtimeAudioCaptureError,
            .failedToStartSystemAudio
        )
    }

    func testAudioLevelEstimatorSupportsFloatAndIntegerRecognitionFormats() throws {
        let floatFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let floatBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 4))
        floatBuffer.frameLength = 4
        floatBuffer.floatChannelData?[0][0] = 0.5
        floatBuffer.floatChannelData?[0][1] = -0.5
        floatBuffer.floatChannelData?[0][2] = 0.5
        floatBuffer.floatChannelData?[0][3] = -0.5

        let int16Format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 2,
            interleaved: true
        ))
        let int16Buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 2))
        int16Buffer.frameLength = 2
        for index in 0..<4 {
            int16Buffer.int16ChannelData?[0][index] = index.isMultiple(of: 2) ? 16_384 : -16_384
        }

        let int32Format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let int32Buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: int32Format, frameCapacity: 2))
        int32Buffer.frameLength = 2
        for channel in 0..<2 {
            int32Buffer.int32ChannelData?[channel][0] = 1_073_741_824
            int32Buffer.int32ChannelData?[channel][1] = -1_073_741_824
        }

        let levels = [floatBuffer, int16Buffer, int32Buffer].map(AudioLevelEstimator.normalizedLevel)
        for level in levels {
            XCTAssertEqual(level, 0.899656, accuracy: 0.001)
        }
    }

    func testAudioLevelEstimatorReturnsZeroForSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32

        XCTAssertEqual(AudioLevelEstimator.normalizedLevel(from: buffer), 0)
    }

    private func device(
        uid: String,
        id: UInt32,
        name: String,
        manufacturer: String? = nil,
        channels: Int,
        isAlive: Bool = true,
        isHidden: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            uid: uid,
            systemID: id,
            name: name,
            manufacturer: manufacturer,
            inputChannelCount: channels,
            isAlive: isAlive,
            isHidden: isHidden
        )
    }

    private func makeFirstBufferStream() -> (
        AsyncThrowingStream<Void, Error>,
        AsyncThrowingStream<Void, Error>.Continuation
    ) {
        var storedContinuation: AsyncThrowingStream<Void, Error>.Continuation?
        let stream = AsyncThrowingStream<Void, Error> { storedContinuation = $0 }
        return (stream, storedContinuation!)
    }
}

private final class FakeAudioDeviceHardware: AudioDeviceHardwareProviding, @unchecked Sendable {
    var devices: [AudioInputDevice]
    var defaultID: UInt32?

    init(devices: [AudioInputDevice], defaultID: UInt32? = nil) {
        self.devices = devices
        self.defaultID = defaultID
    }

    func allDevices() throws -> [AudioInputDevice] { devices }
    func defaultInputDeviceSystemID() throws -> UInt32? { defaultID }

    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) throws -> any AudioDeviceChangeObservation {
        FakeAudioDeviceObservation()
    }
}

private final class FakeAudioDeviceObservation: AudioDeviceChangeObservation, @unchecked Sendable {
    func cancel() {}
}

private final class LockedValues<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] { lock.withLock { storage } }
    func append(_ value: Element) { lock.withLock { storage.append(value) } }
}

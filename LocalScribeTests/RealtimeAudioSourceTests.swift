import AVFoundation
import ScreenCaptureKit
import XCTest
@testable import LocalScribe

final class RealtimeAudioSourceTests: XCTestCase {
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

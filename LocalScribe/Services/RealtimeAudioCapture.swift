import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

struct RealtimeAudioCaptureBuffer: @unchecked Sendable {
    let sessionID: UUID
    let buffer: AVAudioPCMBuffer
}

enum AudioLevelEstimator {
    nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        var sampleCount = 0

        func accumulate(_ value: Double) {
            guard value.isFinite else { return }
            let bounded = min(max(value, -1), 1)
            sumOfSquares += bounded * bounded
            sampleCount += 1
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            if buffer.format.isInterleaved {
                for index in 0..<(frameCount * channelCount) {
                    accumulate(Double(channels[0][index]))
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        accumulate(Double(channels[channel][frame]))
                    }
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            let scale = Double(Int16.max)
            if buffer.format.isInterleaved {
                for index in 0..<(frameCount * channelCount) {
                    accumulate(Double(channels[0][index]) / scale)
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        accumulate(Double(channels[channel][frame]) / scale)
                    }
                }
            }
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return 0 }
            let scale = Double(Int32.max)
            if buffer.format.isInterleaved {
                for index in 0..<(frameCount * channelCount) {
                    accumulate(Double(channels[0][index]) / scale)
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        accumulate(Double(channels[channel][frame]) / scale)
                    }
                }
            }
        default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

enum RealtimeAudioCaptureError: LocalizedError, Equatable {
    case alreadyRunning
    case stoppedBeforeFirstBuffer
    case firstBufferTimedOut
    case unavailableInputDevice
    case invalidAudioFormat
    case invalidAudioBuffer
    case noCapturableDisplay
    case screenRecordingPermissionDenied
    case screenRecordingPermissionRequiresRestart
    case missingScreenCaptureEntitlement
    case failedToStartSystemAudio
    case coreAudio(OSStatus)
    case screenCapture(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "An audio capture session is already running."
        case .stoppedBeforeFirstBuffer: "Audio capture stopped before receiving audio."
        case .firstBufferTimedOut: "No audio buffer arrived within two seconds."
        case .unavailableInputDevice: "The selected audio input device is unavailable."
        case .invalidAudioFormat: "The audio source returned an invalid format."
        case .invalidAudioBuffer: "The audio source returned an invalid buffer."
        case .noCapturableDisplay: "No display is available for system audio capture."
        case .screenRecordingPermissionDenied: "Screen and system audio recording permission was denied."
        case .screenRecordingPermissionRequiresRestart: "Restart the app to use the newly granted screen and system audio recording permission."
        case .missingScreenCaptureEntitlement: "The app is not entitled to start screen and system audio capture."
        case .failedToStartSystemAudio: "The system audio stream failed to start."
        case .coreAudio(let status): "CoreAudio failed with status \(status)."
        case .screenCapture(let message): "System audio capture stopped: \(message)"
        }
    }
}

@MainActor
protocol RealtimeAudioCapturing: AnyObject {
    var sessionID: UUID? { get }
    var isRunning: Bool { get }

    @discardableResult
    func start(
        onBuffer: @escaping @Sendable (RealtimeAudioCaptureBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> UUID

    func stop() async
}

@MainActor
protocol RealtimeAudioCaptureBuilding {
    func makeDefaultInputCapture(targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing
    func makeSpecificInputCapture(systemID: UInt32, targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing
    func makeSystemAudioCapture(targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing
}

@MainActor
struct DefaultRealtimeAudioCaptureBuilder: RealtimeAudioCaptureBuilding {
    func makeDefaultInputCapture(targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing {
        InputDeviceAudioCapture(deviceID: nil, targetFormat: targetFormat)
    }

    func makeSpecificInputCapture(systemID: UInt32, targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing {
        InputDeviceAudioCapture(deviceID: AudioDeviceID(systemID), targetFormat: targetFormat)
    }

    func makeSystemAudioCapture(targetFormat: AVAudioFormat) -> any RealtimeAudioCapturing {
        SystemAudioCapture(targetFormat: targetFormat)
    }
}

@MainActor
final class InputDeviceAudioCapture: RealtimeAudioCapturing {
    private let deviceID: AudioDeviceID?
    private let targetFormat: AVAudioFormat
    private let callbackGate = RealtimeAudioCaptureCallbackGate()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var hasTap = false

    private(set) var sessionID: UUID?
    var isRunning: Bool { engine?.isRunning == true }
    var usesSystemDefaultDeviceForTesting: Bool { deviceID == nil }

    init(deviceID: AudioDeviceID?, targetFormat: AVAudioFormat) {
        self.deviceID = deviceID
        self.targetFormat = targetFormat
    }

    @discardableResult
    func start(
        onBuffer: @escaping @Sendable (RealtimeAudioCaptureBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> UUID {
        guard engine == nil else { throw RealtimeAudioCaptureError.alreadyRunning }
        guard Self.isValid(format: targetFormat) else { throw RealtimeAudioCaptureError.invalidAudioFormat }

        let sessionID = UUID()
        let (firstBufferStream, firstBufferContinuation) = Self.makeFirstBufferStream()
        callbackGate.activate(
            sessionID: sessionID,
            onBuffer: onBuffer,
            onError: onError,
            firstBufferContinuation: firstBufferContinuation
        )

        let engine = AVAudioEngine()
        do {
            if let deviceID {
                try Self.bind(engine: engine, to: deviceID)
            }
            let inputNode = engine.inputNode
            let sourceFormat = inputNode.outputFormat(forBus: 0)
            guard Self.isValid(format: sourceFormat) else {
                throw RealtimeAudioCaptureError.invalidAudioFormat
            }
            let converter = sourceFormat == targetFormat
                ? nil
                : AVAudioConverter(from: sourceFormat, to: targetFormat)
            if sourceFormat != targetFormat, converter == nil {
                throw RealtimeAudioCaptureError.invalidAudioFormat
            }

            self.engine = engine
            self.converter = converter
            self.sessionID = sessionID
            inputNode.installTap(onBus: 0, bufferSize: 4_096, format: sourceFormat) {
                [callbackGate, converter, targetFormat] input, _ in
                do {
                    guard Self.isValid(buffer: input) else {
                        throw RealtimeAudioCaptureError.invalidAudioBuffer
                    }
                    let output = if let converter {
                        try Self.convert(input, using: converter, to: targetFormat)
                    } else {
                        input
                    }
                    guard Self.isValid(buffer: output) else {
                        throw RealtimeAudioCaptureError.invalidAudioBuffer
                    }
                    callbackGate.accept(buffer: output, sessionID: sessionID)
                } catch {
                    callbackGate.reject(error: error, sessionID: sessionID)
                }
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            try await Self.awaitFirstBuffer(firstBufferStream)
            return sessionID
        } catch {
            cleanup(sessionID: sessionID)
            throw error
        }
    }

    func stop() async {
        guard let sessionID else { return }
        cleanup(sessionID: sessionID)
    }

    static func bind(engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw RealtimeAudioCaptureError.unavailableInputDevice
        }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout.size(ofValue: selectedDevice))
        )
        guard status == noErr else { throw RealtimeAudioCaptureError.coreAudio(status) }
    }

    private func cleanup(sessionID: UUID) {
        callbackGate.invalidate(sessionID: sessionID)
        if hasTap, let engine {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine?.stop()
        engine = nil
        converter = nil
        if self.sessionID == sessionID { self.sessionID = nil }
    }

    nonisolated private static func isValid(format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
    }

    nonisolated private static func isValid(buffer: AVAudioPCMBuffer) -> Bool {
        isValid(format: buffer.format)
            && buffer.frameLength > 0
            && buffer.frameLength <= buffer.frameCapacity
            && buffer.frameLength <= 1_000_000
    }

    nonisolated fileprivate static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard capacity > 0, capacity <= 1_000_000,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw RealtimeAudioCaptureError.invalidAudioBuffer
        }
        let provider = RealtimeAudioConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? RealtimeAudioCaptureError.invalidAudioFormat
        }
        return output
    }

    fileprivate static func makeFirstBufferStream() -> (
        AsyncThrowingStream<Void, Error>,
        AsyncThrowingStream<Void, Error>.Continuation
    ) {
        var storedContinuation: AsyncThrowingStream<Void, Error>.Continuation?
        let stream = AsyncThrowingStream<Void, Error> { storedContinuation = $0 }
        return (stream, storedContinuation!)
    }

    fileprivate static func awaitFirstBuffer(_ stream: AsyncThrowingStream<Void, Error>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in stream { return }
                throw RealtimeAudioCaptureError.stoppedBeforeFirstBuffer
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw RealtimeAudioCaptureError.firstBufferTimedOut
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }
}

private final class RealtimeAudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard let input else {
                status.pointee = .noDataNow
                return nil
            }
            self.input = nil
            status.pointee = .haveData
            return input
        }
    }
}

@MainActor
final class SystemAudioCapture: RealtimeAudioCapturing {
    private let targetFormat: AVAudioFormat
    private let bundleIdentifier: String?
    private let callbackGate = RealtimeAudioCaptureCallbackGate()
    private let outputQueue = DispatchQueue(label: "ca.lixinchen.localscribe.realtime-system-audio")
    private var stream: SCStream?
    private var output: RealtimeScreenAudioOutput?
    private var streamDelegate: RealtimeScreenAudioStreamDelegate?

    private(set) var sessionID: UUID?
    var isRunning: Bool { stream != nil }

    init(targetFormat: AVAudioFormat, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.targetFormat = targetFormat
        self.bundleIdentifier = bundleIdentifier
    }

    @discardableResult
    func start(
        onBuffer: @escaping @Sendable (RealtimeAudioCaptureBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async throws -> UUID {
        guard sessionID == nil else { throw RealtimeAudioCaptureError.alreadyRunning }
        guard targetFormat.sampleRate.isFinite,
              targetFormat.sampleRate > 0,
              targetFormat.channelCount > 0 else {
            throw RealtimeAudioCaptureError.invalidAudioFormat
        }

        let sessionID = UUID()
        let (_, firstBufferContinuation) = InputDeviceAudioCapture.makeFirstBufferStream()
        callbackGate.activate(
            sessionID: sessionID,
            onBuffer: onBuffer,
            onError: onError,
            firstBufferContinuation: firstBufferContinuation
        )
        self.sessionID = sessionID

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard self.sessionID == sessionID else {
                throw RealtimeAudioCaptureError.stoppedBeforeFirstBuffer
            }
            guard let display = content.displays.first else {
                throw RealtimeAudioCaptureError.noCapturableDisplay
            }
            let excludedApplications = content.applications.filter {
                guard let bundleIdentifier else { return false }
                return $0.bundleIdentifier == bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(targetFormat.sampleRate)
            configuration.channelCount = Int(targetFormat.channelCount)

            let output = RealtimeScreenAudioOutput(
                sessionID: sessionID,
                targetFormat: targetFormat,
                callbackGate: callbackGate
            )
            let delegate = RealtimeScreenAudioStreamDelegate { [callbackGate] error in
                callbackGate.reject(
                    error: Self.classifiedError(error),
                    sessionID: sessionID
                )
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            self.output = output
            self.streamDelegate = delegate
            self.stream = stream
            try await stream.startCapture()
            // A running stream may emit no audio sample while the Mac is silent.
            // Stream startup, not the first nonempty buffer, is this source's
            // readiness boundary.
            return sessionID
        } catch {
            await cleanup(sessionID: sessionID)
            throw Self.classifiedError(error)
        }
    }

    func stop() async {
        guard let sessionID else { return }
        await cleanup(sessionID: sessionID)
    }

    private func cleanup(sessionID: UUID) async {
        callbackGate.invalidate(sessionID: sessionID)
        let activeStream = stream
        let activeOutput = output
        stream = nil
        output = nil
        streamDelegate = nil
        if self.sessionID == sessionID { self.sessionID = nil }
        if let activeStream {
            try? await activeStream.stopCapture()
            if let activeOutput {
                try? activeStream.removeStreamOutput(activeOutput, type: .audio)
            }
        }
    }

    nonisolated static func classifiedError(_ error: Error) -> Error {
        if let captureError = error as? RealtimeAudioCaptureError { return captureError }
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code) else {
            return RealtimeAudioCaptureError.screenCapture(error.localizedDescription)
        }
        switch code {
        case .userDeclined:
            return RealtimeAudioCaptureError.screenRecordingPermissionDenied
        case .missingEntitlements:
            return RealtimeAudioCaptureError.missingScreenCaptureEntitlement
        case .failedToStartAudioCapture:
            return RealtimeAudioCaptureError.failedToStartSystemAudio
        default:
            return RealtimeAudioCaptureError.screenCapture(error.localizedDescription)
        }
    }
}

final class RealtimeAudioCaptureCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSessionID: UUID?
    private var onBuffer: (@Sendable (RealtimeAudioCaptureBuffer) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var firstBufferContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var hasReportedError = false

    func activate(
        sessionID: UUID,
        onBuffer: @escaping @Sendable (RealtimeAudioCaptureBuffer) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        firstBufferContinuation: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        lock.withLock {
            activeSessionID = sessionID
            self.onBuffer = onBuffer
            self.onError = onError
            self.firstBufferContinuation = firstBufferContinuation
            hasReportedError = false
        }
    }

    func accept(buffer: AVAudioPCMBuffer, sessionID: UUID) {
        let actions = lock.withLock { () -> (
            (@Sendable (RealtimeAudioCaptureBuffer) -> Void)?,
            AsyncThrowingStream<Void, Error>.Continuation?
        ) in
            guard activeSessionID == sessionID, !hasReportedError else { return (nil, nil) }
            let continuation = firstBufferContinuation
            firstBufferContinuation = nil
            return (onBuffer, continuation)
        }
        actions.0?(RealtimeAudioCaptureBuffer(sessionID: sessionID, buffer: buffer))
        actions.1?.yield(())
        actions.1?.finish()
    }

    func reject(error: Error, sessionID: UUID) {
        let actions = lock.withLock { () -> (
            (@Sendable (Error) -> Void)?,
            AsyncThrowingStream<Void, Error>.Continuation?
        ) in
            guard activeSessionID == sessionID, !hasReportedError else { return (nil, nil) }
            hasReportedError = true
            activeSessionID = nil
            let continuation = firstBufferContinuation
            firstBufferContinuation = nil
            let handler = onError
            onBuffer = nil
            onError = nil
            return (handler, continuation)
        }
        actions.0?(error)
        actions.1?.finish(throwing: error)
    }

    func invalidate(sessionID: UUID) {
        let continuation = lock.withLock { () -> AsyncThrowingStream<Void, Error>.Continuation? in
            guard activeSessionID == sessionID else { return nil }
            activeSessionID = nil
            onBuffer = nil
            onError = nil
            let continuation = firstBufferContinuation
            firstBufferContinuation = nil
            return continuation
        }
        continuation?.finish(throwing: RealtimeAudioCaptureError.stoppedBeforeFirstBuffer)
    }
}

private final class RealtimeScreenAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

private final class RealtimeScreenAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let sessionID: UUID
    private let targetFormat: AVAudioFormat
    private let callbackGate: RealtimeAudioCaptureCallbackGate
    private var converter: AVAudioConverter?

    init(
        sessionID: UUID,
        targetFormat: AVAudioFormat,
        callbackGate: RealtimeAudioCaptureCallbackGate
    ) {
        self.sessionID = sessionID
        self.targetFormat = targetFormat
        self.callbackGate = callbackGate
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        do {
            let input = try Self.makePCMBuffer(from: sampleBuffer)
            let output: AVAudioPCMBuffer
            if input.format == targetFormat {
                output = input
            } else {
                let converter = if let existing = self.converter, existing.inputFormat == input.format {
                    existing
                } else {
                    AVAudioConverter(from: input.format, to: targetFormat)
                }
                guard let converter else { throw RealtimeAudioCaptureError.invalidAudioFormat }
                self.converter = converter
                output = try InputDeviceAudioCapture.convert(input, using: converter, to: targetFormat)
            }
            callbackGate.accept(buffer: output, sessionID: sessionID)
        } catch {
            callbackGate.reject(error: error, sessionID: sessionID)
        }
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RealtimeAudioCaptureError.invalidAudioBuffer
        }
        var streamDescription = description.pointee
        guard streamDescription.mSampleRate.isFinite,
              streamDescription.mSampleRate > 0,
              streamDescription.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RealtimeAudioCaptureError.invalidAudioFormat
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0, sampleCount <= 1_000_000 else {
            throw RealtimeAudioCaptureError.invalidAudioBuffer
        }
        let frameCount = AVAudioFrameCount(sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RealtimeAudioCaptureError.invalidAudioBuffer
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw RealtimeAudioCaptureError.coreAudio(status) }
        return buffer
    }
}

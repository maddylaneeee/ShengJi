import AVFoundation
import Foundation
import Metal
import WhisperMetal

enum WhisperEngineError: LocalizedError {
    case modelMissing(String)
    case modelLoadFailed
    case inferenceFailed(Int32)
    case invalidAudio
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): L10n.format("尚未下载 Whisper 模型 %@。", name)
        case .modelLoadFailed: L10n.text("Whisper 模型无法载入，文件可能已损坏或内存不足。")
        case .inferenceFailed(let code): L10n.format("Whisper 推理失败（错误码 %lld）。", code)
        case .invalidAudio: L10n.text("无法将音频转换为 Whisper 所需的格式。")
        case .metalUnavailable: L10n.text("Whisper Metal 后端不可用。")
        }
    }
}

actor WhisperModelContext {
    enum DecodingMode: Equatable, Sendable {
        case realtime
        case accurate
    }

    private let context: OpaquePointer
    let model: WhisperModel
    let backendStatus: ComputeBackendStatus

    static var metalSystemInfo: String {
        String(cString: whisper_print_system_info())
    }

    init(
        model: WhisperModel,
        modelURL: URL,
        preference: ComputeBackendPreference = .automatic
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperEngineError.modelMissing(model.title)
        }
        let systemInfo = Self.metalSystemInfo
        let metalAvailable = systemInfo.contains("MTL : EMBED_LIBRARY = 1") && MTLCreateSystemDefaultDevice() != nil
        let requestsCPU = preference == .cpu
        let shouldTryMetal = !requestsCPU && metalAvailable

        if shouldTryMetal, let loaded = Self.load(modelURL: modelURL, useGPU: true) {
            context = loaded
            backendStatus = ComputeBackendStatus(
                requested: preference,
                resolved: .metal,
                aneEligible: false,
                detail: "Whisper · Metal GPU",
                fallbackReason: preference == .coreMLANEPreferred
                    ? L10n.text("当前 Whisper 模型没有匹配的 Core ML encoder；普通 whisper.cpp Metal 模型不使用 ANE。")
                    : nil
            )
        } else if let loaded = Self.load(modelURL: modelURL, useGPU: false) {
            context = loaded
            backendStatus = ComputeBackendStatus(
                requested: preference,
                resolved: .cpu,
                aneEligible: false,
                detail: "Whisper · CPU",
                fallbackReason: requestsCPU ? nil : L10n.text("Metal 初始化不可用，已回退到 CPU。")
            )
        } else {
            throw WhisperEngineError.modelLoadFailed
        }
        self.model = model
    }

    private static func load(modelURL: URL, useGPU: Bool) -> OpaquePointer? {
        var parameters = whisper_context_default_params()
        parameters.use_gpu = useGPU
        parameters.flash_attn = useGPU
        parameters.gpu_device = 0
        return modelURL.path.withCString { path in
            whisper_init_from_file_with_params(path, parameters)
        }
    }

    deinit {
        whisper_free(context)
    }

    func transcribe(
        samples: [Float],
        languageCode: String,
        preserveContext: Bool = true,
        mode: DecodingMode = .accurate,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> [TranscriptSegment] {
        try samples.withUnsafeBufferPointer {
            try transcribe(
                sampleBuffer: $0,
                languageCode: languageCode,
                preserveContext: preserveContext,
                mode: mode,
                progressHandler: progressHandler
            )
        }
    }

    func transcribe(
        mappedPCMData: Data,
        languageCode: String,
        preserveContext: Bool = true,
        incrementalSegmentHandler: (@Sendable ([TranscriptSegment]) -> Void)? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> [TranscriptSegment] {
        guard mappedPCMData.count.isMultiple(of: MemoryLayout<Float>.stride) else {
            throw WhisperEngineError.invalidAudio
        }
        return try mappedPCMData.withUnsafeBytes { rawBuffer in
            try transcribe(
                sampleBuffer: rawBuffer.bindMemory(to: Float.self),
                languageCode: languageCode,
                preserveContext: preserveContext,
                mode: .accurate,
                incrementalSegmentHandler: incrementalSegmentHandler,
                progressHandler: progressHandler
            )
        }
    }

    private func transcribe(
        sampleBuffer samples: UnsafeBufferPointer<Float>,
        languageCode: String,
        preserveContext: Bool,
        mode: DecodingMode,
        incrementalSegmentHandler: (@Sendable ([TranscriptSegment]) -> Void)? = nil,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> [TranscriptSegment] {
        guard samples.count >= WhisperAudio.sampleRate / 3 else { return [] }
        guard samples.count <= Int(Int32.max) else { throw WhisperEngineError.invalidAudio }
        let strategy = mode == .accurate ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        var parameters = whisper_full_default_params(strategy)
        parameters.n_threads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 8)))
        parameters.translate = false
        parameters.no_context = !preserveContext
        parameters.no_timestamps = false
        parameters.single_segment = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.token_timestamps = false
        parameters.suppress_blank = true
        parameters.suppress_nst = true
        parameters.temperature = 0
        // Match the upstream fallback strategy: retry low-confidence or highly
        // repetitive windows instead of committing the first failed decode.
        parameters.temperature_inc = mode == .accurate ? 0.2 : 0
        parameters.entropy_thold = 2.4
        parameters.logprob_thold = -1.0
        parameters.no_speech_thold = mode == .realtime ? 0.45 : 0.55
        parameters.max_initial_ts = 1.0
        parameters.n_max_text_ctx = preserveContext ? 224 : 0
        if mode == .accurate {
            parameters.beam_search.beam_size = 5
            parameters.beam_search.patience = 1
        } else {
            parameters.greedy.best_of = 3
        }

        let progressObserver = progressHandler.map(WhisperProgressObserver.init)
        if let progressObserver {
            parameters.progress_callback = { _, _, progress, userData in
                guard let userData else { return }
                let observer = Unmanaged<WhisperProgressObserver>.fromOpaque(userData).takeUnretainedValue()
                observer.report(progress)
            }
            parameters.progress_callback_user_data = Unmanaged.passUnretained(progressObserver).toOpaque()
        }

        let segmentObserver = incrementalSegmentHandler.map(WhisperIncrementalSegmentObserver.init)
        if let segmentObserver {
            parameters.new_segment_callback = { context, _, newSegmentCount, userData in
                guard let context, let userData else { return }
                let observer = Unmanaged<WhisperIncrementalSegmentObserver>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                observer.report(context: context, newSegmentCount: newSegmentCount)
            }
            parameters.new_segment_callback_user_data = Unmanaged.passUnretained(segmentObserver).toOpaque()
        }

        let useVAD = mode == .accurate
            && WhisperVADResource.shouldUse(forSampleCount: samples.count)
            && WhisperVADResource.modelURL != nil
        if useVAD {
            parameters.vad = true
            parameters.vad_params.threshold = 0.50
            parameters.vad_params.min_speech_duration_ms = 250
            parameters.vad_params.min_silence_duration_ms = 500
            parameters.vad_params.max_speech_duration_s = 28
            parameters.vad_params.speech_pad_ms = 250
            parameters.vad_params.samples_overlap = 0.25
        }

        let result: Int32 = languageCode.withCString { language in
            parameters.language = language
            guard useVAD, let vadModelURL = WhisperVADResource.modelURL else {
                return whisper_full(context, parameters, samples.baseAddress, Int32(samples.count))
            }
            return vadModelURL.path.withCString { vadPath in
                parameters.vad_model_path = vadPath
                return whisper_full(context, parameters, samples.baseAddress, Int32(samples.count))
            }
        }
        guard result == 0 else { throw WhisperEngineError.inferenceFailed(result) }

        let decoded = Self.decodedSegments(context: context)
        let filtered = WhisperOutputFilter.removingTerminalHallucinations(from: decoded.map(\.segment)) { segment in
            WhisperAudio.hasSpeechEnergy(
                samples: samples,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
        return WhisperOutputFilter.removingHallucinatedRuns(from: filtered)
    }

    fileprivate static func decodedSegments(
        context: OpaquePointer,
        range: Range<Int32>? = nil
    ) -> [WhisperDecodedSegment] {
        let count = whisper_full_n_segments(context)
        let requestedRange = range ?? 0..<count
        let safeRange = max(requestedRange.lowerBound, 0)..<min(requestedRange.upperBound, count)
        guard !safeRange.isEmpty else { return [] }
        let endOfText = whisper_token_eot(context)
        var output: [WhisperDecodedSegment] = []
        for index in safeRange {
            guard let textPointer = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let noSpeechProbability = whisper_full_get_segment_no_speech_prob(context, index)
            let tokenCount = whisper_full_n_tokens(context, index)
            var probabilityTotal: Float = 0
            var probabilityCount: Int32 = 0
            for tokenIndex in 0..<tokenCount {
                guard whisper_full_get_token_id(context, index, tokenIndex) < endOfText else { continue }
                probabilityTotal += whisper_full_get_token_p(context, index, tokenIndex)
                probabilityCount += 1
            }
            let averageProbability = probabilityCount > 0
                ? probabilityTotal / Float(probabilityCount)
                : 1
            guard !WhisperOutputFilter.shouldDiscard(
                text: text,
                noSpeechProbability: noSpeechProbability,
                averageTokenProbability: averageProbability
            ) else { continue }
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            output.append(WhisperDecodedSegment(
                segment: TranscriptSegment(
                    startTime: start,
                    endTime: max(end, start + 0.05),
                    text: text
                ),
                noSpeechProbability: noSpeechProbability,
                averageTokenProbability: averageProbability
            ))
        }
        return output
    }
}

fileprivate struct WhisperDecodedSegment: Sendable {
    let segment: TranscriptSegment
    let noSpeechProbability: Float
    let averageTokenProbability: Float
}

private final class WhisperProgressObserver: @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Int32) {
        handler(min(max(Double(progress) / 100, 0), 1))
    }
}

private final class WhisperIncrementalSegmentObserver: @unchecked Sendable {
    private let handler: @Sendable ([TranscriptSegment]) -> Void
    private var deliveredCount: Int32 = 0

    init(handler: @escaping @Sendable ([TranscriptSegment]) -> Void) {
        self.handler = handler
    }

    func report(context: OpaquePointer, newSegmentCount: Int32) {
        let total = whisper_full_n_segments(context)
        let callbackStart = max(total - max(newSegmentCount, 0), 0)
        let start = max(deliveredCount, callbackStart)
        deliveredCount = max(deliveredCount, total)
        let segments = WhisperModelContext.decodedSegments(context: context, range: start..<total)
            .map(\.segment)
        if !segments.isEmpty { handler(segments) }
    }
}

enum WhisperVADResource {
    static let fileName = "ggml-silero-v6.2.0"
    static let minimumAdaptiveDuration: TimeInterval = 12

    static var modelURL: URL? {
        Bundle.main.url(
            forResource: fileName,
            withExtension: "bin",
            subdirectory: "WhisperVAD"
        )
    }

    static func shouldUse(forSampleCount sampleCount: Int) -> Bool {
        Double(sampleCount) / Double(WhisperAudio.sampleRate) >= minimumAdaptiveDuration
    }
}

enum WhisperAudio {
    static let sampleRate = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

    static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) throws -> [Float] {
        let output = try AudioFileFeeder.convert(buffer, using: converter, to: format)
        return floatSamples(from: output)
    }

    static func configure(_ converter: AVAudioConverter) {
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }

    /// Makes model input deterministic and safe without amplifying background
    /// noise: replace non-finite samples, remove DC offset, and only attenuate
    /// clipping. Whisper still receives natural loudness for VAD decisions.
    static func preprocess(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Double = 0
        for index in samples.indices {
            if !samples[index].isFinite { samples[index] = 0 }
            sum += Double(samples[index])
        }
        let mean = Float(sum / Double(samples.count))
        var peak: Float = 0
        for index in samples.indices {
            samples[index] -= mean
            peak = max(peak, abs(samples[index]))
        }
        guard peak > 0.98 else { return }
        let scale = 0.98 / peak
        for index in samples.indices { samples[index] *= scale }
    }

    static func hasSpeechEnergy(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        return rms >= 0.0016 || peak >= 0.018
    }

    static func hasSpeechEnergy(
        samples: UnsafeBufferPointer<Float>,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        let start = min(max(Int(startTime * Double(sampleRate)), 0), samples.count)
        let end = min(max(Int(endTime * Double(sampleRate)), start), samples.count)
        guard end > start else { return false }
        var sumSquares: Double = 0
        var peak: Float = 0
        for index in start..<end {
            let sample = samples[index]
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
        }
        let rms = sqrt(sumSquares / Double(end - start))
        return rms >= 0.0016 || peak >= 0.018
    }

    struct EnergyAccumulator {
        private(set) var sampleCount = 0
        private var sumSquares: Double = 0
        private var peak: Float = 0

        mutating func append(_ samples: [Float]) {
            sampleCount += samples.count
            for sample in samples {
                peak = max(peak, abs(sample))
                sumSquares += Double(sample * sample)
            }
        }

        var hasSpeechEnergy: Bool {
            guard sampleCount > 0 else { return false }
            let rms = sqrt(sumSquares / Double(sampleCount))
            return rms >= 0.0016 || peak >= 0.018
        }
    }
}

enum WhisperOutputFilter {
    static func shouldDiscard(
        text: String,
        noSpeechProbability: Float,
        averageTokenProbability: Float = 1
    ) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        if noSpeechProbability >= 0.65 { return true }
        if averageTokenProbability < 0.08 { return true }
        if noSpeechProbability >= 0.35, averageTokenProbability < 0.18 { return true }
        if noSpeechProbability >= 0.30, containsCreatorBoilerplate(normalized) { return true }
        if hasMechanicalRepetition(normalized) { return true }
        return false
    }

    static func removingHallucinatedRuns(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var previous = ""
        var identicalRun = 0
        for segment in segments {
            let normalized = normalizedForComparison(segment.text)
            if !normalized.isEmpty, normalized == previous {
                identicalRun += 1
            } else {
                previous = normalized
                identicalRun = 1
            }
            // Preserve a genuine immediate repetition, but discard the third
            // and later identical segments typical of a stuck decoder loop.
            if identicalRun <= 2 { result.append(segment) }
        }
        return result
    }

    static func removingTerminalHallucinations(
        from segments: [TranscriptSegment],
        audioHasSpeech: (TranscriptSegment) -> Bool
    ) -> [TranscriptSegment] {
        var result = segments
        while let last = result.last,
              last.endTime - last.startTime <= 8,
              containsTerminalBoilerplate(last.text),
              !audioHasSpeech(last) {
            result.removeLast()
        }
        return result
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
    }

    private static func containsCreatorBoilerplate(_ text: String) -> Bool {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let phrases = [
            "点点关注", "点赞关注", "点关注", "关注点赞",
            "请不吝点赞", "订阅转发", "感谢观看", "下期再见",
            "谢谢大家", "感谢大家"
        ]
        return phrases.contains { collapsed.localizedStandardContains($0) }
    }

    private static func containsTerminalBoilerplate(_ text: String) -> Bool {
        let normalized = normalizedForComparison(text)
        let phrases = [
            "谢谢", "谢谢大家", "感谢大家", "感谢观看", "谢谢观看", "下期再见",
            "thankyou", "thanksforwatching", "seeyounexttime"
        ]
        return phrases.contains(normalized)
    }

    private static func hasMechanicalRepetition(_ text: String) -> Bool {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard collapsed.count >= 6 else { return false }
        let characters = Array(collapsed)
        var lastCharacter: Character?
        var currentRun = 0
        var mostCommonRun = 0
        for character in characters {
            if lastCharacter == character {
                currentRun += 1
            } else {
                lastCharacter = character
                currentRun = 1
            }
            mostCommonRun = max(mostCommonRun, currentRun)
        }
        if mostCommonRun >= 5 { return true }

        let prefixLength = min(3, collapsed.count / 2)
        guard prefixLength >= 2 else { return false }
        let prefix = String(characters.prefix(prefixLength))
        let rebuilt = String(repeating: prefix, count: max(2, collapsed.count / prefixLength))
        return rebuilt.hasPrefix(collapsed) && collapsed.count >= prefixLength * 3
    }
}

actor WhisperLiveSampleBuffer {
    private var samples = FloatRingBuffer()
    private var finished = false

    func append(_ newSamples: [Float]) {
        guard !finished else { return }
        samples.append(contentsOf: newSamples)
    }

    func finish() {
        finished = true
    }

    func takeChunk(minimumCount: Int, maximumCount: Int) -> [Float]? {
        if samples.count < minimumCount, !finished { return nil }
        guard !samples.isEmpty else { return finished ? [] : nil }
        let count = min(samples.count, maximumCount)
        return samples.takeFirst(count)
    }

    /// Waits for a natural pause before handing audio to Whisper. Continuous
    /// speech is capped at `maximumCount` so latency stays bounded, while normal
    /// sentences are no longer cut at an arbitrary four-second boundary.
    func takeSpeechAwareChunk(
        minimumCount: Int,
        maximumCount: Int,
        trailingSilenceCount: Int
    ) -> [Float]? {
        if samples.count < minimumCount, !finished { return nil }
        guard !samples.isEmpty else { return finished ? [] : nil }

        if finished || samples.count >= maximumCount {
            return samples.takeFirst(min(samples.count, maximumCount))
        }

        let tail = samples.suffix(min(trailingSilenceCount, samples.count))
        guard !WhisperAudio.hasSpeechEnergy(tail) else { return nil }
        return samples.takeFirst(min(samples.count, maximumCount))
    }

    var isFinishedAndEmpty: Bool { finished && samples.isEmpty }
}

enum WhisperFileProcessor {
    enum Stage: Sendable {
        case converting(Double)
        case inferring(Double?)
        case finalizing
    }

    static func process(
        url: URL,
        context: WhisperModelContext,
        languageCode: String,
        gate: PauseGate,
        incrementalSegmentHandler: @escaping @Sendable ([TranscriptSegment]) -> Void,
        stageHandler: @escaping @Sendable (Stage) -> Void,
        progressHandler: @escaping @Sendable (Double, TimeInterval) -> Void
    ) async throws -> [TranscriptSegment] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let totalFrames = max(file.length, 1)
        let duration = Double(totalFrames) / sourceFormat.sampleRate
        let readCapacity: AVAudioFrameCount = 16_384
        let converter = AVAudioConverter(from: sourceFormat, to: WhisperAudio.format)
        guard let converter else { throw WhisperEngineError.invalidAudio }
        WhisperAudio.configure(converter)
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribe-Whisper-(UUID().uuidString).f32")
        FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
        let pcmHandle = try FileHandle(forWritingTo: pcmURL)
        var pcmHandleClosed = false
        defer {
            if !pcmHandleClosed { try? pcmHandle.close() }
            try? FileManager.default.removeItem(at: pcmURL)
        }
        var energy = WhisperAudio.EnergyAccumulator()

        while file.framePosition < file.length, !Task.isCancelled {
            await gate.waitIfNeeded()
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(readCapacity), remaining))
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: readCapacity) else {
                throw WhisperEngineError.invalidAudio
            }
            try file.read(into: input, frameCount: frameCount)
            var converted = try WhisperAudio.convert(input, using: converter)
            WhisperAudio.preprocess(&converted)
            energy.append(converted)
            try converted.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
                try pcmHandle.write(contentsOf: Data(bytes: baseAddress, count: rawBuffer.count))
            }

            let progress = min(Double(file.framePosition) / Double(totalFrames), 1)
            progressHandler(progress * 0.12, duration * progress)
            stageHandler(.converting(progress))
        }

        try Task.checkCancellation()
        await gate.waitIfNeeded()
        try pcmHandle.close()
        pcmHandleClosed = true
        if energy.hasSpeechEnergy {
            let mappedPCM = try Data(contentsOf: pcmURL, options: [.mappedIfSafe])
            stageHandler(.inferring(nil))
            let segments = try await context.transcribe(
                mappedPCMData: mappedPCM,
                languageCode: languageCode,
                preserveContext: true,
                incrementalSegmentHandler: incrementalSegmentHandler,
                progressHandler: { progress in
                    stageHandler(.inferring(progress > 0 ? progress : nil))
                    progressHandler(0.12 + progress * 0.88, duration * progress)
                }
            )
            stageHandler(.finalizing)
            progressHandler(1, duration)
            return segments
        }
        stageHandler(.finalizing)
        progressHandler(1, duration)
        return []
    }
}

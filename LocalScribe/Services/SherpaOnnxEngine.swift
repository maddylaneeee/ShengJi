import AVFoundation
import Foundation

enum SherpaOnnxError: LocalizedError {
    case runtimeMissing
    case unsupportedSource
    case modelMissing(String)
    case invalidModelLayout(String)
    case processFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: L10n.text("未找到内置 sherpa-onnx 运行时。")
        case .unsupportedSource: L10n.text("SenseVoice 与 Parakeet 当前支持文件转录；实时麦克风请使用 Apple 或 Whisper。")
        case .modelMissing(let name): L10n.format("尚未安装模型 %@。", name)
        case .invalidModelLayout(let name): L10n.format("模型 %@ 缺少必要文件。", name)
        case .processFailed(let message): L10n.format("第三方模型转录失败：%@", message)
        case .emptyTranscript: L10n.text("第三方模型没有返回可用文字。")
        }
    }
}

struct SherpaTranscriptionResult: Sendable {
    let segments: [TranscriptSegment]
    let backendStatus: ComputeBackendStatus
}

enum SherpaOnnxFileProcessor {
    static func process(
        sourceURL: URL,
        configuration: RecognitionConfiguration,
        locale: Locale,
        progressHandler: @escaping @Sendable (Double, TimeInterval) -> Void
    ) async throws -> SherpaTranscriptionResult {
        guard let model = configuration.managedModel else {
            throw SherpaOnnxError.modelMissing(configuration.displayName)
        }
        guard SpeechModelStore.isInstalled(model) else {
            throw SherpaOnnxError.modelMissing(model.title)
        }

        let prepared = try await MediaAudioPreparer.prepare(sourceURL)
        let wav = try SherpaAudioPreparer.makeMonoPCM16Wav(from: prepared.url)
        defer {
            if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) }
            try? FileManager.default.removeItem(at: wav.url)
        }

        progressHandler(0.12, 0)
        let result = try await runSherpa(
            model: model,
            wavURL: wav.url,
            languageCode: sherpaLanguageCode(for: locale),
            preference: configuration.computeBackend
        )
        progressHandler(1, wav.duration)
        return SherpaTranscriptionResult(
            segments: TranscriptSegment.sentenceSegments(from: result.text, duration: wav.duration),
            backendStatus: result.status
        )
    }

    private static func runSherpa(
        model: ManagedSpeechModel,
        wavURL: URL,
        languageCode: String,
        preference: ComputeBackendPreference
    ) async throws -> (text: String, status: ComputeBackendStatus) {
        let runtimeURL = try runtimeExecutableURL()
        let modelURL = SpeechModelStore.installURL(for: model)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SherpaOnnxError.modelMissing(model.title)
        }

        var environment = ProcessInfo.processInfo.environment
        let libURL = runtimeURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        environment["DYLD_LIBRARY_PATH"] = libURL.path

        let requestedProviders: [String] = switch preference {
        case .automatic: ["coreml", "cpu"]
        case .cpu: ["cpu"]
        case .metal: ["cpu"]
        case .coreMLANEPreferred: ["coreml", "cpu"]
        }
        var firstFailure: String?
        for provider in requestedProviders {
            let arguments = try arguments(
                for: model,
                modelURL: modelURL,
                languageCode: languageCode,
                provider: provider
            ) + [wavURL.path]
            let result = try await SherpaSubprocess().run(
                executableURL: runtimeURL,
                arguments: arguments,
                currentDirectoryURL: modelURL,
                environment: environment
            )
            if Task.isCancelled { throw CancellationError() }
            if result.terminationStatus != 0 {
                let message = (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                firstFailure = firstFailure ?? (message.isEmpty ? "退出码 \(result.terminationStatus)" : message)
                continue
            }
            let transcript = parseTranscript(result.stdout)
            guard !transcript.isEmpty else { throw SherpaOnnxError.emptyTranscript }
            let status = ComputeBackendStatus(
                requested: preference,
                resolved: provider == "coreml" ? .coreMLSystemSelected : .cpu,
                aneEligible: provider == "coreml",
                detail: provider == "coreml"
                    ? L10n.text("Core ML（系统选择；ANE 可用性不等于实际全程使用）")
                    : "Sherpa ONNX · CPU",
                fallbackReason: provider == "cpu" && preference != .cpu
                    ? (firstFailure ?? (preference == .metal ? L10n.text("Sherpa ONNX 不支持 Metal provider。") : L10n.text("Core ML provider 不可用。")))
                    : nil
            )
            return (transcript, status)
        }
        throw SherpaOnnxError.processFailed(firstFailure ?? L10n.text("所有计算后端均不可用。"))
    }

    private static func arguments(
        for model: ManagedSpeechModel,
        modelURL: URL,
        languageCode: String,
        provider: String
    ) throws -> [String] {
        let threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 8))
        switch model {
        case .whisper:
            throw SherpaOnnxError.invalidModelLayout(model.title)
        case .senseVoice(let senseVoice):
            let modelFile = modelURL.appendingPathComponent(senseVoice.modelFileName)
            let tokens = modelURL.appendingPathComponent("tokens.txt")
            guard FileManager.default.fileExists(atPath: modelFile.path),
                  FileManager.default.fileExists(atPath: tokens.path) else {
                throw SherpaOnnxError.invalidModelLayout(model.title)
            }
            return [
                "--tokens=\(tokens.path)",
                "--sense-voice-model=\(modelFile.path)",
                "--sense-voice-language=\(languageCode)",
                "--sense-voice-use-itn=true",
                "--model-type=sense_voice",
                "--num-threads=\(threads)",
                "--provider=\(provider)",
                "--print-args=false"
            ]
        case .parakeet:
            let encoder = firstExisting(in: modelURL, names: ["encoder.int8.onnx", "encoder.onnx"])
            let decoder = firstExisting(in: modelURL, names: ["decoder.int8.onnx", "decoder.onnx"])
            let joiner = firstExisting(in: modelURL, names: ["joiner.int8.onnx", "joiner.onnx"])
            let tokens = modelURL.appendingPathComponent("tokens.txt")
            guard let encoder, let decoder, let joiner,
                  FileManager.default.fileExists(atPath: tokens.path) else {
                throw SherpaOnnxError.invalidModelLayout(model.title)
            }
            return [
                "--encoder=\(encoder.path)",
                "--decoder=\(decoder.path)",
                "--joiner=\(joiner.path)",
                "--tokens=\(tokens.path)",
                "--model-type=nemo_transducer",
                "--decoding-method=greedy_search",
                "--num-threads=\(threads)",
                "--provider=\(provider)",
                "--print-args=false"
            ]
        }
    }

    private static func firstExisting(in directory: URL, names: [String]) -> URL? {
        names
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func parseTranscript(_ stdout: String) -> String {
        let lines = stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let tabSeparated = lines.last(where: { $0.contains("\t") }) {
            return tabSeparated
                .split(separator: "\t")
                .dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let jsonText = lines.reversed().compactMap(extractJSONTranscript).first {
            return jsonText
        }

        let candidates = lines.filter {
            !$0.hasPrefix("/") && !$0.contains(".wav") && !$0.contains("sherpa-onnx")
        }
        return (candidates.last ?? lines.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONTranscript(from line: String) -> String? {
        guard let jsonStart = line.firstIndex(of: "{") else { return nil }
        let jsonCandidate = String(line[jsonStart...])
        guard let data = jsonCandidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            return nil
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func runtimeExecutableURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("SherpaOnnx/bin/sherpa-onnx-offline"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/SherpaOnnx/bin/sherpa-onnx-offline")
        if FileManager.default.isExecutableFile(atPath: development.path) {
            return development
        }

        throw SherpaOnnxError.runtimeMissing
    }

    private static func sherpaLanguageCode(for locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "zh": "zh"
        case "en": "en"
        case "ja", "jp": "ja"
        case "ko": "ko"
        default: "auto"
        }
    }
}

private struct SherpaSubprocessResult: Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

private final class SherpaSubprocess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<SherpaSubprocessResult, Error>?

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) async throws -> SherpaSubprocessResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let tempDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LocalScribe-Sherpa-\(UUID().uuidString)", isDirectory: true)
                let stdoutURL = tempDirectory.appendingPathComponent("stdout.log")
                let stderrURL = tempDirectory.appendingPathComponent("stderr.log")
                do {
                    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
                      let stderr = try? FileHandle(forWritingTo: stderrURL) else {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectoryURL
                process.environment = environment
                process.standardOutput = stdout
                process.standardError = stderr
                process.terminationHandler = { [weak self] process in
                    try? stdout.close()
                    try? stderr.close()
                    let result = SherpaSubprocessResult(
                        stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
                        stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
                        terminationStatus: process.terminationStatus
                    )
                    try? FileManager.default.removeItem(at: tempDirectory)
                    self?.finish(.success(result))
                }

                lock.withLock {
                    self.continuation = continuation
                    self.process = process
                }

                do {
                    try process.run()
                } catch {
                    try? stdout.close()
                    try? stderr.close()
                    try? FileManager.default.removeItem(at: tempDirectory)
                    finish(.failure(error))
                }
            }
        } onCancel: {
            terminate()
        }
    }

    private func terminate() {
        lock.withLock {
            process?.terminate()
        }
    }

    private func finish(_ result: Result<SherpaSubprocessResult, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            process = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

private enum SherpaAudioPreparer {
    static func makeMonoPCM16Wav(from url: URL) throws -> (url: URL, duration: TimeInterval) {
        let inputFile = try AVAudioFile(forReading: url)
        let sourceFormat = inputFile.processingFormat
        let duration = Double(inputFile.length) / sourceFormat.sampleRate

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WhisperEngineError.invalidAudio
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribe-Sherpa-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let readCapacity: AVAudioFrameCount = 8_192
        while inputFile.framePosition < inputFile.length {
            let remaining = inputFile.length - inputFile.framePosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(readCapacity), remaining))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: readCapacity) else {
                throw WhisperEngineError.invalidAudio
            }
            try inputFile.read(into: inputBuffer, frameCount: frameCount)
            let outputBuffer = try AudioFileFeeder.convert(inputBuffer, using: converter, to: targetFormat)
            try outputFile.write(from: outputBuffer)
        }

        return (outputURL, duration)
    }
}

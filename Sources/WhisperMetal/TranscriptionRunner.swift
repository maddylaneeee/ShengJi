import Foundation

struct TranscriptionRunner {
    let config: RunConfig

    func run(
        onStatus: @escaping @Sendable (String) -> Void,
        onLog: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (RunProgress) -> Void,
        onRecord: @escaping @Sendable (RunRecord) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ShengJi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for (index, input) in config.inputFiles.enumerated() {
            try Task.checkCancellation()
            onProgress(RunProgress(currentFile: input, currentIndex: index, totalFiles: config.inputFiles.count, phase: .converting))
            onStatus("Converting \(index + 1) of \(config.inputFiles.count): \(input.lastPathComponent)")
            let wav = tempRoot.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".wav")
            try await convertToWhisperWav(input: input, output: wav, onLog: onLog)

            try Task.checkCancellation()
            onProgress(RunProgress(currentFile: input, currentIndex: index, totalFiles: config.inputFiles.count, phase: .transcribing))
            onStatus("Transcribing \(index + 1) of \(config.inputFiles.count): \(input.lastPathComponent)")
            let outputBase = config.outputDirectory
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                .path

            var args = [
                "-m", config.modelPath.path,
                "-f", wav.path,
                "-of", outputBase,
                "-l", config.language,
                "-t", "\(config.threads)",
                "-p", "\(config.processors)",
                "-tp", String(format: "%.2f", config.temperature),
                "-bo", "\(config.bestOf)",
                "-bs", "\(config.beamSize)",
                "-wt", String(format: "%.2f", config.wordThreshold),
                "-et", String(format: "%.2f", config.entropyThreshold),
                "-lpt", String(format: "%.2f", config.logprobThreshold),
                "-nth", String(format: "%.2f", config.noSpeechThreshold),
                "-pp"
            ]

            if !config.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args += ["--prompt", config.prompt]
            }
            if config.maxLength > 0 {
                args += ["-ml", "\(config.maxLength)"]
            }
            if config.maxContext >= 0 {
                args += ["-mc", "\(config.maxContext)"]
            }
            if config.noFallback {
                args.append("-nf")
            }
            if config.splitOnWord {
                args.append("-sow")
            }
            if config.task == .translate {
                args.append("-tr")
            }
            if !config.useMetal {
                args.append("--no-gpu")
            }
            if !config.printTimestamps {
                args.append("-nt")
            }
            if config.diarize {
                args.append("-di")
            }
            if config.enableVAD, let vadModelPath = config.vadModelPath {
                args += [
                    "--vad",
                    "-vm", vadModelPath.path,
                    "-vt", String(format: "%.2f", config.vadThreshold),
                    "-vspd", "\(config.vadMinSpeechMs)",
                    "-vsd", "\(config.vadMinSilenceMs)",
                    "-vp", "\(config.vadSpeechPadMs)"
                ]
            }
            args += config.outputFormats.map(\.cliFlag)

            let exitCode = try await ProcessRunner.run(
                executable: config.cli,
                arguments: args,
                onOutput: { text in
                    onLog(text)
                    for line in text.components(separatedBy: .newlines) {
                        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if Self.looksLikeTranscript(cleaned) {
                            onTranscript(cleaned)
                        }
                    }
                }
            )
            let ok = exitCode == 0
            onRecord(RunRecord(inputName: input.lastPathComponent, outputBase: outputBase, date: .now, succeeded: ok))
            if !ok {
                throw RunnerError.processFailed("whisper-cli exited with \(exitCode)")
            }
            onProgress(RunProgress(currentFile: input, currentIndex: index + 1, totalFiles: config.inputFiles.count, phase: .finished))
        }
    }

    private func convertToWhisperWav(
        input: URL,
        output: URL,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws {
        let args = [
            input.path,
            "-o", output.path,
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            "-r", "127",
            "--mix"
        ]
        let code = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: args,
            onOutput: onLog
        )
        if code != 0 {
            throw RunnerError.processFailed("afconvert exited with \(code)")
        }
    }

    private static func looksLikeTranscript(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("$") || line.hasPrefix("whisper_") || line.hasPrefix("ggml_") { return false }
        if line.contains("%") && line.lowercased().contains("progress") { return false }
        if line.hasPrefix("main:") || line.hasPrefix("system_info:") { return false }
        return line.range(of: #"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}"#, options: .regularExpression) != nil
            || (!line.hasPrefix("[") && line.count > 2)
    }
}

enum RunnerError: LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let message): message
        }
    }
}

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case transcribe = "Transcribe"
        case downloads = "Downloads"
        case models = "Models"
        case history = "History"
        case settings = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .transcribe: "waveform"
            case .downloads: "arrow.down.circle"
            case .models: "shippingbox"
            case .history: "clock.arrow.circlepath"
            case .settings: "slider.horizontal.3"
            }
        }
    }

    @Published var selection: Section? = .transcribe
    @Published var showInspector = true
    @Published var inputFiles: [URL] = []
    @Published var modelPath = "" {
        didSet {
            guard modelPath != oldValue else { return }
            loadedModelPath = ""
            modelLoadProgress = ModelLoadProgress(detail: "Selection changed", fraction: 0)
            modelLoadState = modelPath.isEmpty ? .notInstalled : .waiting
        }
    }
    @Published var availableModels: [URL] = []
    @Published var vadModelPath = ""
    @Published var availableVADModels: [URL] = []
    @Published var outputDirectory = ""
    @Published var language = "auto"
    @Published var task = WhisperTask.transcribe
    @Published var outputFormats: Set<OutputFormat> = [.txt, .srt]
    @Published var useMetal = true
    @Published var printTimestamps = true
    @Published var threads = max(4, ProcessInfo.processInfo.processorCount / 2)
    @Published var processors = 1
    @Published var temperature = 0.0
    @Published var prompt = ""
    @Published var maxLength = 0
    @Published var maxContext = -1
    @Published var bestOf = 5
    @Published var beamSize = 5
    @Published var noFallback = false
    @Published var splitOnWord = false
    @Published var wordThreshold = 0.01
    @Published var entropyThreshold = 2.4
    @Published var logprobThreshold = -1.0
    @Published var noSpeechThreshold = 0.6
    @Published var enableVAD = false
    @Published var vadThreshold = 0.5
    @Published var vadMinSpeechMs = 250
    @Published var vadMinSilenceMs = 100
    @Published var vadSpeechPadMs = 30
    @Published var diarize = false
    @Published var status = "Ready"
    @Published var logText = ""
    @Published var transcriptText = ""
    @Published var history: [RunRecord] = []
    @Published var isRunning = false
    @Published var runProgress = RunProgress()
    @Published var modelLoadState = ModelLoadState.notInstalled
    @Published var modelLoadProgress = ModelLoadProgress()
    @Published var loadedModelPath = ""
    @Published var isDownloadingModel = false
    @Published var modelDownloadProgress = DownloadProgressState()
    @Published var mediaURL = ""
    @Published var mediaDownloadDirectory = ""
    @Published var mediaAudioOnly = true
    @Published var addDownloadedToQueue = true
    @Published var keepDownloadedMedia = false
    @Published var isDownloadingMedia = false
    @Published var mediaDownloadProgress = DownloadProgressState()
    @Published var ytdlpPath = ""
    @Published var ytdlpVersion = "Not checked"
    @Published var detectedGPU = "Detecting Metal device..."

    private var runTask: Task<Void, Never>?
    private var modelLoadTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var downloadedMediaFiles: [URL] = []
    private var temporaryMediaFiles: Set<URL> = []
    private let whisperEngine = WhisperEngine()
    private let defaults = UserDefaults.standard

    var canRun: Bool {
        canTranscribeReason == nil
    }

    var canTranscribeReason: String? {
        if isRunning { return "Transcription is already running." }
        if inputFiles.isEmpty { return "Add a local file or download a URL first." }
        if modelPath.isEmpty { return "Choose or download a GGML model." }
        if !FileManager.default.fileExists(atPath: modelPath) { return "Selected model file is missing." }
        if modelLoadState != .ready || loadedModelPath != modelPath { return "Selected model is not ready yet." }
        if outputFormats.isEmpty { return "Choose at least one output format." }
        guard let cli = whisperCLIURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            return "Bundled whisper-cli is missing."
        }
        return nil
    }

    var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ShengJi", isDirectory: true)
    }

    var modelDirectory: URL {
        appSupportURL.appendingPathComponent("models", isDirectory: true)
    }

    var defaultOutputURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("声迹输出", isDirectory: true)
    }

    var defaultMediaDownloadURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("声迹下载", isDirectory: true)
    }

    var whisperCLIURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("whisper-cli")
    }

    func startup() async {
        loadSettings()
        ensureDirectories()
        refreshModels()
        refreshYtDlpStatus()
        detectedGPU = MetalProbe.describeDevice()
        if modelPath.isEmpty, let first = availableModels.first {
            modelPath = first.path
        }
        scheduleModelLoad()
        appendLog("App started. \(detectedGPU)")
    }

    func pickInputFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose audio or video files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaTypes.supportedTypes
        if panel.runModal() == .OK {
            addInputFiles(panel.urls)
        }
    }

    func addInputFiles(_ urls: [URL]) {
        let existing = Set(inputFiles.map(\.path))
        inputFiles.append(contentsOf: urls.filter { !existing.contains($0.path) })
        saveSettings()
    }

    func removeInputFiles(at offsets: IndexSet) {
        cleanupTemporaryMedia(for: offsets.map { inputFiles[$0] })
        inputFiles.remove(atOffsets: offsets)
        saveSettings()
    }

    func clearInputFiles() {
        cleanupTemporaryMedia(for: inputFiles)
        inputFiles.removeAll()
        saveSettings()
    }

    func removeInputFile(_ url: URL) {
        inputFiles.removeAll { $0 == url }
        cleanupTemporaryMedia(for: [url])
        saveSettings()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func pickModelFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGML Whisper model"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importModel(url)
        }
    }

    func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose output folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
            saveSettings()
        }
    }

    func pickMediaDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose download folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            mediaDownloadDirectory = url.path
            saveSettings()
        }
    }

    func revealOutputDirectory() {
        let url = URL(fileURLWithPath: outputDirectory.isEmpty ? defaultOutputURL.path : outputDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshModels() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        availableModels = urls
            .filter { $0.pathExtension.lowercased() == "bin" && !$0.lastPathComponent.contains("silero") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        availableVADModels = urls
            .filter { $0.pathExtension.lowercased() == "bin" && $0.lastPathComponent.contains("silero") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if vadModelPath.isEmpty, let first = availableVADModels.first {
            vadModelPath = first.path
        }
        if modelPath.isEmpty {
            modelLoadState = .notInstalled
            modelLoadProgress = ModelLoadProgress(detail: ModelLoadState.notInstalled.detail, fraction: 0)
        }
    }

    func isModelInstalled(_ model: DownloadableModel) -> Bool {
        FileManager.default.fileExists(atPath: installedModelURL(model).path)
    }

    func installedModelURL(_ model: DownloadableModel) -> URL {
        modelDirectory.appendingPathComponent(model.fileName)
    }

    func deleteModel(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            if modelPath == url.path { modelPath = "" }
            if vadModelPath == url.path { vadModelPath = "" }
            refreshModels()
            saveSettings()
            appendLog("Deleted model: \(url.lastPathComponent)")
        } catch {
            appendLog("Delete model failed: \(error.localizedDescription)")
        }
    }

    func importModel(_ source: URL) {
        ensureDirectories()
        let destination = modelDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            modelPath = destination.path
            refreshModels()
            saveSettings()
            scheduleModelLoad()
            appendLog("Imported model: \(destination.lastPathComponent)")
        } catch {
            status = "Model import failed"
            appendLog("Model import failed: \(error.localizedDescription)")
        }
    }

    func downloadModel(_ model: DownloadableModel) {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        modelDownloadProgress = DownloadProgressState(title: model.name, detail: "Connecting...", completed: 0, total: 0)
        status = "Downloading \(model.name)"
        appendLog("Downloading \(model.name) from \(model.url.absoluteString)")
        Task {
            do {
                ensureDirectories()
                let destination = modelDirectory.appendingPathComponent(model.fileName)
                let temporary = try await downloadFile(
                    from: model.url,
                    title: model.name,
                    update: { [weak self] progress in
                        Task { @MainActor in self?.modelDownloadProgress = progress }
                    }
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                if destination.lastPathComponent.contains("silero") {
                    vadModelPath = destination.path
                } else {
                    modelPath = destination.path
                }
                refreshModels()
                saveSettings()
                scheduleModelLoad()
                status = "Downloaded \(model.name)"
                modelDownloadProgress.detail = "Done"
                appendLog("Downloaded model: \(destination.path)")
            } catch {
                status = "Model download failed"
                modelDownloadProgress.detail = error.localizedDescription
                appendLog("Model download failed: \(error.localizedDescription)")
            }
            isDownloadingModel = false
        }
    }

    func refreshYtDlpStatus() {
        let candidates = [
            ytdlpPath,
            appSupportURL.appendingPathComponent("yt-dlp").path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ].filter { !$0.isEmpty }

        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            ytdlpVersion = "Not installed"
            return
        }
        ytdlpPath = found
        Task {
            let result = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: found),
                arguments: ["--version"],
                onOutput: { [weak self] text in
                    Task { @MainActor in self?.ytdlpVersion = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            )
            if result != 0 {
                ytdlpVersion = "Unavailable"
            }
        }
    }

    func updateYtDlp() {
        guard !isDownloadingMedia else { return }
        isDownloadingMedia = true
        mediaDownloadProgress = DownloadProgressState(title: "yt-dlp", detail: "Downloading latest binary...", completed: 0, total: 0)
        Task {
            do {
                ensureDirectories()
                let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
                let temp = try await downloadFile(
                    from: url,
                    title: "yt-dlp",
                    update: { [weak self] progress in
                        Task { @MainActor in self?.mediaDownloadProgress = progress }
                    }
                )
                let destination = appSupportURL.appendingPathComponent("yt-dlp")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                ytdlpPath = destination.path
                saveSettings()
                refreshYtDlpStatus()
                mediaDownloadProgress.detail = "yt-dlp updated"
                appendLog("Updated yt-dlp: \(destination.path)")
            } catch {
                mediaDownloadProgress.detail = error.localizedDescription
                appendLog("yt-dlp update failed: \(error.localizedDescription)")
            }
            isDownloadingMedia = false
        }
    }

    func downloadMedia() {
        guard !isDownloadingMedia, !mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let source = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSettings()
        isDownloadingMedia = true
        let baseDirectory = keepDownloadedMedia ? (mediaDownloadDirectory.isEmpty ? defaultMediaDownloadURL : URL(fileURLWithPath: mediaDownloadDirectory)) : appSupportURL.appendingPathComponent("cache", isDirectory: true)
        mediaDownloadProgress = DownloadProgressState(title: "Media", detail: "Starting download...", completed: 0, total: 0)
        downloadedMediaFiles = []
        mediaTask = Task {
            do {
                try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                if Self.shouldUseYtDlp(for: source) {
                    try await downloadWithYtDlp(urlString: source, downloadDir: baseDirectory)
                } else {
                    let file = try await downloadDirectURL(urlString: source, downloadDir: baseDirectory)
                    await MainActor.run {
                        self.downloadedMediaFiles = [file]
                        if !self.keepDownloadedMedia {
                            self.temporaryMediaFiles.insert(file)
                        }
                    }
                }
                let downloaded = await MainActor.run { self.downloadedMediaFiles }
                if await MainActor.run(body: { self.addDownloadedToQueue }) {
                    await MainActor.run {
                        self.addInputFiles(downloaded.filter { FileManager.default.fileExists(atPath: $0.path) })
                    }
                } else if await MainActor.run(body: { !self.keepDownloadedMedia }) {
                    await MainActor.run {
                        self.cleanupTemporaryMedia(for: downloaded)
                    }
                }
                await MainActor.run {
                    self.mediaDownloadProgress.detail = "Ready: \(downloaded.count) file(s)"
                    self.appendLog("Media download finished: \(downloaded.count) file(s)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.mediaDownloadProgress.detail = "Cancelled"
                    self.cleanupTemporaryMedia(for: self.downloadedMediaFiles)
                    self.appendLog("Media download cancelled.")
                }
            } catch {
                await MainActor.run {
                    self.mediaDownloadProgress.detail = error.localizedDescription
                    self.cleanupTemporaryMedia(for: self.downloadedMediaFiles)
                    self.appendLog("Media download failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.isDownloadingMedia = false
                self.mediaTask = nil
            }
        }
    }

    private func downloadWithYtDlp(urlString: String, downloadDir: URL) async throws {
        refreshYtDlpStatus()
        guard FileManager.default.isExecutableFile(atPath: ytdlpPath) else {
            throw RunnerError.processFailed("Install or update yt-dlp first.")
        }
        var args = [
            urlString,
            "-o", downloadDir.appendingPathComponent("%(title)s.%(ext)s").path,
            "--newline",
            "--progress",
            "--print", "after_move:filepath",
            "--no-warnings"
        ]
        if mediaAudioOnly {
            args += ["-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "192"]
        } else {
            args += ["-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"]
        }
        let code = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: ytdlpPath),
            arguments: args,
            onOutput: { [weak self] text in
                Task { @MainActor in self?.handleYtDlpOutput(text) }
            }
        )
        if code != 0 {
            throw RunnerError.processFailed("yt-dlp exited with \(code)")
        }
        if !keepDownloadedMedia {
            await MainActor.run {
                self.temporaryMediaFiles.formUnion(self.downloadedMediaFiles)
            }
        }
    }

    private func downloadDirectURL(urlString: String, downloadDir: URL) async throws -> URL {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw RunnerError.processFailed("Invalid URL")
        }
        let destination = downloadDir.appendingPathComponent(suggestedFileName(for: url))
        try? FileManager.default.removeItem(at: destination)
        await MainActor.run {
            self.mediaDownloadProgress = DownloadProgressState(title: destination.lastPathComponent, detail: "Preparing direct download...", completed: 0, total: 0)
        }
        let capability = (try? await directDownloadCapability(url: url)) ?? (acceptRanges: false, length: Int64(0))
        if capability.acceptRanges, capability.length > 8 * 1024 * 1024 {
            do {
                return try await rangedDownload(url: url, destination: destination, total: capability.length)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run {
                    self.mediaDownloadProgress.detail = "Range download unavailable, using single stream..."
                }
            }
        }
        return try await singleStreamDownload(url: url, destination: destination, total: capability.length)
    }

    private func directDownloadCapability(url: URL) async throws -> (acceptRanges: Bool, length: Int64) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (false, 0) }
        let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        return (ranges, length)
    }

    private func rangedDownload(url: URL, destination: URL, total: Int64) async throws -> URL {
        let chunkCount = min(8, max(2, Int(total / (8 * 1024 * 1024))))
        let chunkSize = total / Int64(chunkCount)
        let partURLs = (0..<chunkCount).map { destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).part\($0)") }
        try await withThrowingTaskGroup(of: Int64.self) { group in
            do {
                for index in 0..<chunkCount {
                    let start = Int64(index) * chunkSize
                    let end = index == chunkCount - 1 ? total - 1 : start + chunkSize - 1
                    let partURL = partURLs[index]
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                            throw RunnerError.processFailed("Server rejected range request")
                        }
                        try data.write(to: partURL, options: .atomic)
                        return Int64(data.count)
                    }
                }
                var completed: Int64 = 0
                for try await bytes in group {
                    completed += bytes
                    await MainActor.run {
                        self.mediaDownloadProgress = DownloadProgressState(
                            title: destination.lastPathComponent,
                            detail: "Accelerated \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))",
                            completed: completed,
                            total: total
                        )
                    }
                }
            } catch {
                for part in partURLs {
                    try? FileManager.default.removeItem(at: part)
                }
                throw error
            }
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        for part in partURLs {
            let data = try Data(contentsOf: part)
            try output.write(contentsOf: data)
            try? FileManager.default.removeItem(at: part)
        }
        try output.close()
        return destination
    }

    private func singleStreamDownload(url: URL, destination: URL, total: Int64) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expected = total > 0 ? total : response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var completed: Int64 = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                try handle.write(contentsOf: [byte])
                completed += 1
                if completed % 262_144 == 0 {
                    await MainActor.run {
                        self.mediaDownloadProgress = DownloadProgressState(title: destination.lastPathComponent, detail: "Streaming \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file))", completed: completed, total: expected)
                    }
                }
            }
            try handle.close()
            return destination
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func shouldUseYtDlp(for value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be") || host.contains("bilibili.com") || host.contains("vimeo.com")
    }

    private func suggestedFileName(for url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last.contains(".") {
            return last
        }
        return "download-\(Int(Date().timeIntervalSince1970)).media"
    }

    func cancelMediaDownload() {
        mediaTask?.cancel()
    }

    func startTranscription() {
        guard canRun else {
            if let reason = canTranscribeReason {
                status = reason
                appendLog("Cannot start: \(reason)")
            }
            return
        }
        guard let cli = whisperCLIURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            status = "whisper-cli is missing"
            appendLog("Missing bundled whisper-cli. Run scripts/bootstrap_whisper_cpp.sh and scripts/build_release.sh.")
            return
        }

        saveSettings()
        let config = RunConfig(
            inputFiles: inputFiles,
            modelPath: URL(fileURLWithPath: modelPath),
            outputDirectory: URL(fileURLWithPath: outputDirectory.isEmpty ? defaultOutputURL.path : outputDirectory),
            language: language,
            task: task,
            outputFormats: Array(outputFormats).sorted { $0.rawValue < $1.rawValue },
            useMetal: useMetal,
            printTimestamps: printTimestamps,
            threads: threads,
            processors: processors,
            temperature: temperature,
            prompt: prompt,
            maxLength: maxLength,
            maxContext: maxContext,
            bestOf: bestOf,
            beamSize: beamSize,
            noFallback: noFallback,
            splitOnWord: splitOnWord,
            wordThreshold: wordThreshold,
            entropyThreshold: entropyThreshold,
            logprobThreshold: logprobThreshold,
            noSpeechThreshold: noSpeechThreshold,
            enableVAD: enableVAD,
            vadModelPath: vadModelPath.isEmpty ? nil : URL(fileURLWithPath: vadModelPath),
            vadThreshold: vadThreshold,
            vadMinSpeechMs: vadMinSpeechMs,
            vadMinSilenceMs: vadMinSilenceMs,
            vadSpeechPadMs: vadSpeechPadMs,
            diarize: diarize,
            cli: cli
        )

        isRunning = true
        runProgress = RunProgress(currentFile: nil, currentIndex: 0, totalFiles: config.inputFiles.count, phase: .idle)
        transcriptText = ""
        status = "Preparing run"
        appendLog("Starting batch: \(config.inputFiles.count) file(s)")
        runTask = Task {
            let runner = TranscriptionRunner(config: config)
            do {
                try await runner.run(
                    onStatus: { [weak self] message in
                        Task { @MainActor in self?.status = message }
                    },
                    onLog: { [weak self] message in
                        Task { @MainActor in self?.appendLog(message) }
                    },
                    onTranscript: { [weak self] message in
                        Task { @MainActor in
                            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            self?.transcriptText += message + "\n"
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in self?.runProgress = progress }
                    },
                    onRecord: { [weak self] record in
                        Task { @MainActor in self?.history.insert(record, at: 0) }
                    }
                )
                status = "Finished"
                appendLog("Batch finished.")
            } catch is CancellationError {
                status = "Cancelled"
                appendLog("Run cancelled.")
            } catch {
                status = "Failed"
                appendLog("Run failed: \(error.localizedDescription)")
            }
            if !keepDownloadedMedia {
                cleanupFinishedTemporaryMedia()
            }
            runProgress = RunProgress()
            isRunning = false
            runTask = nil
        }
    }

    func cancelRun() {
        runTask?.cancel()
        status = "Cancelling..."
    }

    func selectModel(_ path: String) {
        modelPath = path
        saveSettings()
        scheduleModelLoad()
    }

    func scheduleModelLoad() {
        modelLoadTask?.cancel()
        let selected = modelPath
        guard !selected.isEmpty else {
            modelLoadState = .notInstalled
            modelLoadProgress = ModelLoadProgress(detail: ModelLoadState.notInstalled.detail, fraction: 0)
            return
        }
        modelLoadState = .waiting
        modelLoadProgress = ModelLoadProgress(detail: "Queued: \(URL(fileURLWithPath: selected).lastPathComponent)", fraction: 0)
        modelLoadTask = Task { [weak self] in
            await self?.prepareSelectedModel(path: selected)
        }
    }

    func saveSettings() {
        defaults.set(modelPath, forKey: "modelPath")
        defaults.set(outputDirectory, forKey: "outputDirectory")
        defaults.set(language, forKey: "language")
        defaults.set(task.rawValue, forKey: "task")
        defaults.set(Array(outputFormats.map(\.rawValue)), forKey: "outputFormats")
        defaults.set(useMetal, forKey: "useMetal")
        defaults.set(printTimestamps, forKey: "printTimestamps")
        defaults.set(threads, forKey: "threads")
        defaults.set(processors, forKey: "processors")
        defaults.set(temperature, forKey: "temperature")
        defaults.set(prompt, forKey: "prompt")
        defaults.set(maxLength, forKey: "maxLength")
        defaults.set(maxContext, forKey: "maxContext")
        defaults.set(bestOf, forKey: "bestOf")
        defaults.set(beamSize, forKey: "beamSize")
        defaults.set(noFallback, forKey: "noFallback")
        defaults.set(splitOnWord, forKey: "splitOnWord")
        defaults.set(wordThreshold, forKey: "wordThreshold")
        defaults.set(entropyThreshold, forKey: "entropyThreshold")
        defaults.set(logprobThreshold, forKey: "logprobThreshold")
        defaults.set(noSpeechThreshold, forKey: "noSpeechThreshold")
        defaults.set(enableVAD, forKey: "enableVAD")
        defaults.set(vadModelPath, forKey: "vadModelPath")
        defaults.set(vadThreshold, forKey: "vadThreshold")
        defaults.set(vadMinSpeechMs, forKey: "vadMinSpeechMs")
        defaults.set(vadMinSilenceMs, forKey: "vadMinSilenceMs")
        defaults.set(vadSpeechPadMs, forKey: "vadSpeechPadMs")
        defaults.set(diarize, forKey: "diarize")
        defaults.set(mediaURL, forKey: "mediaURL")
        defaults.set(mediaDownloadDirectory, forKey: "mediaDownloadDirectory")
        defaults.set(mediaAudioOnly, forKey: "mediaAudioOnly")
        defaults.set(addDownloadedToQueue, forKey: "addDownloadedToQueue")
        defaults.set(keepDownloadedMedia, forKey: "keepDownloadedMedia")
        defaults.set(ytdlpPath, forKey: "ytdlpPath")
    }

    private func loadSettings() {
        modelPath = defaults.string(forKey: "modelPath") ?? ""
        outputDirectory = defaults.string(forKey: "outputDirectory") ?? defaultOutputURL.path
        language = defaults.string(forKey: "language") ?? "auto"
        task = WhisperTask(rawValue: defaults.string(forKey: "task") ?? "") ?? .transcribe
        if let raw = defaults.stringArray(forKey: "outputFormats") {
            outputFormats = Set(raw.compactMap(OutputFormat.init(rawValue:)))
        }
        if outputFormats.isEmpty { outputFormats = [.txt, .srt] }
        if defaults.object(forKey: "useMetal") != nil {
            useMetal = defaults.bool(forKey: "useMetal")
        }
        if defaults.object(forKey: "printTimestamps") != nil {
            printTimestamps = defaults.bool(forKey: "printTimestamps")
        }
        let savedThreads = defaults.integer(forKey: "threads")
        if savedThreads > 0 { threads = savedThreads }
        let savedProcessors = defaults.integer(forKey: "processors")
        if savedProcessors > 0 { processors = savedProcessors }
        if defaults.object(forKey: "temperature") != nil {
            temperature = defaults.double(forKey: "temperature")
        }
        prompt = defaults.string(forKey: "prompt") ?? ""
        if defaults.object(forKey: "maxLength") != nil { maxLength = defaults.integer(forKey: "maxLength") }
        if defaults.object(forKey: "maxContext") != nil { maxContext = defaults.integer(forKey: "maxContext") }
        let savedBestOf = defaults.integer(forKey: "bestOf")
        if savedBestOf > 0 { bestOf = savedBestOf }
        let savedBeamSize = defaults.integer(forKey: "beamSize")
        if savedBeamSize > 0 { beamSize = savedBeamSize }
        if defaults.object(forKey: "noFallback") != nil { noFallback = defaults.bool(forKey: "noFallback") }
        if defaults.object(forKey: "splitOnWord") != nil { splitOnWord = defaults.bool(forKey: "splitOnWord") }
        if defaults.object(forKey: "wordThreshold") != nil { wordThreshold = defaults.double(forKey: "wordThreshold") }
        if defaults.object(forKey: "entropyThreshold") != nil { entropyThreshold = defaults.double(forKey: "entropyThreshold") }
        if defaults.object(forKey: "logprobThreshold") != nil { logprobThreshold = defaults.double(forKey: "logprobThreshold") }
        if defaults.object(forKey: "noSpeechThreshold") != nil { noSpeechThreshold = defaults.double(forKey: "noSpeechThreshold") }
        if defaults.object(forKey: "enableVAD") != nil {
            enableVAD = defaults.bool(forKey: "enableVAD")
        }
        vadModelPath = defaults.string(forKey: "vadModelPath") ?? ""
        if defaults.object(forKey: "vadThreshold") != nil {
            vadThreshold = defaults.double(forKey: "vadThreshold")
        }
        if defaults.object(forKey: "vadMinSpeechMs") != nil { vadMinSpeechMs = defaults.integer(forKey: "vadMinSpeechMs") }
        if defaults.object(forKey: "vadMinSilenceMs") != nil { vadMinSilenceMs = defaults.integer(forKey: "vadMinSilenceMs") }
        if defaults.object(forKey: "vadSpeechPadMs") != nil { vadSpeechPadMs = defaults.integer(forKey: "vadSpeechPadMs") }
        if defaults.object(forKey: "diarize") != nil {
            diarize = defaults.bool(forKey: "diarize")
        }
        mediaURL = defaults.string(forKey: "mediaURL") ?? ""
        mediaDownloadDirectory = defaults.string(forKey: "mediaDownloadDirectory") ?? defaultMediaDownloadURL.path
        if defaults.object(forKey: "mediaAudioOnly") != nil { mediaAudioOnly = defaults.bool(forKey: "mediaAudioOnly") }
        if defaults.object(forKey: "addDownloadedToQueue") != nil { addDownloadedToQueue = defaults.bool(forKey: "addDownloadedToQueue") }
        if defaults.object(forKey: "keepDownloadedMedia") != nil { keepDownloadedMedia = defaults.bool(forKey: "keepDownloadedMedia") }
        ytdlpPath = defaults.string(forKey: "ytdlpPath") ?? ""
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultOutputURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: defaultMediaDownloadURL, withIntermediateDirectories: true)
        if !outputDirectory.isEmpty {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outputDirectory), withIntermediateDirectories: true)
        }
        if !mediaDownloadDirectory.isEmpty {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: mediaDownloadDirectory), withIntermediateDirectories: true)
        }
    }

    private func prepareSelectedModel(path: String) async {
        if Task.isCancelled { return }
        modelLoadState = .loading
        modelLoadProgress = ModelLoadProgress(detail: "Checking model file...", fraction: 0.2)
        guard FileManager.default.fileExists(atPath: path) else {
            await unloadPreparedModel(message: "Selected model file no longer exists.")
            return
        }

        modelLoadProgress = ModelLoadProgress(detail: "Validating bundled runtime...", fraction: 0.65)
        guard let cli = whisperCLIURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            await unloadPreparedModel(message: "Bundled whisper runtime is missing.")
            return
        }

        if Task.isCancelled { return }
        do {
            loadedModelPath = try await whisperEngine.prepare(modelPath: path, runtime: cli)
            modelLoadState = .ready
            modelLoadProgress = ModelLoadProgress(detail: URL(fileURLWithPath: path).lastPathComponent, fraction: 1)
            appendLog("Model ready: \(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
            await unloadPreparedModel(message: error.localizedDescription)
        }
    }

    private func unloadPreparedModel(message: String) async {
        await whisperEngine.unload()
        modelLoadState = .failed(message)
        modelLoadProgress = ModelLoadProgress(detail: message, fraction: 0)
        loadedModelPath = ""
    }

    private func appendLog(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        logText += "[\(stamp)] \(message)\n"
    }

    private func cleanupTemporaryMedia(for urls: [URL]) {
        for url in urls where temporaryMediaFiles.contains(url) {
            try? FileManager.default.removeItem(at: url)
            temporaryMediaFiles.remove(url)
        }
    }

    private func cleanupFinishedTemporaryMedia() {
        let finished = inputFiles.filter { temporaryMediaFiles.contains($0) }
        cleanupTemporaryMedia(for: finished)
        inputFiles.removeAll { temporaryMediaFiles.contains($0) || !FileManager.default.fileExists(atPath: $0.path) }
        saveSettings()
    }

    private func downloadFile(
        from url: URL,
        title: String,
        update: @escaping (DownloadProgressState) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        var completed: Int64 = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                try handle.write(contentsOf: Data([byte]))
                completed += 1
                if completed % 262_144 == 0 || completed == total {
                    update(DownloadProgressState(title: title, detail: "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "unknown")", completed: completed, total: total))
                }
            }
            try handle.close()
            update(DownloadProgressState(title: title, detail: "Downloaded", completed: completed, total: total))
            return temp
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private func handleYtDlpOutput(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            appendLog("[yt-dlp] \(line)")
            if line.hasPrefix("[download]") {
                mediaDownloadProgress.detail = line.replacingOccurrences(of: "[download]", with: "").trimmingCharacters(in: .whitespaces)
                if let match = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression) {
                    let raw = String(line[match]).replacingOccurrences(of: "%", with: "")
                    if let percent = Double(raw) {
                        mediaDownloadProgress.completed = Int64(percent * 1000)
                        mediaDownloadProgress.total = 100_000
                    }
                }
            } else if FileManager.default.fileExists(atPath: line) {
                let url = URL(fileURLWithPath: line)
                if !downloadedMediaFiles.contains(url) {
                    downloadedMediaFiles.append(url)
                }
                mediaDownloadProgress.detail = "Ready: \(url.lastPathComponent)"
            }
        }
    }
}

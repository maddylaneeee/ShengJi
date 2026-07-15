import CryptoKit
import Foundation

enum ModelDownloadState: Equatable {
    case idle
    case downloading(model: ManagedSpeechModel, progress: Double)
    case failed(model: ManagedSpeechModel, message: String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

enum ModelStorageError: LocalizedError {
    case invalidResponse
    case invalidSize(expected: Int64, actual: Int64)
    case invalidChecksum(expected: String, actual: String)
    case extractionFailed(String)
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "模型服务器返回了无效响应。"
        case .invalidSize(let expected, let actual):
            "模型文件不完整（应为 \(expected) 字节，实际为 \(actual) 字节）。"
        case .invalidChecksum(let expected, let actual):
            "模型校验失败（SHA1 应为 \(expected)，实际为 \(actual)）。"
        case .extractionFailed(let message): "模型解包失败：\(message)"
        case .modelNotInstalled(let title): "尚未安装模型 \(title)。"
        }
    }
}

enum SpeechModelStore {
    static func installedModels() -> Set<ManagedSpeechModel> {
        Set(ManagedSpeechModel.allModels.filter { isInstalled($0) })
    }

    static func isInstalled(_ model: ManagedSpeechModel) -> Bool {
        switch model {
        case .whisper(let whisper):
            guard let size = try? url(for: model).resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return Int64(size) == whisper.expectedByteCount
        case .senseVoice:
            let marker = installURL(for: model).appendingPathComponent(".localscribe-model.json")
            guard FileManager.default.fileExists(atPath: marker.path) else { return false }
            return requiredFiles(for: model).allSatisfy {
                FileManager.default.fileExists(atPath: installURL(for: model).appendingPathComponent($0).path)
            }
        case .parakeet:
            let directory = installURL(for: model)
            let marker = directory.appendingPathComponent(".localscribe-model.json")
            guard FileManager.default.fileExists(atPath: marker.path) else { return false }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokens.txt").path) else { return false }
            return [
                ["encoder.int8.onnx", "encoder.onnx"],
                ["decoder.int8.onnx", "decoder.onnx"],
                ["joiner.int8.onnx", "joiner.onnx"]
            ].allSatisfy { alternatives in
                alternatives.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            }
        }
    }

    static func url(for model: ManagedSpeechModel) -> URL {
        switch model {
        case .whisper(let whisper):
            return whisperModelsDirectory.appendingPathComponent(whisper.fileName)
        case .senseVoice, .parakeet:
            return installURL(for: model)
        }
    }

    static func installURL(for model: ManagedSpeechModel) -> URL {
        switch model {
        case .whisper:
            return url(for: model)
        case .senseVoice, .parakeet:
            return managedModelsDirectory.appendingPathComponent(model.id, isDirectory: true)
        }
    }

    static func requiredFiles(for model: ManagedSpeechModel) -> [String] {
        switch model {
        case .whisper:
            return []
        case .senseVoice(let senseVoice):
            return [senseVoice.modelFileName, "tokens.txt"]
        case .parakeet:
            return ["tokens.txt"]
        }
    }

    static func remove(_ model: ManagedSpeechModel) throws {
        let target = url(for: model)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    static func install(
        _ model: ManagedSpeechModel,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let partialURL = downloadsDirectory.appendingPathComponent(model.id + ".download")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partialURL)

        let operation = ModelDownloadOperation(
            source: model.downloadURL,
            destination: partialURL,
            progress: progress
        )
        try await operation.start()

        let size = try partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard size == model.expectedByteCount else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelStorageError.invalidSize(expected: model.expectedByteCount, actual: size)
        }
        if let expectedSHA1 = model.expectedSHA1 {
            let actualSHA1 = try sha1Hex(of: partialURL)
            guard actualSHA1 == expectedSHA1 else {
                try? FileManager.default.removeItem(at: partialURL)
                throw ModelStorageError.invalidChecksum(expected: expectedSHA1, actual: actualSHA1)
            }
        }

        if model.isArchive {
            try installArchive(model, archiveURL: partialURL)
        } else {
            try FileManager.default.createDirectory(at: whisperModelsDirectory, withIntermediateDirectories: true)
            let finalURL = url(for: model)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        }
    }

    private static func installArchive(_ model: ManagedSpeechModel, archiveURL: URL) throws {
        let finalURL = installURL(for: model)
        let stagingURL = downloadsDirectory.appendingPathComponent(model.id + ".staging", isDirectory: true)
        try? FileManager.default.removeItem(at: stagingURL)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", stagingURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "tar exited with \(process.terminationStatus)"
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: archiveURL)
            throw ModelStorageError.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let extractedDirectoryName = model.extractedDirectoryName else {
            throw ModelStorageError.extractionFailed("模型缺少目录信息。")
        }
        let extractedURL = stagingURL.appendingPathComponent(extractedDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extractedURL.path) else {
            throw ModelStorageError.extractionFailed("未找到解包后的模型目录 \(extractedDirectoryName)。")
        }

        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.createDirectory(at: managedModelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extractedURL, to: finalURL)
        let marker = ModelInstallMarker(
            id: model.id,
            title: model.title,
            sourceURL: model.downloadURL.absoluteString,
            installedAt: Date()
        )
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: finalURL.appendingPathComponent(".localscribe-model.json"), options: [.atomic])
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: stagingURL)
    }

    static var whisperModelsDirectory: URL {
        LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/WhisperModels", isDirectory: true)
    }

    static var managedModelsDirectory: URL {
        LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/Models", isDirectory: true)
    }

    private static var downloadsDirectory: URL {
        LocalScribePaths.cachesDirectory
            .appendingPathComponent("声迹/ModelDownloads", isDirectory: true)
    }

    private static func sha1Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 * 1_024 * 1_024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct ModelInstallMarker: Codable {
    let id: String
    let title: String
    let sourceURL: String
    let installedAt: Date
}

final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let progressHandler: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var downloadedFile = false

    init(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.destination = destination
        progressHandler = progress
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 90
                configuration.timeoutIntervalForResource = 7_200
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: source)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedFile = true
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if downloadedFile { finish(.success(())) }
        else { finish(.failure(ModelStorageError.invalidResponse)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}

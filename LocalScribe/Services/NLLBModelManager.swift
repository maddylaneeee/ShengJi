import CryptoKit
import Foundation
import Observation

enum NLLBModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double)
    case failed(message: String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

enum NLLBModelDownloadError: LocalizedError {
    case invalidSize(file: String, expected: Int64, actual: Int64)
    case invalidChecksum(file: String)
    case incompleteInstall

    var errorDescription: String? {
        switch self {
        case .invalidSize(let file, let expected, let actual):
            "NLLB 模型文件 \(file) 不完整（应为 \(expected) 字节，实际为 \(actual) 字节）。"
        case .invalidChecksum(let file):
            "NLLB 模型文件 \(file) 校验失败，请重试。"
        case .incompleteInstall:
            "NLLB 模型安装不完整，请重试。"
        }
    }
}

enum NLLBModelStore {
    static let title = "NLLB-200 Distilled 600M · INT8"
    static let totalByteCount: Int64 = 630_477_782
    static let repositoryURL = URL(string: "https://huggingface.co/osa911/nllb-200-distilled-600M-ct2-int8")!

    private static let revision = "46858753dbaf8eb5e21bb6f0037c3b90851e090a"
    private static let files: [NLLBModelFile] = [
        NLLBModelFile(
            name: "config.json",
            byteCount: 223,
            sha256: "8f6496adfc930cbfecbe8281112197705c488fab47d34b4829b06d7f478909af"
        ),
        NLLBModelFile(
            name: "sentencepiece.bpe.model",
            byteCount: 4_852_054,
            sha256: "14bb8dfb35c0ffdea7bc01e56cea38b9e3d5efcdcb9c251d6b40538e1aab555a"
        ),
        NLLBModelFile(
            name: "shared_vocabulary.json",
            byteCount: 5_921_176,
            sha256: "af53bfd0e6f726209e7325e45b87ab3b14e5856f7d42d7b9be91de3287c45267"
        ),
        NLLBModelFile(
            name: "model.bin",
            byteCount: 619_704_329,
            sha256: "ca3362e6e81906c0cf9c33bd6917674222c71d69617d0afb18507ce0b6c2e2e8"
        )
    ]

    static var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalByteCount, countStyle: .file)
    }

    static var installDirectory: URL {
        LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/NLLBModels/nllb-200-distilled-600M-int8", isDirectory: true)
    }

    static func install(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: installDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var completedBytes: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let stagedURL = stagingDirectory.appendingPathComponent(file.name)
            if try isValid(file: file, at: stagedURL) {
                completedBytes += file.byteCount
                progress(Double(completedBytes) / Double(totalByteCount))
                continue
            }

            try? fileManager.removeItem(at: stagedURL)
            let partialURL = downloadsDirectory.appendingPathComponent(file.name + ".download")
            try? fileManager.removeItem(at: partialURL)
            let startingBytes = completedBytes
            let operation = ModelDownloadOperation(
                source: downloadURL(for: file),
                destination: partialURL
            ) { fileProgress in
                let current = Double(startingBytes) + Double(file.byteCount) * fileProgress
                progress(min(current / Double(totalByteCount), 1))
            }
            do {
                try await operation.start()
                try Task.checkCancellation()
                try validate(file: file, at: partialURL)
                try fileManager.moveItem(at: partialURL, to: stagedURL)
                completedBytes += file.byteCount
                progress(Double(completedBytes) / Double(totalByteCount))
            } catch {
                try? fileManager.removeItem(at: partialURL)
                throw error
            }
        }

        guard try files.allSatisfy({ try isValid(file: $0, at: stagingDirectory.appendingPathComponent($0.name)) }) else {
            throw NLLBModelDownloadError.incompleteInstall
        }

        let marker = NLLBModelInstallMarker(
            revision: revision,
            sourceURL: repositoryURL.absoluteString,
            installedAt: Date()
        )
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: stagingDirectory.appendingPathComponent(".localscribe-model.json"), options: .atomic)

        let backupURL = installDirectory.deletingLastPathComponent()
            .appendingPathComponent("nllb-200-distilled-600M-int8.previous", isDirectory: true)
        try? fileManager.removeItem(at: backupURL)
        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.moveItem(at: installDirectory, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: installDirectory)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: installDirectory)
            }
            throw error
        }
        progress(1)
    }

    static func removeManagedModel() throws {
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try FileManager.default.removeItem(at: installDirectory)
        }
    }

    private static var downloadsDirectory: URL {
        LocalScribePaths.cachesDirectory
            .appendingPathComponent("声迹/NLLBModelDownloads", isDirectory: true)
    }

    private static var stagingDirectory: URL {
        downloadsDirectory.appendingPathComponent("nllb-200-distilled-600M-int8.staging", isDirectory: true)
    }

    private static func downloadURL(for file: NLLBModelFile) -> URL {
        URL(string: "https://huggingface.co/osa911/nllb-200-distilled-600M-ct2-int8/resolve/\(revision)/\(file.name)?download=true")!
    }

    private static func validate(file: NLLBModelFile, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard size == file.byteCount else {
            throw NLLBModelDownloadError.invalidSize(file: file.name, expected: file.byteCount, actual: size)
        }
        guard try sha256Hex(of: url) == file.sha256 else {
            throw NLLBModelDownloadError.invalidChecksum(file: file.name)
        }
    }

    private static func isValid(file: NLLBModelFile, at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try validate(file: file, at: url)
            return true
        } catch {
            return false
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 * 1_024 * 1_024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class NLLBModelManager {
    private(set) var state: NLLBModelDownloadState = .idle
    private(set) var isInstalled: Bool
    private var downloadTask: Task<Void, Never>?
    private var activeDownloadID: UUID?

    init() {
        isInstalled = NLLBTranslationRuntime.installedModelURL != nil
    }

    func refresh() {
        isInstalled = NLLBTranslationRuntime.installedModelURL != nil
    }

    func download() {
        guard !state.isDownloading else { return }
        downloadTask?.cancel()
        let downloadID = UUID()
        activeDownloadID = downloadID
        state = .downloading(progress: 0)
        let observer = NLLBDownloadProgressObserver(manager: self, downloadID: downloadID)
        downloadTask = Task { [weak self, observer, downloadID] in
            do {
                try await NLLBModelStore.install { progress in
                    Task { @MainActor in observer.update(progress: progress) }
                }
                guard !Task.isCancelled else { return }
                guard self?.activeDownloadID == downloadID else { return }
                self?.refresh()
                self?.state = .idle
                self?.downloadTask = nil
                self?.activeDownloadID = nil
            } catch is CancellationError {
                guard self?.activeDownloadID == downloadID else { return }
                self?.state = .idle
                self?.downloadTask = nil
                self?.activeDownloadID = nil
            } catch {
                guard self?.activeDownloadID == downloadID else { return }
                self?.state = .failed(message: error.localizedDescription)
                self?.downloadTask = nil
                self?.activeDownloadID = nil
            }
        }
    }

    func cancelDownload() {
        activeDownloadID = nil
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    fileprivate func updateDownloadProgress(_ progress: Double, downloadID: UUID) {
        guard activeDownloadID == downloadID else { return }
        state = .downloading(progress: progress)
    }
}

private struct NLLBModelFile: Sendable {
    let name: String
    let byteCount: Int64
    let sha256: String
}

private struct NLLBModelInstallMarker: Codable {
    let revision: String
    let sourceURL: String
    let installedAt: Date
}

private final class NLLBDownloadProgressObserver: @unchecked Sendable {
    private weak var manager: NLLBModelManager?
    private let downloadID: UUID

    init(manager: NLLBModelManager, downloadID: UUID) {
        self.manager = manager
        self.downloadID = downloadID
    }

    @MainActor
    func update(progress: Double) {
        manager?.updateDownloadProgress(progress, downloadID: downloadID)
    }
}

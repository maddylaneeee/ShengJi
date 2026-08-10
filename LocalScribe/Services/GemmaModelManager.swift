import CryptoKit
import Foundation
import Observation

enum GemmaHardwareSupport {
    static let minimumExclusiveBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    static var isSupported: Bool { isSupported(physicalMemory: physicalMemory) }

    static func isSupported(physicalMemory: UInt64) -> Bool {
        physicalMemory > minimumExclusiveBytes
    }

    static var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
    }

    static var unsupportedReason: String {
        L10n.format("这台 Mac 有 %@ 内存；6 GB 及以下不能安全运行 Gemma E2B，因此 AI 功能已停用。", memoryLabel)
    }
}

enum GemmaModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case e2b
    case e4b

    var id: String { rawValue }

    var title: String {
        switch self {
        case .e2b: "Gemma 4 E2B IT · Q4"
        case .e4b: "Gemma 4 E4B IT · Q4"
        }
    }

    var fileName: String {
        switch self {
        case .e2b: "gemma-4-E2B-it-Q4_0.gguf"
        case .e4b: "gemma-4-E4B-it-Q4_0.gguf"
        }
    }

    var repository: String {
        switch self {
        case .e2b: "ggml-org/gemma-4-E2B-it-GGUF"
        case .e4b: "ggml-org/gemma-4-E4B-it-GGUF"
        }
    }

    var revision: String {
        switch self {
        case .e2b: "b4243c156154b6dca9324415f8c7ccc098b4aed1"
        case .e4b: "b8093469224f83f5c38f691eb906c380e9e63114"
        }
    }

    var expectedByteCount: Int64 {
        switch self {
        case .e2b: 2_841_481_184
        case .e4b: 4_590_807_392
        }
    }

    var expectedSHA256: String {
        switch self {
        case .e2b: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        case .e4b: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2"
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)?download=true")!
    }
}

enum GemmaModelDownloadState: Equatable {
    case idle
    case downloading(model: GemmaModel, progress: Double)
    case failed(model: GemmaModel, message: String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

enum GemmaModelStore {
    static var modelsDirectory: URL {
        LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/GemmaModels", isDirectory: true)
    }

    static func url(for model: GemmaModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    static func isInstalled(_ model: GemmaModel) -> Bool {
        guard FileManager.default.fileExists(atPath: url(for: model).path),
              let size = try? url(for: model).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) == model.expectedByteCount
    }

    static func install(
        _ model: GemmaModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard GemmaHardwareSupport.isSupported else { throw GemmaModelError.insufficientMemory }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let downloads = LocalScribePaths.cachesDirectory
            .appendingPathComponent("声迹/GemmaModelDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let partial = downloads.appendingPathComponent(model.fileName + ".download")
        try? fileManager.removeItem(at: partial)

        let operation = ModelDownloadOperation(
            source: model.downloadURL,
            destination: partial,
            progress: progress
        )
        do {
            try await operation.start()
            try Task.checkCancellation()
            try validate(model, at: partial)
            let destination = url(for: model)
            let backup = destination.appendingPathExtension("previous")
            try? fileManager.removeItem(at: backup)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            do {
                try fileManager.moveItem(at: partial, to: destination)
                try? fileManager.removeItem(at: backup)
            } catch {
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            progress(1)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    static func remove(_ model: GemmaModel) throws {
        let modelURL = url(for: model)
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
    }

    private static func validate(_ model: GemmaModel, at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard size == model.expectedByteCount else {
            throw GemmaModelError.invalidSize(expected: model.expectedByteCount, actual: size)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 * 1_024 * 1_024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == model.expectedSHA256 else { throw GemmaModelError.invalidChecksum }
    }
}

enum GemmaModelError: LocalizedError {
    case insufficientMemory
    case invalidSize(expected: Int64, actual: Int64)
    case invalidChecksum

    var errorDescription: String? {
        switch self {
        case .insufficientMemory:
            GemmaHardwareSupport.unsupportedReason
        case .invalidSize(let expected, let actual):
            L10n.format("Gemma 模型不完整（应为 %lld 字节，实际为 %lld 字节）。", expected, actual)
        case .invalidChecksum:
            L10n.text("Gemma 模型校验失败，请重新下载。")
        }
    }
}

@MainActor
@Observable
final class GemmaModelManager {
    private(set) var state: GemmaModelDownloadState = .idle
    private(set) var installedModels: Set<GemmaModel> = []
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    init() { refresh() }

    func refresh() {
        installedModels = Set(GemmaModel.allCases.filter(GemmaModelStore.isInstalled))
    }

    func download(_ model: GemmaModel) {
        guard !state.isDownloading else { return }
        guard GemmaHardwareSupport.isSupported else {
            state = .failed(model: model, message: GemmaHardwareSupport.unsupportedReason)
            return
        }
        let id = UUID()
        operationID = id
        state = .downloading(model: model, progress: 0)
        let observer = GemmaDownloadProgressObserver(manager: self, model: model, operationID: id)
        task = Task { [weak self, observer] in
            do {
                try await GemmaModelStore.install(model) { progress in
                    Task { @MainActor in observer.update(progress: progress) }
                }
                guard !Task.isCancelled, self?.operationID == id else { return }
                self?.refresh()
                self?.state = .idle
                self?.operationID = nil
                self?.task = nil
            } catch is CancellationError {
                guard self?.operationID == id else { return }
                self?.state = .idle
                self?.operationID = nil
                self?.task = nil
            } catch {
                guard self?.operationID == id else { return }
                self?.state = .failed(model: model, message: error.localizedDescription)
                self?.operationID = nil
                self?.task = nil
            }
        }
    }

    func cancelDownload() {
        operationID = nil
        task?.cancel()
        task = nil
        state = .idle
    }

    fileprivate func updateDownloadProgress(
        _ progress: Double,
        model: GemmaModel,
        operationID: UUID
    ) {
        guard self.operationID == operationID else { return }
        state = .downloading(model: model, progress: progress)
    }
}

private final class GemmaDownloadProgressObserver: @unchecked Sendable {
    private weak var manager: GemmaModelManager?
    private let model: GemmaModel
    private let operationID: UUID

    init(manager: GemmaModelManager, model: GemmaModel, operationID: UUID) {
        self.manager = manager
        self.model = model
        self.operationID = operationID
    }

    @MainActor
    func update(progress: Double) {
        manager?.updateDownloadProgress(progress, model: model, operationID: operationID)
    }
}

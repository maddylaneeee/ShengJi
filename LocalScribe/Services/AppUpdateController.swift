import AppKit
import CryptoKit
import Foundation
import Observation

struct AppUpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let downloadURL: URL
    let sha256: String
    let releaseNotes: String?
    let minimumSystemVersion: String?
    let publishedAt: Date?
    let sizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case downloadURL = "download_url"
        case sha256
        case releaseNotes = "release_notes"
        case minimumSystemVersion = "minimum_system_version"
        case publishedAt = "published_at"
        case sizeBytes = "size_bytes"
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case available(AppUpdateManifest)
    case upToDate
    case downloading(Double)
    case ready(AppUpdateManifest)
    case failed(String)
}

@MainActor
@Observable
final class AppUpdateController {
    var manifestURLString: String {
        didSet {
            if let url = URL(string: manifestURLString) {
                AppInfo.updateManifestURL = url
            }
        }
    }

    private(set) var state: AppUpdateState = .idle
    private(set) var downloadedAppURL: URL?
    private var currentManifest: AppUpdateManifest?
    @ObservationIgnored private let preparation = UpdatePreparationActor()

    init() {
        manifestURLString = AppInfo.updateManifestURL.absoluteString
    }

    var statusText: String {
        switch state {
        case .idle: "尚未检查更新"
        case .checking: "正在检查更新…"
        case .available(let manifest): "发现 \(manifest.version) (\(manifest.build))"
        case .upToDate: "当前已是最新版本"
        case .downloading(let progress): "正在下载 \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case .ready: "更新已准备好，重启后替换应用"
        case .failed(let message): message
        }
    }

    var canInstall: Bool {
        if case .ready = state { return downloadedAppURL != nil }
        return false
    }

    func checkForUpdates() async {
        guard let manifestURL = URL(string: manifestURLString) else {
            state = .failed("更新地址无效。")
            return
        }

        state = .checking
        do {
            var request = URLRequest(url: manifestURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
                throw UpdateError.invalidResponse
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(AppUpdateManifest.self, from: data)
            currentManifest = manifest
            if isNewer(manifest) {
                state = .available(manifest)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func downloadAvailableUpdate() async {
        let manifest: AppUpdateManifest?
        switch state {
        case .available(let available): manifest = available
        case .ready(let ready): manifest = ready
        default: manifest = currentManifest
        }
        guard let manifest else {
            state = .failed("没有可下载的更新。")
            return
        }

        state = .downloading(0)
        do {
            let packageURL = try await downloadPackage(manifest)
            let appURL = try await preparation.prepare(
                packageURL: packageURL,
                manifest: manifest,
                expectedBundleIdentifier: AppInfo.bundleIdentifier
            )
            downloadedAppURL = appURL
            state = .ready(manifest)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func installAndRelaunch() throws {
        guard let downloadedAppURL else { throw UpdateError.noDownloadedApp }
        let scriptURL = try makeInstallScript(newAppURL: downloadedAppURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, Bundle.main.bundleURL.path, downloadedAppURL.path]
        try process.run()
        NSApp.terminate(nil)
    }

    func reset() {
        state = .idle
        downloadedAppURL = nil
        currentManifest = nil
    }

    private func isNewer(_ manifest: AppUpdateManifest) -> Bool {
        if manifest.version.compare(AppInfo.version, options: .numeric) == .orderedDescending {
            return true
        }
        if manifest.version == AppInfo.version {
            return manifest.build.compare(AppInfo.build, options: .numeric) == .orderedDescending
        }
        return false
    }

    private func downloadPackage(_ manifest: AppUpdateManifest) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: manifest.downloadURL) { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(progress.fractionCompleted)
            }
        }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
            throw UpdateError.invalidResponse
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribeUpdate-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporaryURL, to: target)
        return target
    }

    private func makeInstallScript(newAppURL: URL) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-localscribe-\(UUID().uuidString).zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        current="$1"
        replacement="$2"
        backup="${current}.previous"
        sleep 1
        rm -rf "$backup"
        if [[ -d "$current" ]]; then
          mv "$current" "$backup"
        fi
        ditto "$replacement" "$current"
        xattr -dr com.apple.FinderInfo "$current" 2>/dev/null || true
        xattr -dr com.apple.ResourceFork "$current" 2>/dev/null || true
        open "$current"
        rm -rf "$backup"
        rm -rf "$(dirname "$replacement")"
        rm -f "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

}

private actor UpdatePreparationActor {
    func prepare(
        packageURL: URL,
        manifest: AppUpdateManifest,
        expectedBundleIdentifier: String
    ) throws -> URL {
        let actualHash = try sha256Hex(of: packageURL)
        guard actualHash.lowercased() == manifest.sha256.lowercased() else {
            throw UpdateError.checksumMismatch
        }
        let appURL = try extractApp(from: packageURL)
        try validateExtractedApp(
            appURL,
            manifest: manifest,
            expectedBundleIdentifier: expectedBundleIdentifier
        )
        return appURL
    }

    private func extractApp(from packageURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalScribeUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", packageURL.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw UpdateError.extractionFailed(String(data: data, encoding: .utf8) ?? "ditto failed")
        }
        let candidates = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" } ?? []
        guard let appURL = candidates.first(where: { $0.lastPathComponent == "声迹.app" }) ?? candidates.first else {
            throw UpdateError.noAppInArchive
        }
        return appURL
    }

    private func validateExtractedApp(
        _ appURL: URL,
        manifest: AppUpdateManifest,
        expectedBundleIdentifier: String
    ) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == expectedBundleIdentifier,
              FileManager.default.fileExists(atPath: infoURL.path) else {
            throw UpdateError.invalidBundle
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard version == manifest.version, build == manifest.build else {
            throw UpdateError.versionMismatch
        }
        try verifyCodeSignature(appURL)
    }

    private func verifyCodeSignature(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "codesign failed"
            throw UpdateError.invalidCodeSignature(message)
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
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

private enum UpdateError: LocalizedError {
    case invalidResponse
    case checksumMismatch
    case extractionFailed(String)
    case noAppInArchive
    case invalidBundle
    case versionMismatch
    case invalidCodeSignature(String)
    case noDownloadedApp

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "更新服务器返回了无效响应。"
        case .checksumMismatch: "更新包校验失败，已停止安装。"
        case .extractionFailed(let message): "更新包解压失败：\(message)"
        case .noAppInArchive: "更新包中没有找到 .app。"
        case .invalidBundle: "更新包不是声迹应用。"
        case .versionMismatch: "更新包版本与更新说明不一致。"
        case .invalidCodeSignature(let message): "更新包签名验证失败：\(message)"
        case .noDownloadedApp: "尚未准备好可安装的更新。"
        }
    }
}

private extension URLSession {
    func download(
        from url: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.download(from: url)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Progress) -> Void

    init(progress: @escaping @Sendable (Progress) -> Void) {
        progressHandler = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Progress(totalUnitCount: totalBytesExpectedToWrite)
        progress.completedUnitCount = totalBytesWritten
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

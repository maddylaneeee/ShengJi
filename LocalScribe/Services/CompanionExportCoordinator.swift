import AppKit
import Foundation

struct CompanionExportResult: Sendable {
    let textURL: URL
    let audioURL: URL?
    let audioError: String?
    var isComplete: Bool { audioError == nil }
}

enum CompanionExportCoordinator {
    static func baseName(_ name: String, format: TranscriptExportFormat) throws -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix("." + format.fileExtension.lowercased()) { value = String(value.dropLast(format.fileExtension.count + 1)) }
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains(":"), !value.contains("\\"), !value.contains("\0") else { throw SessionAudioError.invalidPath }
        return value
    }
    /// Caller supplies explicit directory authority and collision approval. Each replacement
    /// preserves the prior file until its new version is ready; two-file success is never inferred.
    static func write(data: Data, format: TranscriptExportFormat, name: String, directory: URL,
                      audio: URL?, overwrite: Bool, copyAudio: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws -> CompanionExportResult {
        let base = try baseName(name, format: format)
        let textURL = directory.appendingPathComponent(base + "." + format.fileExtension)
        let audioURL = audio.map { _ in directory.appendingPathComponent(base + ".m4a") }
        let fm = FileManager.default
        let targets = [textURL] + (audioURL.map { [$0] } ?? [])
        if !overwrite, targets.contains(where: { fm.fileExists(atPath: $0.path) }) { throw CocoaError(.fileWriteFileExists) }
        // Temp files live in the selected directory so each final move stays on one volume.
        let tempText = directory.appendingPathComponent(".localscribe-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempText) }
        try data.write(to: tempText, options: .atomic)
        try commit(tempText, to: textURL, overwrite: overwrite)
        guard let audio, let audioURL else { return CompanionExportResult(textURL: textURL, audioURL: nil, audioError: nil) }
        let tempAudio = directory.appendingPathComponent(".localscribe-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempAudio) }
        do {
            try copyAudio(audio, tempAudio)
            try commit(tempAudio, to: audioURL, overwrite: overwrite)
            return CompanionExportResult(textURL: textURL, audioURL: audioURL, audioError: nil)
        } catch { return CompanionExportResult(textURL: textURL, audioURL: nil, audioError: error.localizedDescription) }
    }
    private static func commit(_ temporary: URL, to target: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            guard overwrite else { throw CocoaError(.fileWriteFileExists) }
            _ = try fm.replaceItemAt(target, withItemAt: temporary)
        } else { try fm.moveItem(at: temporary, to: target) }
    }
    @MainActor static func export(data: Data, format: TranscriptExportFormat, name: String, asset: SessionAudioAsset?, warning: String) async throws -> CompanionExportResult? {
        if let asset, !SessionAudioFeatures.permits(asset) { throw SessionAudioError.synthesisUnavailable }
        let base = try baseName(name, format: format)
        if asset != nil, !warning.isEmpty {
            guard await confirm(title: L10n.text("确认伴随音频"), message: warning, accept: L10n.text("继续导出")) else { return nil }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("选择文字稿和伴随音频的保存文件夹。")
        let response = await panel.begin()
        guard response == .OK, let directory = panel.url else { return nil }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        if let asset { SessionAudioStore.retain(asset.sessionID) }
        defer { if let asset { SessionAudioStore.release(asset.sessionID) } }
        let targets = [base + "." + format.fileExtension] + (asset == nil ? [] : [base + ".m4a"])
        let existing = targets.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        if !existing.isEmpty {
            guard await confirm(title: L10n.text("覆盖已有文件？"), message: existing.joined(separator: "\n"), accept: L10n.text("覆盖")) else { return nil }
        }
        let audio = try asset.map(SessionAudioStore.readableURL)
        return try await Task.detached(priority: .utility) {
            try write(data: data, format: format, name: base, directory: directory, audio: audio, overwrite: !existing.isEmpty)
        }.value
    }
    @MainActor private static func confirm(title: String, message: String, accept: String) async -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: accept); alert.addButton(withTitle: L10n.text("取消"))
        guard let window = NSApp.keyWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

import Foundation

struct RecoverySnapshot: Codable, Identifiable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case microphone
        case file
        case recovered
    }

    let id: UUID
    var schemaVersion: Int? = nil
    var journalRelativePath: String? = nil
    var journalRecordCount: Int? = nil
    var journalGeneration: Int? = nil
    var sourceTitle: String
    var sourceKind: SourceKind
    var localeIdentifier: String
    var configuration: RecognitionConfiguration
    var translationConfiguration: TranslationConfiguration?
    var transcriptText: String
    var translatedText: String?
    var translatedSegments: [TranscriptSegment]?
    var segmentTranslations: [SegmentTranslation]?
    var segments: [TranscriptSegment]
    var hasManualEdits: Bool
    var elapsed: TimeInterval
    var progress: Double
    var createdAt: Date
    var updatedAt: Date

    var shortPreview: String {
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "还没有已识别文字" }
        return String(text.prefix(80))
    }
}

enum RecoveryStore {
    static func load() -> RecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    static func save(_ snapshot: RecoverySnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Recovery is rewritten repeatedly during long tasks. Compact JSON keeps the
        // v1-compatible safety snapshot while the v2 journal remains append-only.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func clear() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var directoryURL: URL {
        LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/Recovery", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("latest.json")
    }
}

actor RecoverySnapshotWriter {
    func save(_ snapshot: RecoverySnapshot) {
        try? RecoveryStore.save(snapshot)
    }
}

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
    var isTextToSpeech: Bool? = nil
    var originalAudioEnabled: Bool? = nil
    var audioAsset: SessionAudioAsset? = nil
    var timelineProvenance: TimelineProvenance? = nil
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

    var availableFeaturesSnapshot: RecoverySnapshot {
        guard !SessionAudioFeatures.speechSynthesisEnabled else { return self }
        var result = self
        if let asset = result.audioAsset, !SessionAudioFeatures.permits(asset) { result.audioAsset = nil }
        if result.isTextToSpeech == true {
            result.isTextToSpeech = false
            result.sourceTitle = L10n.text("导入稿件")
            result.sourceKind = .recovered
            result.originalAudioEnabled = false
            result.audioAsset = nil
        }
        return result
    }

    var shortPreview: String {
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return L10n.text("还没有已识别文字") }
        return String(text.prefix(80))
    }
}

enum RecoveryStore {
    private static let writeLock = NSRecursiveLock()
    private static var clearedSessions: Set<UUID> = []
    static func load() -> RecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(RecoverySnapshot.self, from: data).availableFeaturesSnapshot
        } catch {
            return nil
        }
    }

    static func save(_ snapshot: RecoverySnapshot) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !clearedSessions.contains(snapshot.id), load().map({ $0.updatedAt <= snapshot.updatedAt }) ?? true else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Recovery is rewritten repeatedly during long tasks. Compact JSON keeps the
        // v1-compatible safety snapshot while the v2 journal remains append-only.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    static func clear() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let previous = load()?.id
        if let previous { clearedSessions.insert(previous) }
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        if let previous { SessionAudioStore.retire(previous) }
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
        let previous = RecoveryStore.load()?.id
        do {
            try RecoveryStore.save(snapshot)
            if let previous, previous != snapshot.id { SessionAudioStore.retire(previous) }
        } catch { }
    }
}

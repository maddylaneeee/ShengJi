import Foundation

final class EventRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: UInt64 = 0

    func shouldEmit(every interval: Duration) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let components = interval.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let requested = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
        return lock.withLock {
            guard lastEmission == 0 || now &- lastEmission >= requested else { return false }
            lastEmission = now
            return true
        }
    }
}

struct TranscriptPage: Sendable {
    let offset: Int
    let totalCount: Int
    let segments: [TranscriptSegment]
}

actor TranscriptRepository {
    private struct SourceJournalIndexEntry: Sendable {
        let offset: UInt64
        let length: Int
        let segmentStart: Int
        let segmentCount: Int
    }

    private enum RecordKind: String, Codable {
        case sourceSegments
        case translations
        case manualSnapshot
        case event
    }

    private struct JournalRecord: Codable {
        let schemaVersion: Int
        let timestamp: Date
        let kind: RecordKind
        let sourceSegments: [TranscriptSegment]?
        let translations: [SegmentTranslation]?
        let transcriptText: String?
        let message: String?
    }

    let sessionID: UUID
    let directoryURL: URL
    let journalURL: URL
    let eventLogURL: URL

    // Only the active tail stays resident. Older pages are replayed from the
    // append-only journal on demand so this actor does not duplicate the full
    // transcript already owned by the session model.
    private var sourceSegments: [TranscriptSegment] = []
    private var totalSourceCount = 0
    private var translations: [SegmentTranslation] = []
    private var sourceIDs: Set<UUID> = []
    private var cachedPages: [Int: TranscriptPage] = [:]
    private var pageOrder: [Int] = []
    private var sourceJournalIndex: [SourceJournalIndexEntry] = []
    private var journalIndexLoaded = false

    init(sessionID: UUID) {
        self.sessionID = sessionID
        directoryURL = LocalScribePaths.applicationSupportDirectory
            .appendingPathComponent("声迹/Sessions/\(sessionID.uuidString)", isDirectory: true)
        journalURL = directoryURL.appendingPathComponent("transcript.jsonl")
        eventLogURL = directoryURL.appendingPathComponent("events.jsonl")
    }

    func appendSourceSegments(_ segments: [TranscriptSegment]) {
        loadJournalIndexIfNeeded()
        let unique = segments.filter { sourceIDs.insert($0.id).inserted }
        guard !unique.isEmpty else { return }
        let segmentStart = totalSourceCount
        sourceSegments.append(contentsOf: unique)
        totalSourceCount += unique.count
        if sourceSegments.count > 600 {
            sourceSegments.removeFirst(sourceSegments.count - 600)
        }
        cachedPages.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        let position = append(JournalRecord(
            schemaVersion: 1,
            timestamp: Date(),
            kind: .sourceSegments,
            sourceSegments: unique,
            translations: nil,
            transcriptText: nil,
            message: nil
        ), to: journalURL)
        if let position {
            sourceJournalIndex.append(SourceJournalIndexEntry(
                offset: position.offset,
                length: position.length,
                segmentStart: segmentStart,
                segmentCount: unique.count
            ))
        }
    }

    func replaceManualTranscript(text: String, segments: [TranscriptSegment]) {
        loadJournalIndexIfNeeded()
        sourceSegments = segments
        totalSourceCount = segments.count
        if sourceSegments.count > 600 {
            sourceSegments = Array(sourceSegments.suffix(600))
        }
        sourceIDs = Set(sourceSegments.map(\.id))
        cachedPages.removeAll(keepingCapacity: true)
        pageOrder.removeAll(keepingCapacity: true)
        let position = append(JournalRecord(
            schemaVersion: 1,
            timestamp: Date(),
            kind: .manualSnapshot,
            sourceSegments: segments,
            translations: nil,
            transcriptText: text,
            message: nil
        ), to: journalURL)
        if let position {
            sourceJournalIndex = [SourceJournalIndexEntry(
                offset: position.offset,
                length: position.length,
                segmentStart: 0,
                segmentCount: segments.count
            )]
        }
    }

    func replaceTranslations(_ values: [SegmentTranslation]) {
        translations = values
        append(JournalRecord(
            schemaVersion: 1,
            timestamp: Date(),
            kind: .translations,
            sourceSegments: nil,
            translations: values,
            transcriptText: nil,
            message: nil
        ), to: journalURL)
    }

    func page(offset: Int, limit: Int = 200) -> TranscriptPage {
        loadJournalIndexIfNeeded()
        let safeLimit = max(1, min(limit, 500))
        let safeOffset = max(0, min(offset, totalSourceCount))
        let pageKey = safeOffset / safeLimit
        if let cached = cachedPages[pageKey] { return cached }
        let segments = readSourceSegments(offset: safeOffset, limit: safeLimit)
        let page = TranscriptPage(
            offset: safeOffset,
            totalCount: totalSourceCount,
            segments: segments
        )
        cachedPages[pageKey] = page
        pageOrder.removeAll { $0 == pageKey }
        pageOrder.append(pageKey)
        while pageOrder.count > 3, let evicted = pageOrder.first {
            pageOrder.removeFirst()
            cachedPages.removeValue(forKey: evicted)
        }
        return page
    }

    func allSegments() -> [TranscriptSegment] {
        loadJournalIndexIfNeeded()
        return readSourceSegments(offset: 0, limit: totalSourceCount)
    }

    func log(_ message: String) {
        append(JournalRecord(
            schemaVersion: 1,
            timestamp: Date(),
            kind: .event,
            sourceSegments: nil,
            translations: nil,
            transcriptText: nil,
            message: message
        ), to: eventLogURL)
    }

    @discardableResult
    private func append(_ record: JournalRecord, to url: URL) -> (offset: UInt64, length: Int)? {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var data = try encoder.encode(record)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: [.atomic])
                return (0, data.count)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return (offset, data.count)
        } catch {
            // Recovery snapshots remain the compatibility fallback if journaling fails.
            return nil
        }
    }

    private func loadJournalIndexIfNeeded() {
        guard !journalIndexLoaded else { return }
        journalIndexLoaded = true
        guard let handle = try? FileHandle(forReadingFrom: journalURL) else {
            totalSourceCount = sourceSegments.count
            return
        }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var pending = Data()
        var pendingOffset: UInt64 = 0
        var count = 0
        var index: [SourceJournalIndexEntry] = []
        var ids: Set<UUID> = []

        func consume(_ line: Data, offset: UInt64, length: Int) {
            guard let record = try? decoder.decode(JournalRecord.self, from: line) else { return }
            switch record.kind {
            case .sourceSegments:
                let segments = (record.sourceSegments ?? []).filter { ids.insert($0.id).inserted }
                if !segments.isEmpty {
                    index.append(SourceJournalIndexEntry(
                        offset: offset,
                        length: length,
                        segmentStart: count,
                        segmentCount: segments.count
                    ))
                    count += segments.count
                }
            case .manualSnapshot:
                let segments = record.sourceSegments ?? []
                index = [SourceJournalIndexEntry(
                    offset: offset,
                    length: length,
                    segmentStart: 0,
                    segmentCount: segments.count
                )]
                count = segments.count
                ids = Set(segments.map(\.id))
            case .translations, .event:
                break
            }
        }

        while true {
            let chunk = handle.readData(ofLength: 64 * 1_024)
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineLength = pending.distance(from: pending.startIndex, to: newline) + 1
                let line = Data(pending[..<newline])
                consume(line, offset: pendingOffset, length: lineLength)
                pending.removeFirst(lineLength)
                pendingOffset += UInt64(lineLength)
            }
        }
        if !pending.isEmpty {
            consume(pending, offset: pendingOffset, length: pending.count)
        }

        sourceJournalIndex = index
        totalSourceCount = count
        sourceIDs = ids
    }

    private func readSourceSegments(offset: Int, limit: Int) -> [TranscriptSegment] {
        guard limit > 0, offset < totalSourceCount else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: journalURL) else {
            let localOffset = max(0, offset - (totalSourceCount - sourceSegments.count))
            let end = min(localOffset + limit, sourceSegments.count)
            guard localOffset < end else { return [] }
            return Array(sourceSegments[localOffset..<end])
        }
        defer { try? handle.close() }

        let requestedEnd = min(offset + limit, totalSourceCount)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var output: [TranscriptSegment] = []

        for entry in sourceJournalIndex {
            let entryEnd = entry.segmentStart + entry.segmentCount
            guard entryEnd > offset else { continue }
            guard entry.segmentStart < requestedEnd else { break }
            do {
                try handle.seek(toOffset: entry.offset)
                guard var data = try handle.read(upToCount: entry.length), !data.isEmpty else { continue }
                if data.last == 0x0A { data.removeLast() }
                guard let record = try? decoder.decode(JournalRecord.self, from: data) else { continue }
                let segments = record.sourceSegments ?? []
                let lower = max(offset, entry.segmentStart) - entry.segmentStart
                let upper = min(requestedEnd, entryEnd) - entry.segmentStart
                guard lower < upper, lower < segments.count else { continue }
                output.append(contentsOf: segments[lower..<min(upper, segments.count)])
                if output.count >= limit { break }
            } catch {
                continue
            }
        }
        return output
    }
}

struct FloatRingBuffer: Sendable {
    private var storage: [Float] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(contentsOf values: [Float]) {
        storage.append(contentsOf: values)
    }

    mutating func takeFirst(_ requestedCount: Int) -> [Float] {
        let amount = min(max(requestedCount, 0), count)
        guard amount > 0 else { return [] }
        let end = head + amount
        let output = Array(storage[head..<end])
        head = end
        compactIfNeeded()
        return output
    }

    mutating func takeAll() -> [Float] {
        takeFirst(count)
    }

    func suffix(_ requestedCount: Int) -> [Float] {
        let amount = min(max(requestedCount, 0), count)
        guard amount > 0 else { return [] }
        return Array(storage[(storage.count - amount)..<storage.count])
    }

    private mutating func compactIfNeeded() {
        guard head > 65_536, head * 2 >= storage.count else { return }
        storage.removeFirst(head)
        head = 0
    }
}

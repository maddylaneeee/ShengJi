import Foundation

struct ImportedTranscript: Sendable, Equatable {
    let title: String
    let text: String
    let segments: [TranscriptSegment]
    let duration: TimeInterval
}

enum TranscriptImportError: LocalizedError {
    case unreadable
    case empty
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: L10n.text("无法读取所选稿件。")
        case .empty: L10n.text("稿件中没有可导入的文字。")
        case .unsupported: L10n.text("暂不支持这种稿件格式。请选择 SRT、VTT、TXT、Markdown 或声迹 JSON。")
        }
    }
}

enum TranscriptImporter {
    static func load(url: URL) throws -> ImportedTranscript {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw TranscriptImportError.unreadable }
        return try parse(data: data, fileName: url.lastPathComponent)
    }

    static func parse(data: Data, fileName: String) throws -> ImportedTranscript {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        switch ext {
        case "srt":
            return try subtitle(textData: data, title: title, isWebVTT: false)
        case "vtt":
            return try subtitle(textData: data, title: title, isWebVTT: true)
        case "txt", "md", "markdown":
            guard let text = decodedText(data)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw TranscriptImportError.empty
            }
            let segments = TranscriptSegment.sentenceSegments(from: text, duration: max(Double(text.count) / 5, 1))
            return ImportedTranscript(title: title, text: text, segments: segments, duration: segments.last?.endTime ?? 1)
        case "json":
            return try json(data: data, fallbackTitle: title)
        default:
            throw TranscriptImportError.unsupported
        }
    }

    private static func subtitle(textData data: Data, title: String, isWebVTT: Bool) throws -> ImportedTranscript {
        guard var source = decodedText(data) else { throw TranscriptImportError.unreadable }
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        if isWebVTT, source.hasPrefix("WEBVTT") {
            source = source.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        }

        let blocks = source.components(separatedBy: "\n\n")
        var segments: [TranscriptSegment] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = parseTimestamp(timing[0]),
                  let end = parseTimestamp(timing[1]) else { continue }
            let text = lines.dropFirst(timingIndex + 1)
                .map(stripSubtitleMarkup)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(startTime: start, endTime: max(end, start + 0.05), text: text))
        }
        guard !segments.isEmpty else { throw TranscriptImportError.empty }
        let text = segments.map(\.text).joined(separator: "\n")
        return ImportedTranscript(title: title, text: text, segments: segments, duration: segments.map(\.endTime).max() ?? 1)
    }

    private static func json(data: Data, fallbackTitle: String) throws -> ImportedTranscript {
        struct Payload: Decodable {
            let title: String?
            let duration: TimeInterval?
            let text: String
            let segments: [TranscriptSegment]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TranscriptImportError.unreadable
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptImportError.empty }
        let duration = max(payload.duration ?? payload.segments?.last?.endTime ?? Double(text.count) / 5, 1)
        let segments = payload.segments?.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? TranscriptSegment.sentenceSegments(from: text, duration: duration)
        return ImportedTranscript(title: payload.title ?? fallbackTitle, text: text, segments: segments, duration: duration)
    }

    private static func decodedText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? raw
        let fields = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard fields.count >= 2 else { return nil }
        let seconds = Double(fields.last ?? "")
        let minutes = Double(fields[fields.count - 2])
        let hours = fields.count > 2 ? Double(fields[fields.count - 3]) : 0
        guard let seconds, let minutes, let hours else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func stripSubtitleMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "{\\[^}]+}", with: "", options: .regularExpression)
    }
}

enum TranscriptTextEditing {
    static func validRange(_ range: NSRange, in text: String) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location + range.length <= (text as NSString).length else { return nil }
        return range
    }

    static func replacing(_ text: String, range: NSRange, with replacement: String) -> (String, NSRange)? {
        guard let range = validRange(range, in: text) else { return nil }
        let output = (text as NSString).replacingCharacters(in: range, with: replacement)
        return (output, NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }

    static func deletingBefore(_ text: String, node: NSRange) -> (String, NSRange)? {
        guard let node = validRange(node, in: text) else { return nil }
        return replacing(text, range: NSRange(location: 0, length: node.location), with: "")
    }

    static func deletingAfter(_ text: String, node: NSRange) -> (String, NSRange)? {
        guard let node = validRange(node, in: text) else { return nil }
        let start = node.location + node.length
        return replacing(text, range: NSRange(location: start, length: (text as NSString).length - start), with: "")
    }

    static func deletingBetween(_ text: String, first: NSRange, second: NSRange) -> (String, NSRange)? {
        guard let first = validRange(first, in: text), let second = validRange(second, in: text) else { return nil }
        let earlier = first.location <= second.location ? first : second
        let later = first.location <= second.location ? second : first
        let start = earlier.location + earlier.length
        guard later.location >= start else { return nil }
        return replacing(text, range: NSRange(location: start, length: later.location - start), with: "")
    }

    static func find(_ query: String, in text: String, after selection: NSRange) -> NSRange? {
        guard !query.isEmpty else { return nil }
        let full = text as NSString
        let start = min(selection.location + selection.length, full.length)
        let tail = NSRange(location: start, length: full.length - start)
        let found = full.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: tail)
        if found.location != NSNotFound { return found }
        let wrapped = full.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: 0, length: start))
        return wrapped.location == NSNotFound ? nil : wrapped
    }
}

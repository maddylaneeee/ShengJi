import Foundation

/// A timed caption ready to be burned into video frames.
struct SubtitleCue: Equatable, Sendable {
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
}

enum SubtitleFileFormat: String, CaseIterable, Sendable {
    case srt
    case webVTT
    case localScribeJSON
    case ass
    case sbv
    case ttml

    var title: String {
        switch self {
        case .srt: "SRT"
        case .webVTT: "WebVTT"
        case .localScribeJSON: L10n.text("声迹 JSON")
        case .ass: "ASS/SSA"
        case .sbv: "SBV"
        case .ttml: "TTML/DFXP"
        }
    }
}

struct SubtitleDocument: Equatable, Sendable {
    let format: SubtitleFileFormat
    /// Cues sorted by start time. Every cue has finite, non-negative times,
    /// `endTime > startTime`, and non-empty text.
    let cues: [SubtitleCue]

    var firstStart: TimeInterval { cues.first?.startTime ?? 0 }
    var lastEnd: TimeInterval { cues.map(\.endTime).max() ?? 0 }

    func warnings(videoDuration: TimeInterval?) -> [SubtitleDocumentWarning] {
        var warnings: [SubtitleDocumentWarning] = []
        if let videoDuration, videoDuration.isFinite, videoDuration > 0 {
            let beyond = cues.filter { $0.endTime > videoDuration + 0.05 }.count
            if beyond > 0 { warnings.append(.beyondVideo(count: beyond)) }
        }
        var overlaps = 0
        var latestEnd = -Double.infinity
        for cue in cues {
            if cue.startTime < latestEnd - 0.001 { overlaps += 1 }
            latestEnd = max(latestEnd, cue.endTime)
        }
        if overlaps > 0 { warnings.append(.overlapping(count: overlaps)) }
        return warnings
    }
}

enum SubtitleDocumentWarning: Equatable, Sendable {
    case beyondVideo(count: Int)
    case overlapping(count: Int)

    var message: String {
        switch self {
        case .beyondVideo(let count):
            L10n.format("%lld 条字幕超出视频结尾，超出部分不会显示。", Int64(count))
        case .overlapping(let count):
            L10n.format("%lld 条字幕与前一条时间重叠，将上下堆叠显示。", Int64(count))
        }
    }
}

enum SubtitleValidationError: LocalizedError, Equatable {
    case unreadable
    case unsupportedFormat
    case noTimestamps
    case unreliableTimeline
    case invalidTimestamp(line: Int)
    case invalidSegment(index: Int)
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadable:
            L10n.text("无法读取所选字幕文件。")
        case .unsupportedFormat:
            L10n.text("不支持：格式不受支持。请选择 SRT、WebVTT、声迹 JSON、ASS/SSA、SBV 或 TTML/DFXP 字幕。")
        case .noTimestamps:
            L10n.text("不支持：文件中没有时间戳。")
        case .unreliableTimeline:
            L10n.text("不支持：这份声迹 JSON 的时间轴是估算值，没有可靠时间戳。")
        case .invalidTimestamp(let line):
            L10n.format("不支持：第 %lld 行时间戳无效。", Int64(line))
        case .invalidSegment(let index):
            L10n.format("不支持：第 %lld 个片段的时间戳无效。", Int64(index))
        case .noText:
            L10n.text("不支持：字幕中没有文字。")
        }
    }
}

/// Strict parser used for subtitle burning. Unlike the lenient transcript
/// importer, any malformed timestamp rejects the whole file so a burned video
/// never silently loses or misplaces captions.
enum SubtitleFileParser {
    static let supportedExtensions = ["srt", "vtt", "json", "ass", "ssa", "sbv", "ttml", "dfxp", "xml"]

    static func load(url: URL) throws -> SubtitleDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw SubtitleValidationError.unreadable }
        return try parse(data: data, fileName: url.lastPathComponent)
    }

    static func parse(data: Data, fileName: String) throws -> SubtitleDocument {
        guard !data.isEmpty, let rawText = decodedText(data) else { throw SubtitleValidationError.unsupportedFormat }
        let text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard let format = detectFormat(text: text, fileExtension: ext) else {
            throw SubtitleValidationError.unsupportedFormat
        }
        let cues: [SubtitleCue]
        switch format {
        case .srt: cues = try parseArrowCues(text, isWebVTT: false)
        case .webVTT: cues = try parseArrowCues(text, isWebVTT: true)
        case .localScribeJSON: cues = try parseJSON(data)
        case .ass: cues = try parseASS(text)
        case .sbv: cues = try parseSBV(text)
        case .ttml: cues = try TTMLParser.parse(data)
        }
        guard !cues.isEmpty else { throw SubtitleValidationError.noText }
        return SubtitleDocument(format: format, cues: cues.sorted { $0.startTime < $1.startTime })
    }

    // MARK: Detection

    static func detectFormat(text: String, fileExtension ext: String) -> SubtitleFileFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("WEBVTT") { return .webVTT }
        if trimmed.hasPrefix("{") { return .localScribeJSON }
        let head = String(trimmed.prefix(4_096))
        if head.range(of: "[Script Info]", options: .caseInsensitive) != nil
            || head.range(of: "[Events]", options: .caseInsensitive) != nil
            || trimmed.range(of: #"(?m)^Dialogue:\s*"#, options: .regularExpression) != nil {
            return .ass
        }
        if trimmed.hasPrefix("<") {
            return head.range(of: "<tt", options: .caseInsensitive) != nil ? .ttml : nil
        }
        if let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first,
           firstLine.trimmingCharacters(in: .whitespaces).range(of: sbvTimingPattern, options: .regularExpression) != nil {
            return .sbv
        }
        if trimmed.contains("-->") { return ext == "vtt" ? .webVTT : .srt }
        // Recognized subtitle extension, but no timing structure at all.
        switch ext {
        case "srt": return .srt
        case "vtt": return .webVTT
        case "ass", "ssa": return .ass
        case "sbv": return .sbv
        default: return nil
        }
    }

    // MARK: SRT / WebVTT

    private static func parseArrowCues(_ text: String, isWebVTT: Bool) throws -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        guard text.contains("-->") else {
            // A line that looks like a timing line with a broken arrow is a malformed timestamp.
            if let index = lines.firstIndex(where: { $0.range(of: #"\d:\d{2}.*-+>"#, options: .regularExpression) != nil }) {
                throw SubtitleValidationError.invalidTimestamp(line: index + 1)
            }
            throw SubtitleValidationError.noTimestamps
        }
        // Trim each line once; large files have tens of thousands of lines.
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(lines.count / 4)
        var sawTiming = false
        var index = 0
        if isWebVTT {
            // Skip the WEBVTT header block.
            while index < trimmed.count, !trimmed[index].isEmpty { index += 1 }
        }
        while index < trimmed.count {
            while index < trimmed.count, trimmed[index].isEmpty { index += 1 }
            guard index < trimmed.count else { break }
            let blockStart = index
            var block: [(number: Int, text: String)] = []
            while index < trimmed.count, !trimmed[index].isEmpty {
                block.append((index + 1, trimmed[index]))
                index += 1
            }
            if isWebVTT, let first = block.first?.text,
               first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" {
                continue
            }
            guard let timingOffset = block.firstIndex(where: { $0.text.contains("-->") }) else {
                // A text block without a timing line means a broken or missing timestamp.
                throw SubtitleValidationError.invalidTimestamp(line: blockStart + 1)
            }
            // SRT allows a numeric counter, VTT an identifier, before the timing line.
            guard timingOffset <= 1 else {
                throw SubtitleValidationError.invalidTimestamp(line: block[0].number)
            }
            sawTiming = true
            let timing = block[timingOffset]
            let parts = timing.text.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseClock(parts[0].trimmingCharacters(in: .whitespaces), allowsMissingHours: isWebVTT),
                  let endField = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = parseClock(String(endField), allowsMissingHours: isWebVTT),
                  end > start else {
                throw SubtitleValidationError.invalidTimestamp(line: timing.number)
            }
            let body = block.dropFirst(timingOffset + 1)
                .map { stripMarkup($0.text) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(startTime: start, endTime: end, text: body)) }
        }
        guard sawTiming else { throw SubtitleValidationError.noTimestamps }
        return cues
    }

    /// Parses `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, or (WebVTT) `MM:SS.mmm`.
    /// Hand-written instead of a regular expression: it runs twice per cue.
    static func parseClock(_ raw: String, allowsMissingHours: Bool) -> TimeInterval? {
        let fields = raw.utf8.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard fields.count == 3 || (allowsMissingHours && fields.count == 2) else { return nil }
        let last = fields[fields.count - 1]
        guard let separator = last.firstIndex(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ",") }) else { return nil }
        let secondsField = last[last.startIndex..<separator]
        let fractionField = last[last.index(after: separator)...]
        let hoursField = fields.count == 3 ? fields[0] : nil
        let minutesField = fields[fields.count - 2]

        var hours = 0
        if let hoursField {
            guard let parsed = digits(hoursField, lengths: 1...9) else { return nil }
            hours = parsed
        }
        guard let minutes = digits(minutesField, lengths: 1...2),
              let seconds = digits(secondsField, lengths: 2...2),
              let fraction = digits(fractionField, lengths: 1...3),
              minutes < 60, seconds < 60 else { return nil }
        let divisor = pow(10, Double(fractionField.count))
        return Double(hours) * 3_600 + Double(minutes) * 60 + Double(seconds) + Double(fraction) / divisor
    }

    // MARK: SBV

    private static let sbvTimingPattern = #"^\d+:\d{1,2}:\d{2}\.\d{1,3},\d+:\d{1,2}:\d{2}\.\d{1,3}$"#

    private static func parseSBV(_ text: String) throws -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var cues: [SubtitleCue] = []
        var sawTiming = false
        var index = 0
        while index < lines.count {
            while index < lines.count, lines[index].isEmpty { index += 1 }
            guard index < lines.count else { break }
            let timingLine = lines[index]
            let timingNumber = index + 1
            index += 1
            let parts = timingLine.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let start = parseClock(String(parts[0]), allowsMissingHours: false),
                  let end = parseClock(String(parts[1]), allowsMissingHours: false),
                  end > start else {
                throw SubtitleValidationError.invalidTimestamp(line: timingNumber)
            }
            sawTiming = true
            var body: [String] = []
            while index < lines.count, !lines[index].isEmpty {
                body.append(stripMarkup(lines[index]))
                index += 1
            }
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { cues.append(SubtitleCue(startTime: start, endTime: end, text: joined)) }
        }
        guard sawTiming else { throw SubtitleValidationError.noTimestamps }
        return cues
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) throws -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var inEvents = false
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [SubtitleCue] = []
        var sawDialogue = false
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            let prefix = line.prefix(9).lowercased()
            if prefix.hasPrefix("format:") {
                fields = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard prefix == "dialogue:" else { continue }
            sawDialogue = true
            let values = line.dropFirst("dialogue:".count)
                .split(separator: ",", maxSplits: max(fields.count - 1, 0), omittingEmptySubsequences: false)
                .map(String.init)
            guard values.count == fields.count,
                  let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text"),
                  let start = parseASSTime(values[startIndex].trimmingCharacters(in: .whitespaces)),
                  let end = parseASSTime(values[endIndex].trimmingCharacters(in: .whitespaces)),
                  end > start else {
                throw SubtitleValidationError.invalidTimestamp(line: offset + 1)
            }
            let rawText = values[textIndex]
            let body = (rawText.contains("{")
                ? rawText.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                : rawText)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(startTime: start, endTime: end, text: body)) }
        }
        guard sawDialogue else { throw SubtitleValidationError.noTimestamps }
        return cues
    }

    /// ASS uses `H:MM:SS.cc` (centiseconds).
    static func parseASSTime(_ raw: String) -> TimeInterval? {
        let fields = raw.utf8.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let last = fields[2]
        let separator = last.firstIndex(of: UInt8(ascii: "."))
        let secondsField = separator.map { last[last.startIndex..<$0] } ?? last[...]
        let fractionField = separator.map { last[last.index(after: $0)...] }
        guard let hours = digits(fields[0], lengths: 1...9),
              let minutes = digits(fields[1], lengths: 1...2),
              let seconds = digits(secondsField, lengths: 1...2),
              minutes < 60, seconds < 60 else { return nil }
        var value = Double(hours) * 3_600 + Double(minutes) * 60 + Double(seconds)
        if let fractionField {
            guard let number = digits(fractionField, lengths: 1...3) else { return nil }
            value += Double(number) / pow(10, Double(fractionField.count))
        }
        return value
    }

    /// Parses ASCII digits only (no sign or spaces) with a length limit.
    private static func digits<S: Collection>(_ bytes: S, lengths: ClosedRange<Int>) -> Int? where S.Element == UInt8 {
        guard lengths.contains(bytes.count) else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    // MARK: LocalScribe JSON

    private static func parseJSON(_ data: Data) throws -> [SubtitleCue] {
        struct Segment: Decodable {
            let startTime: Double
            let endTime: Double
            let text: String
        }
        struct Payload: Decodable {
            let text: String?
            let segments: [Segment]?
            let timelineProvenance: TimelineProvenance?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw SubtitleValidationError.unsupportedFormat
        }
        guard let segments = payload.segments, !segments.isEmpty else {
            throw SubtitleValidationError.noTimestamps
        }
        if let provenance = payload.timelineProvenance, !provenance.isReliable {
            throw SubtitleValidationError.unreliableTimeline
        }
        var cues: [SubtitleCue] = []
        for (index, segment) in segments.enumerated() {
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime > segment.startTime else {
                throw SubtitleValidationError.invalidSegment(index: index + 1)
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(startTime: segment.startTime, endTime: segment.endTime, text: text)) }
        }
        return cues
    }

    // MARK: Helpers

    static func decodedText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        // Text subtitle files never contain NUL bytes without a UTF-16 BOM.
        if data.prefix(8_192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    static func stripMarkup(_ text: String) -> String {
        // Most cue lines carry no markup; skip the regular expressions for them.
        guard text.contains(where: { $0 == "<" || $0 == "{" || $0 == "&" }) else { return text }
        return text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - TTML / DFXP

private final class TTMLParser: NSObject, XMLParserDelegate {
    private var frameRate: Double = 30
    private var tickRate: Double?
    private var cues: [SubtitleCue] = []
    private var sawTimedParagraph = false
    private var sawTT = false
    private var failure: SubtitleValidationError?
    /// Begin offsets of enclosing timed containers (`body`, `div`).
    private var containerOffsets: [Double] = []
    private var elementStack: [String] = []
    private var paragraph: (start: Double, end: Double, text: String)?
    private var paragraphDepth = 0

    static func parse(_ data: Data) throws -> [SubtitleCue] {
        let delegate = TTMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        let succeeded = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard succeeded, delegate.sawTT else { throw SubtitleValidationError.unsupportedFormat }
        guard delegate.sawTimedParagraph else { throw SubtitleValidationError.noTimestamps }
        return delegate.cues
    }

    private func fail(_ error: SubtitleValidationError, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        elementStack.append(name)
        func attribute(_ key: String) -> String? {
            attributes.first { $0.key.lowercased() == key.lowercased() || $0.key.lowercased().hasSuffix(":" + key.lowercased()) }?.value
        }
        switch name {
        case "tt":
            sawTT = true
            if let rate = attribute("frameRate").flatMap(Double.init), rate > 0 { frameRate = rate }
            if let multiplier = attribute("frameRateMultiplier") {
                let parts = multiplier.split(separator: " ").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { frameRate *= parts[0] / parts[1] }
            }
            if let rate = attribute("tickRate").flatMap(Double.init), rate > 0 { tickRate = rate }
        case "body", "div":
            let base = containerOffsets.last ?? 0
            if let begin = attribute("begin") {
                guard let value = time(begin) else { return fail(.invalidTimestamp(line: parser.lineNumber), parser) }
                containerOffsets.append(base + value)
            } else {
                containerOffsets.append(base)
            }
        case "p":
            paragraphDepth = elementStack.count
            let base = containerOffsets.last ?? 0
            let beginRaw = attribute("begin"), endRaw = attribute("end"), durRaw = attribute("dur")
            guard beginRaw != nil || endRaw != nil || durRaw != nil else {
                return fail(.invalidTimestamp(line: parser.lineNumber), parser)
            }
            let parsedBegin: Double?
            if let beginRaw { parsedBegin = time(beginRaw) } else { parsedBegin = 0 }
            guard let begin = parsedBegin else { return fail(.invalidTimestamp(line: parser.lineNumber), parser) }
            let end: Double?
            if let endRaw { end = time(endRaw) } else if let durRaw { end = time(durRaw).map { begin + $0 } } else { end = nil }
            guard let end, end > begin else { return fail(.invalidTimestamp(line: parser.lineNumber), parser) }
            sawTimedParagraph = true
            paragraph = (base + begin, base + end, "")
        case "br":
            paragraph?.text.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if (name == "body" || name == "div"), !containerOffsets.isEmpty { containerOffsets.removeLast() }
        if name == "p", elementStack.count == paragraphDepth, let paragraph {
            let text = paragraph.text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(startTime: paragraph.start, endTime: paragraph.end, text: text)) }
            self.paragraph = nil
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraph != nil else { return }
        // XML whitespace inside <p> collapses to single spaces; explicit <br/> carries line breaks.
        let collapsed = string.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        paragraph?.text.append(collapsed)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil, !sawTT { failure = .unsupportedFormat }
    }

    /// TTML clock time (`HH:MM:SS(.fff)`, `HH:MM:SS:FF`) or offset time (`1.5s`, `500ms`, `2m`, `1h`, `30f`, `100t`).
    private func time(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let match = value.firstMatch(of: #/^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$/#),
           let h = Double(match.1), let m = Double(match.2), let s = Double(match.3), m < 60, s < 60 {
            var result = h * 3_600 + m * 60 + s
            if let fraction = match.4, let number = Double(fraction) { result += number / pow(10, Double(fraction.count)) }
            return result
        }
        if let match = value.firstMatch(of: #/^(\d+):(\d{2}):(\d{2}):(\d+)(?:\.\d+)?$/#),
           let h = Double(match.1), let m = Double(match.2), let s = Double(match.3), let f = Double(match.4),
           m < 60, s < 60, f < frameRate.rounded(.up) {
            return h * 3_600 + m * 60 + s + f / frameRate
        }
        if let match = value.firstMatch(of: #/^(\d+(?:\.\d+)?)(h|ms|m|s|f|t)$/#), let number = Double(match.1) {
            switch match.2 {
            case "h": return number * 3_600
            case "m": return number * 60
            case "s": return number
            case "ms": return number / 1_000
            case "f": return number / frameRate
            case "t": return number / (tickRate ?? frameRate)
            default: return nil
            }
        }
        return nil
    }
}

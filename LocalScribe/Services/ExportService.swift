import AppKit
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        .plainText, UTType(filenameExtension: "md") ?? .plainText, .json, .pdf,
        UTType(filenameExtension: "srt") ?? .plainText,
        UTType(filenameExtension: "vtt") ?? .plainText
    ]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct JSONTranscript: Codable {
    let title: String
    let source: String
    let language: String
    let createdAt: Date
    let duration: TimeInterval
    let text: String
    let segments: [TranscriptSegment]
    let translations: [SegmentTranslation]?
    let timelineProvenance: TimelineProvenance
}

enum TranscriptExporter {
    static func makeData(
        format: TranscriptExportFormat,
        title: String,
        source: String,
        language: String,
        duration: TimeInterval,
        text: String,
        segments: [TranscriptSegment],
        hasManualEdits: Bool,
        translations: [SegmentTranslation] = []
    ) throws -> Data {
        switch format {
        case .txt:
            return Data(text.utf8)
        case .markdown:
            let markdown = """
            # \(title)

            > 来源：\(source)
            > 语言：\(language)
            > 时长：\(duration.formattedDuration)

            \(text)
            """
            return Data(markdown.utf8)
        case .json:
            let payload = JSONTranscript(
                title: title,
                source: source,
                language: language,
                createdAt: Date(),
                duration: duration,
                text: text,
                segments: subtitleSegments(text: text, duration: duration, segments: segments, manuallyEdited: hasManualEdits),
                translations: translations.isEmpty ? nil : translations,
                timelineProvenance: hasManualEdits || segments.isEmpty ? .estimated : .json
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(payload)
        case .pdf:
            return try PDFTranscriptRenderer.render(
                title: title,
                metadata: "\(source) · \(language) · \(duration.formattedDuration)",
                text: text
            )
        case .srt:
            let output = formattedSubtitleCues(text: text, duration: duration, segments: segments, manuallyEdited: hasManualEdits)
                .enumerated()
                .map { index, segment in
                    "\(index + 1)\n\(srtTime(segment.startTime)) --> \(srtTime(segment.endTime))\n\(segment.text)"
                }
                .joined(separator: "\n\n")
            return Data((output + "\n").utf8)
        case .webVTT:
            let body = formattedSubtitleCues(text: text, duration: duration, segments: segments, manuallyEdited: hasManualEdits)
                .map { segment in
                    "\(vttTime(segment.startTime)) --> \(vttTime(segment.endTime))\n\(segment.text)"
                }
                .joined(separator: "\n\n")
            return Data(("WEBVTT\n\n" + body + "\n").utf8)
        }
    }

    private static func subtitleSegments(
        text: String,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        manuallyEdited: Bool
    ) -> [TranscriptSegment] {
        let source = (manuallyEdited || segments.isEmpty)
            ? TranscriptSegment.sentenceSegments(from: text, duration: duration)
            : segments.sorted { $0.startTime < $1.startTime }
        return source.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func formattedSubtitleCues(
        text: String,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        manuallyEdited: Bool
    ) -> [TranscriptSegment] {
        subtitleSegments(text: text, duration: duration, segments: segments, manuallyEdited: manuallyEdited)
            .flatMap(SubtitleTextLayout.cues)
    }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        timestamp(seconds, separator: ",")
    }

    private static func vttTime(_ seconds: TimeInterval) -> String {
        timestamp(seconds, separator: ".")
    }

    private static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = max(Int(seconds * 1_000), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1_000) % 60
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }
}

/// Keeps exported cues readable even when the source has no spaces or punctuation.
/// Widths are approximate display columns; playback applications choose the final font.
enum SubtitleTextLayout {
    static let columnsPerLine = 36
    static let linesPerCue = 2

    static func cues(for segment: TranscriptSegment) -> [TranscriptSegment] {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lines = wrappedLines(segment.text)
        let chunks = stride(from: 0, to: lines.count, by: linesPerCue).map { index in
            lines[index..<min(index + linesPerCue, lines.count)].joined(separator: "\n")
        }
        guard chunks.count > 1, segment.endTime > segment.startTime else {
            return [TranscriptSegment(id: segment.id, startTime: segment.startTime,
                                      endTime: segment.endTime, text: lines.joined(separator: "\n"))]
        }

        let weights = chunks.map { max($0.filter { !$0.isWhitespace }.count, 1) }
        let totalWeight = weights.reduce(0, +)
        var consumed = 0
        return chunks.enumerated().map { index, chunk in
            let start = segment.startTime + (segment.endTime - segment.startTime)
                * Double(consumed) / Double(totalWeight)
            consumed += weights[index]
            let end = index == chunks.count - 1 ? segment.endTime : segment.startTime
                + (segment.endTime - segment.startTime) * Double(consumed) / Double(totalWeight)
            return TranscriptSegment(id: index == 0 ? segment.id : UUID(),
                                     startTime: start, endTime: end, text: chunk)
        }
    }

    private static func wrappedLines(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        var width = 0
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            if character == "\n" {
                if !line.isEmpty { lines.append(line) }
                line = ""
                width = 0
                continue
            }
            let characterWidth = displayWidth(character)
            let isClosingPunctuation = "，。！？；：、,.!?;:)]}”’".contains(character)
            if width + characterWidth > columnsPerLine && !line.isEmpty
                && !(isClosingPunctuation && width <= columnsPerLine) {
                let characters = Array(line)
                let preferredBreak = characters.indices.last { index in
                    let prefixWidth = characters[...index].reduce(0) { $0 + displayWidth($1) }
                    return prefixWidth >= columnsPerLine / 2
                        && (characters[index].isWhitespace
                            || "，。！？；：、,.!?;:".contains(characters[index]))
                }
                if let preferredBreak {
                    lines.append(String(characters[...preferredBreak]))
                    line = String(characters.dropFirst(preferredBreak + 1))
                    width = line.reduce(0) { $0 + displayWidth($1) }
                } else {
                    lines.append(line)
                    line = ""
                    width = 0
                }
            }
            line.append(character)
            width += characterWidth
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func displayWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let value = scalar.value
        let wideScript = (0x1100...0x11FF).contains(value) || (0x3040...0x30FF).contains(value)
            || (0x3000...0x303F).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xFF01...0xFF60).contains(value)
        return scalar.properties.isIdeographic || scalar.properties.isEmojiPresentation || wideScript ? 2 : 1
    }
}

private enum PDFTranscriptRenderer {
    static func render(title: String, metadata: String, text: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &pageBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        body.append(NSAttributedString(
            string: metadata + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        body.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        ))

        let framesetter = CTFramesetterCreateWithAttributedString(body)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            context.saveGState()
            let frameRect = CGRect(x: 54, y: 54, width: pageBox.width - 108, height: pageBox.height - 108)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            location += visible.length
            context.restoreGState()
            context.endPDFPage()
        } while location < body.length

        context.closePDF()
        return data as Data
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let total = max(Int(self.rounded()), 0)
        let hours = total / 3_600
        let minutes = (total / 60) % 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

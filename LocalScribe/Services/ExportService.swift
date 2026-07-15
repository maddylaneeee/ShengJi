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
                translations: translations.isEmpty ? nil : translations
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
            let output = subtitleSegments(text: text, duration: duration, segments: segments, manuallyEdited: hasManualEdits)
                .enumerated()
                .map { index, segment in
                    "\(index + 1)\n\(srtTime(segment.startTime)) --> \(srtTime(segment.endTime))\n\(segment.text)"
                }
                .joined(separator: "\n\n")
            return Data((output + "\n").utf8)
        case .webVTT:
            let body = subtitleSegments(text: text, duration: duration, segments: segments, manuallyEdited: hasManualEdits)
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
        if manuallyEdited {
            return TranscriptSegment.sentenceSegments(from: text, duration: duration)
        }
        if segments.isEmpty {
            return TranscriptSegment.sentenceSegments(from: text, duration: duration)
        }
        return segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
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

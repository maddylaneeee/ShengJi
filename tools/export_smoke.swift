import Foundation

@main
struct ExportSmokeTest {
    static func main() throws {
        let text = "你好，这是声迹的导出测试。"
        let segments = [TranscriptSegment(startTime: 0, endTime: 2.5, text: text)]
        for format in TranscriptExportFormat.allCases {
            let data = try TranscriptExporter.makeData(
                format: format,
                title: "测试转录",
                source: "测试音频.aiff",
                language: "中文（中国大陆）",
                duration: 2.5,
                text: text,
                segments: segments,
                hasManualEdits: false
            )
            guard !data.isEmpty else {
                throw NSError(domain: "ExportSmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty \(format.rawValue) export"])
            }
            let destination = URL(fileURLWithPath: "/tmp/localscribe-export.\(format.fileExtension)")
            try data.write(to: destination)
            print("\(format.rawValue): \(data.count) bytes")
        }
    }
}

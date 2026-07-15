import AVFoundation
import Foundation
import Speech

@main
struct TranscriptionSmokeTest {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass an audio file path"])
        }

        let locale = Locale(identifier: "zh_CN")
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "SmokeTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "No compatible format"])
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let bridge = AnalyzerInputBridge()
        let resultTask = Task {
            var output = ""
            var finalResultCount = 0
            var lastFinalEndTime: TimeInterval = 0
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    output += text
                    finalResultCount += 1
                    lastFinalEndTime = max(
                        lastFinalEndTime,
                        CMTimeGetSeconds(result.range.start + result.range.duration)
                    )
                }
            }
            return (output, finalResultCount, lastFinalEndTime)
        }
        let analysisTask = Task {
            try await analyzer.analyzeSequence(bridge.stream)
        }

        let prepared = try await MediaAudioPreparer.prepare(URL(fileURLWithPath: CommandLine.arguments[1]))
        print("preparedTemporary=\(prepared.isTemporary)")
        try await AudioFileFeeder.feed(
            url: prepared.url,
            targetFormat: format,
            bridge: bridge,
            gate: PauseGate(),
            progress: { _ in }
        )
        _ = try await analysisTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, finalResultCount, lastFinalEndTime) = try await resultTask.value
        print("finalResults=\(finalResultCount)")
        print("lastFinalEndTime=\(lastFinalEndTime)")
        print(text)
        guard !text.isEmpty else {
            throw NSError(domain: "SmokeTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "No transcription produced"])
        }
    }
}

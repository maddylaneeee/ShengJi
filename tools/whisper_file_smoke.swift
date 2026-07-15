import AVFoundation
import Darwin
import Foundation

private final class TranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    func append(_ text: String) {
        lock.withLock {
            parts.append(text)
        }
    }

    var joined: String {
        lock.withLock {
            parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@main
struct WhisperFileSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            fputs("usage: whisper_file_smoke MODEL_PATH AUDIO_PATH [LANGUAGE]\n", stderr)
            Darwin.exit(64)
        }

        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let language = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "auto"

        let context = try WhisperModelContext(model: .tiny, modelURL: modelURL)
        let gate = PauseGate()
        let transcript = TranscriptCollector()
        try await WhisperFileProcessor.process(
            url: audioURL,
            context: context,
            languageCode: language,
            gate: gate,
            segmentHandler: { segments in
                for segment in segments {
                    transcript.append(segment.text)
                    print("[\(String(format: "%.2f", segment.startTime))-\(String(format: "%.2f", segment.endTime))] \(segment.text)")
                }
            },
            progressHandler: { progress, _ in
                if progress >= 1 { print("progress=1.0") }
            }
        )

        let joined = transcript.joined
        guard !joined.isEmpty else {
            fputs("no transcript returned\n", stderr)
            Darwin.exit(65)
        }
        print("transcript=\(joined)")
    }
}

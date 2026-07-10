import Foundation
import UniformTypeIdentifiers

enum WhisperTask: String, CaseIterable, Identifiable {
    case transcribe
    case translate

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case txt
    case srt
    case vtt
    case json
    case lrc
    case csv
    case words

    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: "Words"
        default: rawValue.uppercased()
        }
    }
    var cliFlag: String {
        switch self {
        case .txt: "-otxt"
        case .srt: "-osrt"
        case .vtt: "-ovtt"
        case .json: "-oj"
        case .lrc: "-olrc"
        case .csv: "-ocsv"
        case .words: "-owts"
        }
    }
}

struct DownloadableModel: Identifiable, Hashable {
    let name: String
    let fileName: String
    let size: String
    let url: URL

    var id: String { fileName }

    static let all: [DownloadableModel] = [
        .init(name: "Tiny", fileName: "ggml-tiny.bin", size: "75 MB", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!),
        .init(name: "Base", fileName: "ggml-base.bin", size: "142 MB", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!),
        .init(name: "Small", fileName: "ggml-small.bin", size: "466 MB", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!),
        .init(name: "Medium", fileName: "ggml-medium.bin", size: "1.5 GB", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!),
        .init(name: "Large v3 Turbo", fileName: "ggml-large-v3-turbo.bin", size: "1.6 GB", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!)
    ]

    static let vad: [DownloadableModel] = [
        .init(name: "Silero VAD 6.2.0", fileName: "ggml-silero-v6.2.0.bin", size: "865 KB", url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!)
    ]
}

struct RunRecord: Identifiable {
    let id = UUID()
    let inputName: String
    let outputBase: String
    let date: Date
    let succeeded: Bool
}

enum ModelLoadState: Equatable, Sendable {
    case notInstalled
    case waiting
    case loading
    case ready
    case failed(String)
    case unloaded

    var title: String {
        switch self {
        case .notInstalled: "No model"
        case .waiting: "Waiting"
        case .loading: "Loading"
        case .ready: "Ready"
        case .failed: "Failed"
        case .unloaded: "Unloaded"
        }
    }

    var detail: String {
        switch self {
        case .notInstalled: "Install or import a GGML model."
        case .waiting: "A model is selected and will be prepared."
        case .loading: "Preparing selected model for transcription."
        case .ready: "Selected model is available."
        case .failed(let message): message
        case .unloaded: "Previous model was released."
        }
    }
}

struct ModelLoadProgress: Sendable {
    var detail = ""
    var fraction = 0.0
}

enum RunPhase: String, Sendable {
    case idle = "Idle"
    case converting = "Converting"
    case transcribing = "Transcribing"
    case finished = "Finished"
}

struct RunProgress: Sendable {
    var currentFile: URL?
    var currentIndex = 0
    var totalFiles = 0
    var phase = RunPhase.idle

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return min(1, max(0, Double(currentIndex) / Double(totalFiles)))
    }
}

struct RunConfig {
    let inputFiles: [URL]
    let modelPath: URL
    let outputDirectory: URL
    let language: String
    let task: WhisperTask
    let outputFormats: [OutputFormat]
    let useMetal: Bool
    let printTimestamps: Bool
    let threads: Int
    let processors: Int
    let temperature: Double
    let prompt: String
    let maxLength: Int
    let maxContext: Int
    let bestOf: Int
    let beamSize: Int
    let noFallback: Bool
    let splitOnWord: Bool
    let wordThreshold: Double
    let entropyThreshold: Double
    let logprobThreshold: Double
    let noSpeechThreshold: Double
    let enableVAD: Bool
    let vadModelPath: URL?
    let vadThreshold: Double
    let vadMinSpeechMs: Int
    let vadMinSilenceMs: Int
    let vadSpeechPadMs: Int
    let diarize: Bool
    let cli: URL
}

struct DownloadProgressState {
    var title = ""
    var detail = ""
    var completed: Int64 = 0
    var total: Int64 = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum MediaTypes {
    static let supportedTypes: [UTType] = [
        .audio,
        .movie,
        .mpeg4Movie,
        .quickTimeMovie,
        .wav,
        .mp3,
        .mpeg4Audio,
        .aiff
    ]
}

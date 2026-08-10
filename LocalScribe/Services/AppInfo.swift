import Foundation

enum AppInfo {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "声迹"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "ca.lixinchen.localscribe"
    }

    static let updateManifestURL = URL(
        string: "https://github.com/maddylaneeee/ShengJi/releases/latest/download/update.json"
    )!

    static let documentationURL = URL(string: "https://lixinchen.ca/docs/localscribe/")!
    static let acceptanceURL = URL(string: "https://lixinchen.ca/docs/localscribe/acceptance.html")!
    static let sherpaBuildURL = URL(string: "https://lixinchen.ca/docs/localscribe/sherpa-onnx.html")!
    static let githubURL = URL(string: "https://github.com/maddylaneeee/ShengJi")!

    static var dependencies: [OpenSourceDependency] { [
        OpenSourceDependency(
            name: "Apple SpeechAnalyzer / SpeechTranscriber",
            role: L10n.text("Apple 本地语音识别与实时字幕"),
            license: "Apple platform SDK",
            url: URL(string: "https://developer.apple.com/documentation/speech")!
        ),
        OpenSourceDependency(
            name: "whisper.cpp / GGML",
            role: L10n.text("Whisper Metal 离线识别与 VAD 运行时"),
            license: "MIT",
            url: URL(string: "https://github.com/ggerganov/whisper.cpp")!
        ),
        OpenSourceDependency(
            name: "Silero VAD v6.2.0",
            role: L10n.text("Whisper 文件转录语音活动检测"),
            license: "MIT",
            url: URL(string: "https://huggingface.co/ggml-org/whisper-vad")!
        ),
        OpenSourceDependency(
            name: "sherpa-onnx",
            role: L10n.text("SenseVoice 与 NVIDIA Parakeet 文件识别运行时"),
            license: "Apache-2.0",
            url: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!
        ),
        OpenSourceDependency(
            name: "ONNX Runtime",
            role: L10n.text("sherpa-onnx 推理依赖"),
            license: "MIT",
            url: URL(string: "https://github.com/microsoft/onnxruntime")!
        ),
        OpenSourceDependency(
            name: "Apple Translation Framework",
            role: L10n.text("默认转录后翻译与系统语言包管理"),
            license: "Apple platform SDK",
            url: URL(string: "https://developer.apple.com/documentation/translation")!
        ),
        OpenSourceDependency(
            name: "NLLB / CTranslate2 / SentencePiece",
            role: L10n.text("可选转录后本机翻译后端"),
            license: "CC-BY-NC-4.0 / MIT / Apache-2.0",
            url: URL(string: "https://huggingface.co/osa911/nllb-200-distilled-600M-ct2-int8")!
        ),
        OpenSourceDependency(
            name: "Gemma 4 E2B / E4B IT",
            role: L10n.text("本机转录纠错、润色与总结模型"),
            license: "Apache-2.0",
            url: URL(string: "https://ai.google.dev/gemma")!
        ),
        OpenSourceDependency(
            name: "llama.cpp b10333",
            role: L10n.text("Gemma Metal 推理运行环境"),
            license: "MIT",
            url: URL(string: "https://github.com/ggml-org/llama.cpp")!
        )
    ] }
}

struct OpenSourceDependency: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let role: String
    let license: String
    let url: URL
}

import Foundation
import UniformTypeIdentifiers

enum RecognitionEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple
    case whisper
    case senseVoice
    case parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: L10n.text("Apple 本地识别")
        case .whisper: "Whisper · Metal"
        case .senseVoice: "SenseVoice"
        case .parakeet: "NVIDIA Parakeet"
        }
    }

    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .whisper: "cpu"
        case .senseVoice: "waveform.badge.magnifyingglass"
        case .parakeet: "bird"
        }
    }

    var supportsRealtimeMicrophone: Bool {
        switch self {
        case .apple, .whisper: true
        case .senseVoice, .parakeet: false
        }
    }

    var usesManagedModel: Bool {
        switch self {
        case .apple: false
        case .whisper, .senseVoice, .parakeet: true
        }
    }
}

enum ComputeBackendPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case coreMLANEPreferred
    case metal
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: L10n.text("自动")
        case .coreMLANEPreferred: L10n.text("Core ML（优先 ANE）")
        case .metal: "Metal GPU"
        case .cpu: "CPU"
        }
    }
}

enum ComputeBackend: String, Codable, Sendable {
    case appleManaged
    case coreMLANEPreferred
    case coreMLSystemSelected
    case metal
    case cpu
}

struct ComputeBackendStatus: Codable, Hashable, Sendable {
    var requested: ComputeBackendPreference
    var resolved: ComputeBackend
    var aneEligible: Bool
    var detail: String
    var fallbackReason: String?

    static func appleManaged(requested: ComputeBackendPreference = .automatic) -> Self {
        Self(
            requested: requested,
            resolved: .appleManaged,
            aneEligible: true,
            detail: L10n.text("Apple 管理（具体计算单元由系统决定）"),
            fallbackReason: nil
        )
    }
}

enum WhisperModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiny
    case base
    case small
    case medium
    case largeV3TurboQ5
    case largeV3Turbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: "Tiny"
        case .base: "Base"
        case .small: "Small"
        case .medium: "Medium"
        case .largeV3TurboQ5: "Large v3 Turbo · Q5"
        case .largeV3Turbo: "Large v3 Turbo"
        }
    }

    var detail: String {
        switch self {
        case .tiny: L10n.text("最快，适合快速草稿")
        case .base: L10n.text("轻量，准确度略高")
        case .small: L10n.text("速度与准确度均衡")
        case .medium: L10n.text("高准确度，内存占用较高")
        case .largeV3TurboQ5: L10n.text("推荐；接近完整精度，体积更小")
        case .largeV3Turbo: L10n.text("完整精度，最佳质量")
        }
    }

    var fileName: String {
        switch self {
        case .largeV3TurboQ5: "ggml-large-v3-turbo-q5_0.bin"
        case .largeV3Turbo: "ggml-large-v3-turbo.bin"
        default: "ggml-\(rawValue).bin"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var expectedByteCount: Int64 {
        switch self {
        case .tiny: 77_691_713
        case .base: 147_951_465
        case .small: 487_601_967
        case .medium: 1_533_763_059
        case .largeV3TurboQ5: 574_041_195
        case .largeV3Turbo: 1_624_555_275
        }
    }

    var expectedSHA1: String {
        switch self {
        case .tiny: "bd577a113a864445d4c299885e0cb97d4ba92b5f"
        case .base: "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        case .small: "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        case .medium: "fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        case .largeV3TurboQ5: "e050f7970618a659205450ad97eb95a18d69c9ee"
        case .largeV3Turbo: "4af2b29d7ec73d781377bfd1758ca957a807e941"
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
    }
}

enum SenseVoiceModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case int8_2025
    case int8_2024
    case full_2025
    case full_2024

    var id: String { rawValue }

    var title: String {
        switch self {
        case .int8_2025: "SenseVoice Small · INT8 · 2025"
        case .int8_2024: "SenseVoice Small · INT8 · 2024"
        case .full_2025: "SenseVoice Small · FP32 · 2025"
        case .full_2024: "SenseVoice Small · FP32 · 2024"
        }
    }

    var detail: String {
        switch self {
        case .int8_2025: L10n.text("推荐；中英日韩粤，多语种，体积小")
        case .int8_2024: L10n.text("兼容旧版导出，体积小")
        case .full_2025: L10n.text("完整精度，多语种，体积较大")
        case .full_2024: L10n.text("旧版完整精度，多语种，体积较大")
        }
    }

    var archiveName: String {
        switch self {
        case .int8_2025: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
        case .int8_2024: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
        case .full_2025: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2"
        case .full_2024: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
        }
    }

    var extractedDirectoryName: String {
        archiveName.replacingOccurrences(of: ".tar.bz2", with: "")
    }

    var downloadURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(archiveName)")!
    }

    var expectedByteCount: Int64 {
        switch self {
        case .int8_2025: 165_783_878
        case .int8_2024: 163_002_883
        case .full_2025: 886_547_748
        case .full_2024: 1_047_870_769
        }
    }

    var modelFileName: String {
        switch self {
        case .int8_2025, .int8_2024: "model.int8.onnx"
        case .full_2025, .full_2024: "model.onnx"
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
    }
}

enum ParakeetModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case transducer110mInt8
    case tdt06bV3Int8
    case tdt06bV2Int8
    case unified06bInt8

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transducer110mInt8: "Parakeet TDT Transducer · 110M · INT8"
        case .tdt06bV3Int8: "Parakeet TDT · 0.6B v3 · INT8"
        case .tdt06bV2Int8: "Parakeet TDT · 0.6B v2 · INT8"
        case .unified06bInt8: "Parakeet Unified · 0.6B · INT8"
        }
    }

    var detail: String {
        switch self {
        case .transducer110mInt8: L10n.text("轻量英文模型，适合快速本地转录")
        case .tdt06bV3Int8: L10n.text("推荐；0.6B 英文模型，质量较高")
        case .tdt06bV2Int8: L10n.text("0.6B v2 英文模型")
        case .unified06bInt8: L10n.text("0.6B unified non-streaming 英文模型")
        }
    }

    var archiveName: String {
        switch self {
        case .transducer110mInt8: "sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8.tar.bz2"
        case .tdt06bV3Int8: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        case .tdt06bV2Int8: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
        case .unified06bInt8: "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming.tar.bz2"
        }
    }

    var extractedDirectoryName: String {
        archiveName.replacingOccurrences(of: ".tar.bz2", with: "")
    }

    var downloadURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(archiveName)")!
    }

    var expectedByteCount: Int64 {
        switch self {
        case .transducer110mInt8: 108_035_095
        case .tdt06bV3Int8: 487_170_055
        case .tdt06bV2Int8: 482_468_385
        case .unified06bInt8: 501_350_460
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedByteCount, countStyle: .file)
    }
}

enum ManagedSpeechModel: Hashable, Codable, Identifiable, Sendable {
    case whisper(WhisperModel)
    case senseVoice(SenseVoiceModel)
    case parakeet(ParakeetModel)

    static var allModels: [ManagedSpeechModel] {
        WhisperModel.allCases.map(ManagedSpeechModel.whisper)
            + SenseVoiceModel.allCases.map(ManagedSpeechModel.senseVoice)
            + ParakeetModel.allCases.map(ManagedSpeechModel.parakeet)
    }

    static func find(_ id: String) -> ManagedSpeechModel? {
        let normalizedID = id.lowercased()
        return allModels.first {
            $0.id.lowercased() == normalizedID || $0.shortID.lowercased() == normalizedID
        }
    }

    var id: String {
        switch self {
        case .whisper(let model): "whisper.\(model.rawValue)"
        case .senseVoice(let model): "sensevoice.\(model.rawValue)"
        case .parakeet(let model): "parakeet.\(model.rawValue)"
        }
    }

    var shortID: String {
        switch self {
        case .whisper(let model): model.rawValue
        case .senseVoice(let model): model.rawValue
        case .parakeet(let model): model.rawValue
        }
    }

    var engine: RecognitionEngine {
        switch self {
        case .whisper: .whisper
        case .senseVoice: .senseVoice
        case .parakeet: .parakeet
        }
    }

    var title: String {
        switch self {
        case .whisper(let model): model.title
        case .senseVoice(let model): model.title
        case .parakeet(let model): model.title
        }
    }

    var detail: String {
        switch self {
        case .whisper(let model): model.detail
        case .senseVoice(let model): model.detail
        case .parakeet(let model): model.detail
        }
    }

    var sizeLabel: String {
        switch self {
        case .whisper(let model): model.sizeLabel
        case .senseVoice(let model): model.sizeLabel
        case .parakeet(let model): model.sizeLabel
        }
    }

    var expectedByteCount: Int64 {
        switch self {
        case .whisper(let model): model.expectedByteCount
        case .senseVoice(let model): model.expectedByteCount
        case .parakeet(let model): model.expectedByteCount
        }
    }

    var expectedSHA1: String? {
        switch self {
        case .whisper(let model): model.expectedSHA1
        case .senseVoice, .parakeet: nil
        }
    }

    var downloadURL: URL {
        switch self {
        case .whisper(let model): model.downloadURL
        case .senseVoice(let model): model.downloadURL
        case .parakeet(let model): model.downloadURL
        }
    }

    var isArchive: Bool {
        switch self {
        case .whisper: false
        case .senseVoice, .parakeet: true
        }
    }

    var archiveName: String? {
        switch self {
        case .whisper: nil
        case .senseVoice(let model): model.archiveName
        case .parakeet(let model): model.archiveName
        }
    }

    var extractedDirectoryName: String? {
        switch self {
        case .whisper: nil
        case .senseVoice(let model): model.extractedDirectoryName
        case .parakeet(let model): model.extractedDirectoryName
        }
    }
}

struct RecognitionConfiguration: Codable, Hashable, Sendable {
    var engine: RecognitionEngine
    var whisperModel: WhisperModel?
    var senseVoiceModel: SenseVoiceModel?
    var parakeetModel: ParakeetModel?
    var computeBackend: ComputeBackendPreference

    private enum CodingKeys: String, CodingKey {
        case engine
        case whisperModel
        case senseVoiceModel
        case parakeetModel
        case computeBackend
    }

    init(
        engine: RecognitionEngine,
        whisperModel: WhisperModel? = nil,
        senseVoiceModel: SenseVoiceModel? = nil,
        parakeetModel: ParakeetModel? = nil,
        computeBackend: ComputeBackendPreference = .automatic
    ) {
        self.engine = engine
        self.whisperModel = whisperModel
        self.senseVoiceModel = senseVoiceModel
        self.parakeetModel = parakeetModel
        self.computeBackend = computeBackend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(RecognitionEngine.self, forKey: .engine)
        whisperModel = try container.decodeIfPresent(WhisperModel.self, forKey: .whisperModel)
        senseVoiceModel = try container.decodeIfPresent(SenseVoiceModel.self, forKey: .senseVoiceModel)
        parakeetModel = try container.decodeIfPresent(ParakeetModel.self, forKey: .parakeetModel)
        computeBackend = try container.decodeIfPresent(ComputeBackendPreference.self, forKey: .computeBackend) ?? .automatic
    }

    var displayName: String {
        switch engine {
        case .apple: L10n.text("Apple 本地识别")
        case .whisper: "Whisper · \(whisperModel?.title ?? L10n.text("未选择模型")) · Metal"
        case .senseVoice: "SenseVoice · \(senseVoiceModel?.title ?? L10n.text("未选择模型"))"
        case .parakeet: "NVIDIA Parakeet · \(parakeetModel?.title ?? L10n.text("未选择模型"))"
        }
    }

    var managedModel: ManagedSpeechModel? {
        switch engine {
        case .apple: nil
        case .whisper: whisperModel.map(ManagedSpeechModel.whisper)
        case .senseVoice: senseVoiceModel.map(ManagedSpeechModel.senseVoice)
        case .parakeet: parakeetModel.map(ManagedSpeechModel.parakeet)
        }
    }
}

enum SegmentTranslationState: String, Codable, Sendable {
    case translated
    case sourceLanguage
    case fallback
}

struct TranslationUnit: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceSegmentID: UUID
    let ordinal: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sourceText: String
    let boundaryAfter: Bool

    init(segment: TranscriptSegment, ordinal: Int, boundaryAfter: Bool = true) {
        id = segment.id
        sourceSegmentID = segment.id
        self.ordinal = ordinal
        startTime = segment.startTime
        endTime = segment.endTime
        sourceText = segment.text
        self.boundaryAfter = boundaryAfter
    }
}

struct SegmentTranslation: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceSegmentID: UUID
    let ordinal: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sourceText: String
    let translatedText: String
    let state: SegmentTranslationState
    let errorMessage: String?

    var displayText: String {
        switch state {
        case .translated, .sourceLanguage:
            translatedText
        case .fallback:
            L10n.format("【未翻译】%@", sourceText)
        }
    }

    var transcriptSegment: TranscriptSegment {
        TranscriptSegment(
            id: sourceSegmentID,
            startTime: startTime,
            endTime: endTime,
            text: displayText
        )
    }
}

enum TranscriptionSource: Equatable, Sendable {
    case microphone
    case file(URL)
    case recovered(String)

    var title: String {
        switch self {
        case .microphone: L10n.text("麦克风")
        case .file(let url): url.lastPathComponent
        case .recovered(let title): title
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .file: "waveform.badge.magnifyingglass"
        case .recovered: "clock.arrow.circlepath"
        }
    }
}

enum TranscriptionPhase: Equatable, Sendable {
    case preparing
    case loadingModel
    case preparingAudio
    case transcribing
    case paused
    case finishing
    case finished
    case failed(String)

    var label: String {
        switch self {
        case .preparing: L10n.text("准备开始")
        case .loadingModel: L10n.text("正在加载识别模型")
        case .preparingAudio: L10n.text("正在准备音频")
        case .transcribing: L10n.text("正在识别语音")
        case .paused: L10n.text("已暂停，可编辑")
        case .finishing: L10n.text("正在整理文字")
        case .finished: L10n.text("转录完成")
        case .failed: L10n.text("转录失败")
        }
    }

    var isActive: Bool {
        self == .preparing || self == .loadingModel || self == .preparingAudio || self == .transcribing || self == .finishing
    }
}

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    static func sentenceSegments(from text: String, duration: TimeInterval) -> [TranscriptSegment] {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else {
            return [TranscriptSegment(startTime: 0, endTime: max(duration, 1), text: text)]
        }

        let totalWeight = max(sentences.reduce(0) { $0 + $1.count }, 1)
        let totalDuration = max(duration, Double(sentences.count))
        var cursor: TimeInterval = 0
        return sentences.enumerated().map { index, sentence in
            let isLast = index == sentences.count - 1
            let share = Double(max(sentence.count, 1)) / Double(totalWeight)
            let segmentDuration = isLast ? max(totalDuration - cursor, 0.4) : max(totalDuration * share, 0.4)
            let end = min(totalDuration, cursor + segmentDuration)
            defer { cursor = end }
            return TranscriptSegment(startTime: cursor, endTime: max(end, cursor + 0.05), text: sentence)
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let terminators = Set<Character>(["。", "！", "？", ".", "!", "?", "\n"])
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            current.append(character)
            if terminators.contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current.removeAll()
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}

struct LanguageOption: Identifiable, Hashable, Sendable {
    let locale: Locale
    let isInstalled: Bool

    var id: String { locale.identifier }

    var displayName: String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }
}

enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt
    case markdown
    case json
    case pdf
    case srt
    case webVTT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: L10n.text("纯文本")
        case .markdown: "Markdown"
        case .json: "JSON"
        case .pdf: L10n.text("PDF 文档")
        case .srt: L10n.text("SRT 字幕")
        case .webVTT: L10n.text("WebVTT 字幕")
        }
    }

    var detail: String {
        switch self {
        case .txt: L10n.text("通用、轻量的纯文字")
        case .markdown: L10n.text("带标题和来源信息")
        case .json: L10n.text("结构化文字与时间轴")
        case .pdf: L10n.text("适合阅读和分享")
        case .srt: L10n.text("常见视频字幕格式")
        case .webVTT: L10n.text("网页与播放器字幕")
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .webVTT: "vtt"
        default: rawValue
        }
    }

    var contentType: UTType {
        switch self {
        case .txt: .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .json: .json
        case .pdf: .pdf
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .webVTT: UTType(filenameExtension: "vtt") ?? .plainText
        }
    }

    var symbol: String {
        switch self {
        case .txt: "doc.plaintext"
        case .markdown: "text.document"
        case .json: "curlybraces"
        case .pdf: "doc.richtext"
        case .srt, .webVTT: "captions.bubble"
        }
    }
}

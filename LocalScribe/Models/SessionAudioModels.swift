import AVFoundation
import CryptoKit
import Foundation

/// Release scope is fixed in code. Legacy preferences and preview environments cannot enable TTS.
enum SessionAudioFeatures {
    static let speechSynthesisEnabled = false
    static func permits(_ asset: SessionAudioAsset) -> Bool {
        asset.kind == .original || speechSynthesisEnabled
    }
}

enum AudioQualityProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case storage, quality, lossless
    var id: String { rawValue }
    var title: String {
        let key = switch self {
        case .storage: "存储优先"
        case .quality: "质量优先"
        case .lossless: "最高质量"
    }; return L10n.text(key)
    }
    func channels(for input: AVAudioChannelCount) -> AVAudioChannelCount {
        switch self { case .storage: 1; case .quality: min(input, 2); case .lossless: input }
    }
    func settings(sampleRate: Double, channels: AVAudioChannelCount, bitDepth: Int = 24) -> [String: Any] {
        var settings: [String: Any] = [AVFormatIDKey: self == .lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
                                     AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        if self == .lossless { settings[AVEncoderBitDepthHintKey] = bitDepth }
        else { settings[AVEncoderBitRateKey] = self == .storage ? 64_000 : (channels == 1 ? 96_000 : 256_000) }
        return settings
    }
}

enum TimelineProvenance: String, Codable, Sendable {
    case subtitles, recognition, json, estimated, edited
    var isReliable: Bool { self == .subtitles || self == .recognition || self == .json }
}

enum AudioTimeline {
    static func isReliable(text: String, segments: [TranscriptSegment], provenance: TimelineProvenance) -> Bool {
        guard provenance.isReliable, !segments.isEmpty,
              normalized(text) == normalized(segments.map(\.text).joined(separator: "\n")) else { return false }
        var previous = -Double.infinity
        for s in segments {
            guard s.startTime.isFinite, s.endTime.isFinite, s.startTime >= 0, s.endTime > s.startTime,
                  s.startTime >= previous, !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            previous = s.startTime
        }
        return true
    }
    private static func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    static func framePosition(time: Double, sampleRate: Double) throws -> Int64 {
        guard time.isFinite, time >= 0, sampleRate > 0, time * sampleRate < Double(Int64.max) else { throw SessionAudioError.invalidFormat }
        return Int64((time * sampleRate).rounded())
    }
}

struct SynthesisInputSnapshot: Sendable {
    let text: String
    let isTranslation: Bool
    let voiceIdentifier: String
    let quality: AudioQualityProfile
    let usesTimeline: Bool
    let segments: [TranscriptSegment]
    var fingerprint: String {
        var fields = [text, isTranslation ? "translation" : "original", voiceIdentifier, quality.rawValue, usesTimeline ? "timeline" : "continuous"]
        if usesTimeline { fields.append(contentsOf: segments.map { "\($0.startTime)|\($0.endTime)|\($0.text)" }) }
        // Length-prefix every field so punctuation in the text cannot alias another input.
        return Self.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct SessionAudioAsset: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case original, synthesis }
    let id: UUID
    let sessionID: UUID
    let relativePath: String
    let kind: Kind
    let quality: AudioQualityProfile
    let duration: Double
    let sampleRate: Double
    let channels: UInt32
    let frames: Int64
    let isPartial: Bool
    let fingerprint: String?
    let createdAt: Date
    var sourceSampleRate: Double? = nil
    var sourceChannels: UInt32? = nil
}

enum SessionAudioError: LocalizedError {
    case invalidFormat, invalidPath, noAudio, queueOverflow, formatChanged, synthesisUnavailable, synthesisTimedOut, silentOutput
    case encodingFailed(rate: Double, channels: UInt32, reason: String)
    var errorDescription: String? {
        if case .encodingFailed = self {
            return L10n.text("当前输入无法保存为此音质，请尝试其他音质档位。")
        }
        let key = switch self {
        case .invalidFormat: "无法编码这种音频格式。"
        case .invalidPath: "音频路径无效。"
        case .noAudio: "没有可读取的音频。"
        case .queueOverflow: "原始音频保存积压超限；转录继续。"
        case .formatChanged: "输入音频格式已改变；已保留此前音频。"
        case .synthesisUnavailable: "所选音色当前不可用。"
        case .synthesisTimedOut: "语音生成长时间没有输出，请重试或选择其他音色。"
        case .silentOutput: "所选音色没有生成有效声音。"
        case .encodingFailed: "无法编码这种音频格式。"
    }; return L10n.text(key)
    }
}

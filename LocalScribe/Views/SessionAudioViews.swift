import AppKit
import SwiftUI

struct SessionAudioPlayerView: View {
    @Bindable var audio: SpeechAudioModel
    let stale: Bool
    var body: some View {
        if let asset = audio.asset, SessionAudioFeatures.permits(asset) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = audio.player.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else {
                    HStack {
                        Button(audio.player.isPlaying ? "暂停播放" : "播放音频", systemImage: audio.player.isPlaying ? "pause.fill" : "play.fill") { audio.player.toggle() }
                            .disabled(audio.isGenerating)
                        Slider(value: Binding(get: { audio.player.position }, set: { audio.player.seek($0) }), in: 0...max(0.001, audio.player.duration))
                            .accessibilityLabel("音频进度")
                        Text("\(audio.player.position.formattedDuration) / \(audio.player.duration.formattedDuration)").font(.caption.monospacedDigit())
                        Picker("播放倍速", selection: Binding(get: { audio.player.rate }, set: { audio.player.rate = $0 })) {
                            Text("0.5×").tag(Float(0.5)); Text("1×").tag(Float(1)); Text("2×").tag(Float(2))
                        }.frame(width: 88)
                    }
                }
                if asset.isPartial { Label("不完整原音：仅保留了可恢复部分", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if stale { Label("音频与当前稿件/设置不一致", systemImage: "info.circle").foregroundStyle(.orange) }
                if asset.kind == .original { Text("这是原始录音；编辑或译文不会改变音频。").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
    }
}

struct SpeechSynthesisControls: View {
    @Bindable var audio: SpeechAudioModel
    let text: String
    var translation = false
    var segments: [TranscriptSegment] = []
    var canGenerate = true
    var independent = false
    @State private var language: SpeechTextLanguage = .uncertain
    @State private var detectedDigest = ""
    @Bindable private var preferences = SpeechSynthesisPreferences.shared
    private var input: SynthesisInputSnapshot { audio.input(text: text, translation: translation, segments: segments) }
    private var digest: String { SynthesisInputSnapshot.digest(text) }
    private var confirmed: Bool { audio.confirmedTextDigest == digest }
    private var permitted: Bool {
        detectedDigest == digest && language.permits(allowAll: preferences.allowAll, englishConfirmed: confirmed)
            && (!independent || SpeechVoiceCatalog.independentEntryAllowed(allowAll: preferences.allowAll, effectiveLanguage: SpeechVoiceCatalog.effectiveInterfaceLanguage, hasVoices: !audio.catalog.voices.isEmpty))
    }
    var body: some View {
        if SessionAudioFeatures.speechSynthesisEnabled { enabledBody }
    }
    private var enabledBody: some View {
        Section("文字转语音") {
            Picker("朗读音色", selection: $audio.voiceIdentifier) {
                if audio.catalog.voices.isEmpty { Text("没有符合设置的可用音色").tag("") }
                ForEach(audio.catalog.voices) { voice in Text(voice.title).tag(voice.id) }
            }.disabled(audio.isGenerating)
            Picker("音质", selection: $audio.quality) { ForEach(AudioQualityProfile.allCases) { Text($0.title).tag($0) } }.disabled(audio.isGenerating)
            if !independent {
                Toggle("按时间轴朗读", isOn: $audio.usesTimeline).disabled(segments.isEmpty || audio.isGenerating)
                if segments.isEmpty { Text("当前正文没有可靠时间轴。").font(.caption).foregroundStyle(.secondary) }
            }
            if language == .uncertain {
                Text("其他语言的生成效果可能不好").font(.caption).foregroundStyle(.orange)
            }
            if !preferences.allowAll {
                if case .other = language { Text("正文不是英语；可在设置中允许所有朗读功能。").font(.caption).foregroundStyle(.orange) }
                if language == .uncertain {
                    Toggle("主语言是英语", isOn: Binding(get: { confirmed }, set: { audio.confirmedTextDigest = $0 ? digest : nil }))
                        .disabled(audio.isGenerating || detectedDigest != digest)
                }
            } else if let code = language.languageCode,
                      let voice = audio.catalog.voices.first(where: { $0.id == audio.voiceIdentifier }),
                      Locale(identifier: voice.language).language.languageCode?.identifier != code {
                Text("音色与正文语言不匹配，生成效果可能不好。").font(.caption).foregroundStyle(.orange)
            }
            if audio.catalog.voices.isEmpty { Text("没有符合设置的可用音色").font(.caption).foregroundStyle(.orange) }
            if audio.isGenerating {
                ProgressView(value: audio.progress)
                Text(audio.progress >= 0.95 ? "正在保存音频…" : "正在生成语音…").font(.caption)
                Button("取消生成") { audio.cancel() }
            } else {
                Button("开始生成音频", systemImage: "waveform") { audio.generate(input) }
                    .disabled(!canGenerate || !permitted || audio.voiceIdentifier.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = audio.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: digest) {
            let current = digest; let snapshot = text
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await Task.detached { SpeechTextLanguage.detect(snapshot) }.value
            guard !Task.isCancelled else { return }
            language = result; detectedDigest = current
            audio.detectedLanguage = result; audio.detectedTextDigest = current
            if segments.isEmpty { audio.usesTimeline = false }
        }
        .onAppear { audio.usesTimeline = false; audio.refresh() }
        .onChange(of: preferences.allowAll) { _, _ in audio.refresh() }
        .onChange(of: audio.voiceIdentifier) { _, id in if !id.isEmpty { preferences.lastVoiceIdentifier = id } }
        .onChange(of: segments.isEmpty) { _, empty in if empty { audio.usesTimeline = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in audio.refresh() }
    }
}

struct CompanionExportSheet: View {
    let asset: SessionAudioAsset?
    let defaultName: String
    var hasTranslation = false
    var approximateTimeline = false
    let warning: (TranscriptExportFormat, Bool) -> String
    let makeData: (TranscriptExportFormat, String, Bool) throws -> Data
    let onSuccess: () -> Void
    let close: () -> Void
    @State private var name = ""
    @State private var format: TranscriptExportFormat = .txt
    @State private var includeAudio = true
    @State private var useTranslation = false
    @State private var exporting = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出文字稿").font(.title2.weight(.semibold))
            TextField("文件名", text: $name)
            Picker("格式", selection: $format) { ForEach(TranscriptExportFormat.allCases) { Text($0.title).tag($0) } }
            if hasTranslation { Toggle("导出译文", isOn: $useTranslation) }
            Toggle("同时导出音频", isOn: $includeAudio).disabled(asset == nil)
            if asset == nil { Text("没有可附带的音频。").font(.caption).foregroundStyle(.secondary) }
            if approximateTimeline && (format == .srt || format == .webVTT) { Text("编辑后的文字会按句子重新生成近似时间戳").font(.caption).foregroundStyle(.secondary) }
            if includeAudio, asset != nil, !warning(format, useTranslation).isEmpty { Text(warning(format, useTranslation)).font(.caption).foregroundStyle(.orange) }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("复制到剪贴板", systemImage: "doc.on.doc") {
                    if let data = try? makeData(.txt, name, useTranslation), let text = String(data: data, encoding: .utf8) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        message = L10n.text("已复制")
                    }
                }
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                Button("选择保存位置…") {
                    exporting = true; message = nil
                    Task {
                        do {
                            let data = try makeData(format, name, useTranslation)
                            let result = try await CompanionExportCoordinator.export(data: data, format: format, name: name,
                                                                                     asset: includeAudio ? asset : nil, warning: warning(format, useTranslation))
                            if let result {
                                if let error = result.audioError {
                                    message = L10n.format("文字稿已保存到 %@；音频失败：%@。可重试，或取消附带后只保留文字。", result.textURL.path, error)
                                } else { onSuccess(); close() }
                            }
                        } catch { message = error.localizedDescription }
                        exporting = false
                    }
                }.keyboardShortcut(.defaultAction).primaryActionStyle()
            }
        }.padding(24).frame(width: 540).disabled(exporting)
        .onAppear { name = defaultName; includeAudio = asset != nil }
    }
}

extension SpeechAudioModel {
    func exportWarning(input: SynthesisInputSnapshot, format: TranscriptExportFormat) -> String {
        var warnings: [String] = []
        if isStale(input) { warnings.append(L10n.text("音频与当前稿件/设置不一致")) }
        if asset?.isPartial == true { warnings.append(L10n.text("不完整原音：仅保留了可恢复部分")) }
        if asset?.kind == .original { warnings.append(L10n.text("这是原始录音；编辑或译文不会改变音频。")) }
        if asset?.kind == .synthesis && (format == .srt || format == .webVTT) { warnings.append(L10n.text("生成音频可能与字幕时间不一致")) }
        return warnings.joined(separator: "\n")
    }
}

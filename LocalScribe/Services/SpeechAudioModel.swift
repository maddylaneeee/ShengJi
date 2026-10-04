import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class SpeechAudioModel {
    let sessionID: UUID
    private(set) var asset: SessionAudioAsset?
    var error: String?
    var isGenerating = false
    var progress = 0.0
    var voiceIdentifier = ""
    var quality: AudioQualityProfile = .quality
    var usesTimeline = false
    var confirmedTextDigest: String?
    var detectedLanguage: SpeechTextLanguage = .uncertain
    var detectedTextDigest = ""
    let catalog: SpeechVoiceCatalog
    private let preferences: SpeechSynthesisPreferences
    let player = SessionAudioPlayer()
    private let service: any SpeechSynthesizing
    private var task: Task<Void, Never>?
    private let onAsset: () -> Void
    init(sessionID: UUID, service: (any SpeechSynthesizing)? = nil, catalog: SpeechVoiceCatalog? = nil, preferences: SpeechSynthesisPreferences? = nil, onAsset: @escaping () -> Void = {}) {
        self.service = service ?? SpeechSynthesisService()
        self.catalog = catalog ?? SpeechVoiceCatalog()
        self.preferences = preferences ?? .shared
        self.sessionID = sessionID; self.onAsset = onAsset
        SpeechAudioRegistry.shared.register(self)
        refresh()
    }
    func refresh() {
        guard SessionAudioFeatures.speechSynthesisEnabled else { catalog.voices = []; voiceIdentifier = ""; return }
        catalog.refresh(allowAll: preferences.allowAll)
        guard !catalog.voices.contains(where: { $0.id == voiceIdentifier }) else { return }
        let previous = voiceIdentifier.isEmpty ? preferences.lastVoiceIdentifier : voiceIdentifier
        voiceIdentifier = catalog.voices.first(where: { $0.id == previous })?.id ?? catalog.voices.first?.id ?? ""
        if !previous.isEmpty, previous != voiceIdentifier { error = L10n.text("上次音色当前不可用，已更新音色选择。") }
    }
    func input(text: String, translation: Bool = false, segments: [TranscriptSegment] = []) -> SynthesisInputSnapshot {
        SynthesisInputSnapshot(text: text, isTranslation: translation, voiceIdentifier: voiceIdentifier, quality: quality, usesTimeline: usesTimeline, segments: segments)
    }
    func isStale(_ input: SynthesisInputSnapshot) -> Bool { asset?.kind == .synthesis && asset?.fingerprint != input.fingerprint }
    func generate(_ input: SynthesisInputSnapshot) {
        guard SessionAudioFeatures.speechSynthesisEnabled else { return }
        guard !isGenerating else { return }
        refresh()
        let language = SpeechTextLanguage.detect(input.text)
        guard language.permits(allowAll: preferences.allowAll, englishConfirmed: confirmedTextDigest == SynthesisInputSnapshot.digest(input.text)),
              catalog.voices.contains(where: { $0.id == input.voiceIdentifier }) else { error = L10n.text("请检查正文语言和音色选择。"); return }
        player.stop()
        error = nil; progress = 0; isGenerating = true
        task = Task { [self] in
            do {
                let newAsset = try await service.generate(input, sessionID: sessionID) { self.progress = $0 }
                do {
                    try Task.checkCancellation()
                    _ = try SessionAudioStore.readableURL(newAsset)
                    try SessionAudioStore.save(newAsset)
                } catch {
                    if let url = try? SessionAudioStore.resolve(sessionID: sessionID, relativePath: newAsset.relativePath) { try? FileManager.default.removeItem(at: url) }
                    throw error
                }
                asset = newAsset
                player.load(newAsset)
                onAsset()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            isGenerating = false
            task = nil
        }
    }
    func cancelAndWait() async {
        task?.cancel(); service.cancel()
        let running = task
        await running?.value
        player.stop()
    }
    func cancel() { task?.cancel(); service.cancel() }
    func restore(_ asset: SessionAudioAsset?) {
        guard let asset, SessionAudioFeatures.permits(asset) else {
            self.asset = nil; player.unload(); error = nil; return
        }
        do { _ = try SessionAudioStore.readableURL(asset); self.asset = asset; player.load(asset) }
        catch { self.error = L10n.text("内部音频缺失或损坏，稿件仍可使用。") }
    }
}

@MainActor final class SpeechAudioRegistry {
    static let shared = SpeechAudioRegistry()
    private class WeakModel { weak var value: SpeechAudioModel?; init(_ model: SpeechAudioModel) { value = model } }
    private var models: [WeakModel] = []
    func register(_ model: SpeechAudioModel) { models.removeAll { $0.value == nil }; models.append(WeakModel(model)) }
    func cancelAll() async { for model in models.compactMap(\.value) { await model.cancelAndWait() } }
}

@MainActor @Observable
final class SessionAudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var duration = 0.0
    var position = 0.0
    var rate: Float = 1 { didSet { player?.rate = rate } }
    var error: String?
    private var player: AVAudioPlayer?
    private var clockTask: Task<Void, Never>?
    private static weak var active: SessionAudioPlayer?
    func unload() {
        stop(); player = nil; duration = 0; position = 0; rate = 1; error = nil
    }
    func load(_ asset: SessionAudioAsset) {
        unload()
        guard SessionAudioFeatures.permits(asset) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: SessionAudioStore.readableURL(asset))
            player?.delegate = self; player?.enableRate = true
            duration = player?.duration ?? 0
        } catch { self.error = error.localizedDescription }
    }
    func toggle() {
        guard let player else { return }
        if isPlaying { stop(); return }
        Self.active?.stop(); Self.active = self
        if player.currentTime >= duration { player.currentTime = 0 }
        player.rate = rate
        guard player.play() else { error = L10n.text("无法播放音频。"); return }
        isPlaying = true
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let player = self.player else { return }
                self.position = player.currentTime
                self.isPlaying = player.isPlaying
                if !player.isPlaying { return }
            }
        }
    }
    func seek(_ time: Double) { position = min(max(0, time), duration); player?.currentTime = position }
    func stop() { player?.pause(); isPlaying = false; clockTask?.cancel(); clockTask = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop(); self?.position = self?.duration ?? 0 }
    }
}

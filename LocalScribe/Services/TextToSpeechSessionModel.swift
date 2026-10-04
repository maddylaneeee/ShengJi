import Foundation
import Observation

@MainActor @Observable
final class TextToSpeechSessionModel {
    let id: UUID
    var text = "" { didSet { scheduleSave() } }
    var isShowingInspector = true
    @ObservationIgnored private(set) lazy var audio = SpeechAudioModel(sessionID: id) { [weak self] in self?.scheduleSave(immediate: true) }
    private let writer = RecoverySnapshotWriter()
    private var saveTask: Task<Void, Never>?
    private var generation = 0
    private let createdAt: Date
    @ObservationIgnored private var audioLease: SessionAudioLease?
    init(snapshot: RecoverySnapshot? = nil) {
        id = snapshot?.id ?? UUID(); createdAt = snapshot?.createdAt ?? Date()
        text = snapshot?.transcriptText ?? ""
        audioLease = SessionAudioLease(id)
        TextToSpeechSessionRegistry.shared.register(self)
        audio.restore(snapshot?.audioAsset ?? SessionAudioStore.load(sessionID: id))
    }
    func scheduleSave(immediate: Bool = false) {
        guard SessionAudioFeatures.speechSynthesisEnabled else { return }
        generation += 1; let current = generation
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled, let self, self.generation == current else { return }
            await self.save()
        }
    }
    func save() async {
        guard SessionAudioFeatures.speechSynthesisEnabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audio.asset != nil else { return }
        let snapshot = RecoverySnapshot(id: id, schemaVersion: 3, isTextToSpeech: true, audioAsset: audio.asset, timelineProvenance: .estimated,
                                        sourceTitle: L10n.text("文字转语音"), sourceKind: .recovered, localeIdentifier: "en",
                                        configuration: RecognitionConfiguration(engine: .apple), transcriptText: text, segments: [],
                                        hasManualEdits: true, elapsed: max(Double(text.count) / 5, 1), progress: 1, createdAt: createdAt, updatedAt: Date())
        await writer.save(snapshot)
    }
    func close() async {
        await audio.cancelAndWait()
        saveTask?.cancel()
        await saveTask?.value
        await save()
        audioLease?.release()
    }
}

@MainActor final class TextToSpeechSessionRegistry {
    static let shared = TextToSpeechSessionRegistry()
    private class WeakModel { weak var value: TextToSpeechSessionModel?; init(_ model: TextToSpeechSessionModel) { value = model } }
    private var models: [WeakModel] = []
    func register(_ model: TextToSpeechSessionModel) { models.removeAll { $0.value == nil }; models.append(WeakModel(model)) }
    func saveAll() async { for model in models.compactMap(\.value) { await model.save() } }
}

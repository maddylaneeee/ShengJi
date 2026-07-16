import AVFoundation
import Foundation
import Observation
import Speech

@available(macOS 26.0, *)
@MainActor
private final class AppleSpeechSessionState {
    var analyzer: SpeechAnalyzer?
    var transcriber: SpeechTranscriber?
    var bridge: AnalyzerInputBridge?
}

@MainActor
@Observable
final class TranscriptionSessionModel {
    let source: TranscriptionSource
    var locale: Locale
    var configuration: RecognitionConfiguration
    private(set) var translationConfiguration: TranslationConfiguration?

    var phase: TranscriptionPhase = .preparing
    var transcriptText = ""
    private(set) var animatedTranscriptText = ""
    private(set) var translatedText = ""
    private(set) var translatedSegments: [TranscriptSegment] = []
    private(set) var segmentTranslations: [SegmentTranslation] = []
    private(set) var isTranslating = false
    private(set) var translationError: String?
    private(set) var computeBackendStatus: ComputeBackendStatus?
    var progress: Double = 0
    private(set) var progressIsIndeterminate = false
    private(set) var activityDetail = L10n.text("选择设置后开始转录")
    var audioLevel: Double = 0
    var elapsed: TimeInterval = 0
    var isShowingInspector = true
    var hasManualEdits = false
    private(set) var isImportedTranscript = false

    private(set) var segments: [TranscriptSegment] = []
    private var pendingFinalSegments: [TranscriptSegment] = []
    private var volatileSegment: TranscriptSegment?
    private var deferredSegments: [TranscriptSegment] = []
    private var whisperPreviewSegments: [TranscriptSegment] = []
    private var whisperPreviewFingerprints: Set<String> = []
    private var committedText = ""
    private var stableGeneratedText = ""
    private var lastGeneratedText = ""
    private var segmentFingerprints: Set<String> = []

    @ObservationIgnored private var appleSpeechStorage: AnyObject?
    private let pauseGate = PauseGate()
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var feederTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var whisperContext: WhisperModelContext?
    private var whisperLiveBuffer: WhisperLiveSampleBuffer?
    private var whisperTask: Task<Void, Never>?
    private var sherpaTask: Task<Void, Never>?
    private var sherpaFinishedWhilePaused = false

    private var audioEngine: AVAudioEngine?
    private var microphoneConverter: AVAudioConverter?
    private var microphoneFormat: AVAudioFormat?
    private var hasMicrophoneTap = false
    private var temporaryAudioURL: URL?
    private var isUsingSecurityScopedResource = false
    private var sourceDuration: TimeInterval = 0
    private var recognitionTimelineOffset: TimeInterval = 0
    private var startedAt: ContinuousClock.Instant?
    private var elapsedBeforeCurrentRun: Duration = .zero
    private var recoveryID = UUID()
    private var recoveryCreatedAt = Date()
    private var recoverySaveTask: Task<Void, Never>?
    private var recoverySaveGeneration = 0
    private let recoveryWriter = RecoverySnapshotWriter()
    private var translationTask: Task<Void, Never>?
    private var transcriptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private lazy var streamingTextAnimator = AdaptiveStreamingTextAnimator { [weak self] text in
        self?.animatedTranscriptText = text
    }
    @ObservationIgnored private let audioLevelLimiter = EventRateLimiter()
    @ObservationIgnored private lazy var transcriptRepository = TranscriptRepository(sessionID: recoveryID)

    @available(macOS 26.0, *)
    private var appleSpeechState: AppleSpeechSessionState {
        if let state = appleSpeechStorage as? AppleSpeechSessionState { return state }
        let state = AppleSpeechSessionState()
        appleSpeechStorage = state
        return state
    }

    @available(macOS 26.0, *)
    private var existingAppleSpeechState: AppleSpeechSessionState? {
        appleSpeechStorage as? AppleSpeechSessionState
    }

    var displaySegments: [TranscriptSegment] {
        var output = Array(segments.suffix(400))
        output.append(contentsOf: whisperPreviewSegments.suffix(max(0, 400 - output.count)))
        if let volatileSegment { output.append(volatileSegment) }
        return output
    }
    var displayTranslatedSegments: [TranscriptSegment] { Array(translatedSegments.suffix(400)) }
    var usesAnimatedStreamingDisplay: Bool {
        phase.isActive && (configuration.engine == .apple || configuration.engine == .whisper)
    }

    init(
        source: TranscriptionSource,
        locale: Locale,
        configuration: RecognitionConfiguration,
        translationConfiguration: TranslationConfiguration? = nil
    ) {
        self.source = source
        self.locale = locale
        self.configuration = configuration
        self.translationConfiguration = translationConfiguration
    }

    init(snapshot: RecoverySnapshot) {
        self.source = .recovered(snapshot.sourceTitle)
        self.locale = Locale(identifier: snapshot.localeIdentifier)
        self.configuration = snapshot.configuration
        self.translationConfiguration = snapshot.translationConfiguration
        self.phase = .finished
        self.transcriptText = snapshot.transcriptText
        self.translatedText = snapshot.translatedText ?? ""
        self.translatedSegments = snapshot.translatedSegments ?? []
        self.segmentTranslations = snapshot.segmentTranslations ?? []
        self.progress = snapshot.progress
        self.elapsed = snapshot.elapsed
        self.hasManualEdits = snapshot.hasManualEdits
        self.segments = snapshot.segments
        self.committedText = snapshot.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stableGeneratedText = self.committedText
        self.lastGeneratedText = self.committedText
        self.segmentFingerprints = Set(snapshot.segments.map(Self.segmentFingerprint))
        self.animatedTranscriptText = snapshot.transcriptText
        self.recoveryID = snapshot.id
        self.recoveryCreatedAt = snapshot.createdAt
    }

    init(
        imported: ImportedTranscript,
        continueWithMicrophone: Bool,
        locale: Locale,
        configuration: RecognitionConfiguration
    ) {
        self.source = continueWithMicrophone ? .microphone : .recovered(imported.title)
        self.locale = locale
        self.configuration = configuration
        self.phase = continueWithMicrophone ? .preparing : .finished
        self.transcriptText = imported.text
        self.animatedTranscriptText = imported.text
        self.segments = imported.segments
        self.elapsed = imported.duration
        self.recognitionTimelineOffset = imported.duration
        self.elapsedBeforeCurrentRun = .seconds(imported.duration)
        self.committedText = imported.text
        self.stableGeneratedText = imported.text
        self.lastGeneratedText = imported.text
        self.segmentFingerprints = Set(imported.segments.map(Self.segmentFingerprint))
        self.hasManualEdits = false
        self.isImportedTranscript = !continueWithMicrophone
    }

    var languageName: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    var canPause: Bool { phase == .transcribing }
    var canResume: Bool { phase == .paused }
    var canStop: Bool { phase == .transcribing || phase == .paused }
    var canEdit: Bool { phase == .paused || phase == .finished || phase.failedMessage != nil }
    var canStart: Bool { phase == .preparing }

    func configure(
        locale: Locale,
        configuration: RecognitionConfiguration,
        translationConfiguration: TranslationConfiguration? = nil
    ) {
        guard canStart else { return }
        self.locale = locale
        self.configuration = configuration
        self.translationConfiguration = translationConfiguration
    }

    func start() async {
        guard phase == .preparing else { return }
        streamingTextAnimator.reset()
        switch configuration.engine {
        case .whisper:
            await startWhisper()
            return
        case .senseVoice, .parakeet:
            await startSherpaOnnx()
            return
        case .apple:
            computeBackendStatus = .appleManaged(requested: configuration.computeBackend)
            break
        }
        guard #available(macOS 26.0, *) else {
            fail(SessionError.requiresMacOS26)
            return
        }
        do {
            if case .file(let url) = source {
                isUsingSecurityScopedResource = url.startAccessingSecurityScopedResource()
            }

            let selectedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            guard let selectedLocale else {
                throw SessionError.unsupportedLanguage(languageName)
            }

            let transcriber = SpeechTranscriber(locale: selectedLocale, preset: .timeIndexedProgressiveTranscription)
            appleSpeechState.transcriber = transcriber
            try await installAssetsIfNeeded(for: transcriber)

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw SessionError.noCompatibleAudioFormat
            }

            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: .init(priority: .userInitiated, modelRetention: .processLifetime)
            )
            appleSpeechState.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)

            let bridge = AnalyzerInputBridge()
            appleSpeechState.bridge = bridge
            startResultCollection(transcriber)
            analysisTask = Task { [weak self, analyzer, bridge] in
                do {
                    _ = try await analyzer.analyzeSequence(bridge.stream)
                } catch is CancellationError {
                } catch {
                    self?.fail(error)
                }
            }

            switch source {
            case .microphone:
                try await startMicrophone(targetFormat: format)
            case .file(let url):
                try await startFile(url: url, targetFormat: format)
            case .recovered:
                phase = .finished
                return
            }

            phase = .transcribing
            if case .microphone = source { beginTimer() }
        } catch {
            fail(error)
        }
    }

    func pause() {
        guard canPause else { return }
        phase = .paused
        freezeTimer()
        switch source {
        case .microphone:
            stopMicrophoneCapture()
        case .file:
            Task { await pauseGate.pause() }
        case .recovered:
            break
        }
        saveRecoveryNow()
    }

    func resume() async {
        guard canResume else { return }
        commitEditsAndCurrentOutput()
        applyDeferredSegments()
        if configuration.engine == .senseVoice || configuration.engine == .parakeet {
            if sherpaFinishedWhilePaused {
                sherpaFinishedWhilePaused = false
                phase = .finishing
                finalizeTranscript()
                phase = .finished
                progress = 1
                saveRecoveryNow()
                cleanupResources()
            } else {
                phase = .transcribing
            }
            return
        }
        guard #available(macOS 26.0, *) else {
            fail(SessionError.requiresMacOS26)
            return
        }
        do {
            switch source {
            case .microphone:
                try restartMicrophoneCapture()
            case .file:
                await pauseGate.resume()
            case .recovered:
                break
            }
            phase = .transcribing
            if case .microphone = source { beginTimer() }
        } catch {
            fail(error)
        }
    }

    func stop() async {
        guard canStop else { return }
        if configuration.engine == .whisper {
            await stopWhisper()
            return
        }
        if configuration.engine == .senseVoice || configuration.engine == .parakeet {
            await stopSherpaOnnx()
            return
        }
        guard #available(macOS 26.0, *) else {
            cleanupResources()
            return
        }
        if phase == .paused {
            commitEditsAndCurrentOutput()
        }
        phase = .finishing
        freezeTimer()
        stopMicrophoneCapture()
        feederTask?.cancel()
        await pauseGate.resume()
        existingAppleSpeechState?.bridge?.finish()

        do {
            _ = await analysisTask?.result
            guard phase.failedMessage == nil else { return }
            try await finishAnalyzerResults()
            finalizeTranscript()
            phase = .finished
            progress = 1
            if case .file = source { elapsed = sourceDuration }
            cleanupResources()
        } catch {
            fail(error)
        }
    }

    func cancel() async {
        saveRecoveryNow()
        translationTask?.cancel()
        if configuration.engine == .whisper {
            stopMicrophoneCapture()
            whisperTask?.cancel()
            feederTask?.cancel()
            timerTask?.cancel()
            await whisperLiveBuffer?.finish()
            cleanupResources()
            return
        }
        if configuration.engine == .senseVoice || configuration.engine == .parakeet {
            sherpaTask?.cancel()
            timerTask?.cancel()
            cleanupResources()
            return
        }
        stopMicrophoneCapture()
        feederTask?.cancel()
        timerTask?.cancel()
        guard #available(macOS 26.0, *) else {
            cleanupResources()
            return
        }
        existingAppleSpeechState?.bridge?.finish()
        await existingAppleSpeechState?.analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultsTask?.cancel()
        cleanupResources()
    }

    func noteDirectEdit() {
        guard canEdit else { return }
        if transcriptText != lastGeneratedText {
            hasManualEdits = true
            translatedText = ""
            translatedSegments = []
            segmentTranslations = []
        }
        scheduleRecoverySave()
    }

    func translate(targetLanguage: TranslationTargetLanguage, provider: TranslationProvider = .apple) {
        translationTask?.cancel()
        translationConfiguration = TranslationConfiguration(provider: provider, targetLanguage: targetLanguage)
        translatedText = ""
        translatedSegments = []
        segmentTranslations = []
        translationError = nil
        if targetLanguage.isEquivalent(to: locale) {
            isTranslating = false
            translationTask = nil
            saveRecoveryNow()
            return
        }
        startConfiguredTranslationIfNeeded()
    }

    func clearTranslation(targetLanguage: TranslationTargetLanguage? = nil, provider: TranslationProvider? = nil) {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
        if let targetLanguage {
            translationConfiguration = TranslationConfiguration(
                provider: provider ?? translationConfiguration?.provider ?? .apple,
                targetLanguage: targetLanguage
            )
        }
        translatedText = ""
        translatedSegments = []
        segmentTranslations = []
        translationError = nil
        saveRecoveryNow()
    }

    func translateNow() {
        guard let translationConfiguration else { return }
        translate(targetLanguage: translationConfiguration.targetLanguage, provider: translationConfiguration.provider)
    }

    private func startConfiguredTranslationIfNeeded() {
        guard let translationConfiguration,
              !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              translatedText.isEmpty,
              !isTranslating else { return }
        isTranslating = true
        translationError = nil
        let sourceSegments = hasManualEdits || segments.isEmpty
            ? TranscriptSegment.sentenceSegments(from: transcriptText, duration: elapsed)
            : segments.sorted { $0.startTime < $1.startTime }
        let locale = self.locale
        translationTask = Task { [weak self] in
            let units = sourceSegments.enumerated().map { index, segment in
                TranslationUnit(segment: segment, ordinal: index)
            }
            let translations = await TranslationService.translate(
                units: units,
                sourceLocale: locale,
                configuration: translationConfiguration
            )
            guard !Task.isCancelled, let self,
                  self.translationConfiguration == translationConfiguration else {
                self?.isTranslating = false
                return
            }
            self.segmentTranslations = translations
            self.translatedSegments = translations.map(\.transcriptSegment)
            self.translatedText = translations.map(\.displayText).joined(separator: "\n")
            Task { await self.transcriptRepository.replaceTranslations(translations) }
            let failures = translations.filter { $0.state == .fallback }
            self.translationError = failures.isEmpty ? nil : L10n.format("有 %lld 个片段未能翻译，已保留原文并标记。", failures.count)
            self.isTranslating = false
            self.translationTask = nil
            self.saveRecoveryNow()
        }
    }

    @available(macOS 26.0, *)
    private func installAssetsIfNeeded(for module: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [module])
        guard status != .installed else { return }
        guard status != .unsupported else { throw SessionError.unsupportedLanguage(languageName) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    @available(macOS 26.0, *)
    private func startResultCollection(_ transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    self?.consume(result)
                }
            } catch is CancellationError {
            } catch {
                self?.fail(error)
            }
        }
    }

    @available(macOS 26.0, *)
    private func consume(_ result: SpeechTranscriber.Result) {
        let generated = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText: String
        if case .microphone = source {
            guard let filtered = MicrophoneTranscriptFilter.sanitizedStreamingText(generated) else {
                volatileSegment = nil
                refreshGeneratedText()
                return
            }
            rawText = filtered
        } else {
            rawText = generated
        }
        guard !rawText.isEmpty else { return }

        let start = max(CMTimeGetSeconds(result.range.start), 0) + recognitionTimelineOffset
        let duration = max(CMTimeGetSeconds(result.range.duration), 0.05)
        let segment = TranscriptSegment(startTime: start, endTime: start + duration, text: rawText)

        if phase == .paused {
            if result.isFinal { deferredSegments.append(segment) }
            return
        }

        if result.isFinal {
            transcriptRefreshTask?.cancel()
            transcriptRefreshTask = nil
            volatileSegment = nil
            if accept(segment) {
                segments.append(segment)
                pendingFinalSegments.append(segment)
                appendStableText(segment.text)
                Task { await transcriptRepository.appendSourceSegments([segment]) }
            }
            refreshGeneratedText()
        } else {
            volatileSegment = segment
            scheduleVolatileTranscriptRefresh()
        }
    }

    private func refreshGeneratedText() {
        var output = stableGeneratedText
        for preview in whisperPreviewSegments {
            let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !output.isEmpty { output.append("\n") }
            output.append(text)
        }
        if let volatile = volatileSegment?.text.trimmingCharacters(in: .whitespacesAndNewlines), !volatile.isEmpty {
            if !output.isEmpty { output.append("\n") }
            output.append(volatile)
        }
        // Set the generated baseline first so SwiftUI's subsequent binding change is
        // never mistaken for a user edit.
        lastGeneratedText = output
        transcriptText = output
        streamingTextAnimator.submit(output, animated: usesAnimatedStreamingDisplay)
        scheduleRecoverySave()
    }

    private func scheduleVolatileTranscriptRefresh() {
        guard transcriptRefreshTask == nil else { return }
        transcriptRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.transcriptRefreshTask = nil
            self.refreshGeneratedText()
        }
    }

    private func commitEditsAndCurrentOutput() {
        noteDirectEdit()
        committedText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        stableGeneratedText = committedText
        pendingFinalSegments.removeAll()
        volatileSegment = nil
        lastGeneratedText = committedText
        if hasManualEdits {
            let editedSegments = TranscriptSegment.sentenceSegments(from: committedText, duration: elapsed)
            Task { await transcriptRepository.replaceManualTranscript(text: committedText, segments: editedSegments) }
        }
        scheduleRecoverySave()
    }

    private func applyDeferredSegments() {
        guard !deferredSegments.isEmpty else { return }
        let queued = deferredSegments
        deferredSegments.removeAll()
        appendWhisperSegments(queued)
    }

    private func finalizeTranscript() {
        applyMicrophoneHallucinationFilter()
        streamingTextAnimator.flush()
        if transcriptText != lastGeneratedText {
            hasManualEdits = true
        }
        committedText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        stableGeneratedText = committedText
        volatileSegment = nil
        lastGeneratedText = committedText
        if hasManualEdits {
            let editedSegments = TranscriptSegment.sentenceSegments(from: committedText, duration: elapsed)
            Task { await transcriptRepository.replaceManualTranscript(text: committedText, segments: editedSegments) }
        }
        saveRecoveryNow()
        startConfiguredTranslationIfNeeded()
    }

    @available(macOS 26.0, *)
    private func startMicrophone(targetFormat: AVAudioFormat) async throws {
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else { throw SessionError.microphonePermissionDenied }

        let engine = AVAudioEngine()
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            throw SessionError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: targetFormat) else {
            throw SessionError.noCompatibleAudioFormat
        }

        audioEngine = engine
        microphoneConverter = converter
        microphoneFormat = naturalFormat
        try restartMicrophoneCapture()
    }

    private func restartMicrophoneCapture() throws {
        if configuration.engine == .whisper {
            try restartWhisperMicrophoneCapture()
            return
        }
        guard #available(macOS 26.0, *) else { throw SessionError.requiresMacOS26 }
        try restartAppleMicrophoneCapture()
    }

    @available(macOS 26.0, *)
    private func restartAppleMicrophoneCapture() throws {
        guard let engine = audioEngine,
              let naturalFormat = microphoneFormat,
              let converter = microphoneConverter,
              let bridge = existingAppleSpeechState?.bridge else { throw SessionError.noMicrophone }

        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }
        let levelLimiter = audioLevelLimiter
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { [weak self, bridge, levelLimiter] buffer, _ in
            do {
                let output = try AudioFileFeeder.convert(buffer, using: converter, to: converter.outputFormat)
                _ = bridge.yield(AnalyzerInput(buffer: output))
                if levelLimiter.shouldEmit(every: .milliseconds(80)) {
                    let level = Self.level(from: buffer)
                    Task { @MainActor [weak self] in self?.audioLevel = level }
                }
            } catch {
                Task { @MainActor [weak self] in self?.fail(error) }
            }
        }
        hasMicrophoneTap = true
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophoneCapture() {
        guard let engine = audioEngine else { return }
        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }
        engine.stop()
        audioLevel = 0
    }

    @available(macOS 26.0, *)
    private func startFile(url: URL, targetFormat: AVAudioFormat) async throws {
        let prepared = try await MediaAudioPreparer.prepare(url)
        if prepared.isTemporary { temporaryAudioURL = prepared.url }
        let mediaFile = try AVAudioFile(forReading: prepared.url)
        sourceDuration = Double(mediaFile.length) / mediaFile.processingFormat.sampleRate
        elapsed = 0
        guard let bridge = existingAppleSpeechState?.bridge else { throw SessionError.noCompatibleAudioFormat }
        let gate = pauseGate
        let owner = self
        let progressLimiter = EventRateLimiter()
        feederTask = Task.detached(priority: .userInitiated) { [owner, bridge, gate, progressLimiter] in
            do {
                try await AudioFileFeeder.feed(
                    url: prepared.url,
                    targetFormat: targetFormat,
                    bridge: bridge,
                    gate: gate
                ) { value in
                    guard value >= 1 || progressLimiter.shouldEmit(every: .milliseconds(125)) else { return }
                    Task { @MainActor in
                        owner.progress = value
                        owner.elapsed = owner.sourceDuration * value
                    }
                }
                await owner.finishAutomatically()
            } catch is CancellationError {
            } catch {
                await owner.fail(error)
            }
        }
    }

    private func startWhisper() async {
        do {
            guard let model = configuration.whisperModel else {
                throw WhisperEngineError.modelMissing(L10n.text("未选择"))
            }
            phase = .loadingModel
            progress = 0
            progressIsIndeterminate = true
            activityDetail = L10n.format("正在从磁盘载入 %@；内存占用上升属于正常现象", model.title)
            let modelURL = RecognitionPreferences.url(for: model)
            let computePreference = configuration.computeBackend
            let size = try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == model.expectedByteCount else {
                throw WhisperEngineError.modelMissing(model.title)
            }

            if case .file(let url) = source {
                isUsingSecurityScopedResource = url.startAccessingSecurityScopedResource()
            }

            let context = try await Task.detached(priority: .userInitiated) {
                try WhisperModelContext(
                    model: model,
                    modelURL: modelURL,
                    preference: computePreference
                )
            }.value
            whisperContext = context
            computeBackendStatus = context.backendStatus

            switch source {
            case .microphone:
                try await startWhisperMicrophone(context: context)
                phase = .transcribing
                progressIsIndeterminate = false
                activityDetail = L10n.text("模型已加载，正在等待麦克风语音")
                beginTimer()
            case .file(let url):
                phase = .preparingAudio
                activityDetail = L10n.text("模型已加载，正在读取并转换音频")
                try await startWhisperFile(url: url, context: context)
                phase = .transcribing
            case .recovered:
                phase = .finished
                progressIsIndeterminate = false
            }
        } catch {
            fail(error)
        }
    }

    private func startWhisperMicrophone(context: WhisperModelContext) async throws {
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else { throw SessionError.microphonePermissionDenied }

        let engine = AVAudioEngine()
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            throw SessionError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: WhisperAudio.format) else {
            throw WhisperEngineError.invalidAudio
        }
        WhisperAudio.configure(converter)

        let liveBuffer = WhisperLiveSampleBuffer()
        whisperLiveBuffer = liveBuffer
        audioEngine = engine
        microphoneConverter = converter
        microphoneFormat = naturalFormat
        try restartWhisperMicrophoneCapture()

        let owner = self
        let language = whisperLanguageCode
        let initialTimeOffset = recognitionTimelineOffset
        whisperTask = Task.detached(priority: .userInitiated) { [owner, context, liveBuffer] in
            var timeOffset = initialTimeOffset
            do {
                while !Task.isCancelled {
                    if var chunk = await liveBuffer.takeSpeechAwareChunk(
                        minimumCount: WhisperAudio.sampleRate * 3,
                        maximumCount: WhisperAudio.sampleRate * 12,
                        trailingSilenceCount: WhisperAudio.sampleRate * 55 / 100
                    ) {
                        if chunk.isEmpty { break }
                        WhisperAudio.preprocess(&chunk)
                        guard WhisperAudio.hasSpeechEnergy(chunk) else {
                            timeOffset += Double(chunk.count) / Double(WhisperAudio.sampleRate)
                            continue
                        }
                        let relative = try await context.transcribe(
                            samples: chunk,
                            languageCode: language,
                            preserveContext: true,
                            mode: .realtime
                        )
                        let adjusted = relative.map {
                            TranscriptSegment(
                                startTime: $0.startTime + timeOffset,
                                endTime: $0.endTime + timeOffset,
                                text: $0.text
                            )
                        }
                        await owner.receiveWhisperSegments(adjusted)
                        timeOffset += Double(chunk.count) / Double(WhisperAudio.sampleRate)
                    } else if await liveBuffer.isFinishedAndEmpty {
                        break
                    } else {
                        try await Task.sleep(for: .milliseconds(80))
                    }
                }
            } catch is CancellationError {
            } catch {
                await owner.fail(error)
            }
        }
    }

    private func restartWhisperMicrophoneCapture() throws {
        guard let engine = audioEngine,
              let naturalFormat = microphoneFormat,
              let converter = microphoneConverter,
              let liveBuffer = whisperLiveBuffer else {
            throw SessionError.noMicrophone
        }
        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }

        let levelLimiter = audioLevelLimiter
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: naturalFormat) { [weak self, liveBuffer, levelLimiter] buffer, _ in
            do {
                let samples = try WhisperAudio.convert(buffer, using: converter)
                Task { await liveBuffer.append(samples) }
                if levelLimiter.shouldEmit(every: .milliseconds(80)) {
                    let level = Self.level(from: buffer)
                    Task { @MainActor [weak self] in self?.audioLevel = level }
                }
            } catch {
                Task { @MainActor [weak self] in self?.fail(error) }
            }
        }
        hasMicrophoneTap = true
        engine.prepare()
        try engine.start()
    }

    private func startWhisperFile(url: URL, context: WhisperModelContext) async throws {
        let prepared = try await MediaAudioPreparer.prepare(url)
        if prepared.isTemporary { temporaryAudioURL = prepared.url }
        let file = try AVAudioFile(forReading: prepared.url)
        sourceDuration = Double(file.length) / file.processingFormat.sampleRate
        elapsed = 0

        let owner = self
        let gate = pauseGate
        let language = whisperLanguageCode
        let progressLimiter = EventRateLimiter()
        whisperTask = Task.detached(priority: .userInitiated) { [owner, context, gate, progressLimiter] in
            do {
                let finalSegments = try await WhisperFileProcessor.process(
                    url: prepared.url,
                    context: context,
                    languageCode: language,
                    gate: gate,
                    incrementalSegmentHandler: { segments in
                        Task { @MainActor in owner.receiveWhisperPreviewSegments(segments) }
                    },
                    stageHandler: { stage in
                        Task { @MainActor in owner.updateWhisperFileStage(stage) }
                    },
                    progressHandler: { progress, elapsed in
                        guard progress >= 1 || progressLimiter.shouldEmit(every: .milliseconds(125)) else { return }
                        Task { @MainActor in
                            owner.progress = progress
                            owner.elapsed = elapsed
                        }
                    }
                )
                await owner.finishWhisperFileAutomatically(finalSegments: finalSegments)
            } catch is CancellationError {
            } catch {
                await owner.fail(error)
            }
        }
    }

    private func startSherpaOnnx() async {
        do {
            guard case .file(let url) = source else {
                throw SherpaOnnxError.unsupportedSource
            }
            isUsingSecurityScopedResource = url.startAccessingSecurityScopedResource()
            phase = .transcribing
            progress = 0
            elapsed = 0
            sherpaFinishedWhilePaused = false

            let owner = self
            let configuration = self.configuration
            let locale = self.locale
            let progressLimiter = EventRateLimiter()
            sherpaTask = Task.detached(priority: .userInitiated) { [owner, configuration, locale, progressLimiter] in
                do {
                    let result = try await SherpaOnnxFileProcessor.process(
                        sourceURL: url,
                        configuration: configuration,
                        locale: locale,
                        progressHandler: { progress, elapsed in
                            guard progress >= 1 || progressLimiter.shouldEmit(every: .milliseconds(125)) else { return }
                            Task { @MainActor in
                                owner.progress = progress
                                owner.elapsed = elapsed
                                owner.sourceDuration = max(owner.sourceDuration, elapsed)
                            }
                        }
                    )
                    await owner.receiveSherpaResult(result)
                    await owner.finishSherpaAutomatically()
                } catch is CancellationError {
                } catch {
                    await owner.fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func stopSherpaOnnx() async {
        if phase == .paused { commitEditsAndCurrentOutput() }
        phase = .finishing
        sherpaTask?.cancel()
        _ = await sherpaTask?.result
        guard phase.failedMessage == nil else { return }
        applyDeferredSegments()
        finalizeTranscript()
        phase = .finished
        progress = 1
        saveRecoveryNow()
        cleanupResources()
    }

    private func receiveSherpaSegments(_ newSegments: [TranscriptSegment]) {
        guard !newSegments.isEmpty else { return }
        if phase == .paused {
            deferredSegments.append(contentsOf: newSegments)
            return
        }
        appendWhisperSegments(newSegments)
    }

    private func receiveSherpaResult(_ result: SherpaTranscriptionResult) {
        computeBackendStatus = result.backendStatus
        receiveSherpaSegments(result.segments)
    }

    private func finishSherpaAutomatically() {
        if phase == .paused {
            sherpaFinishedWhilePaused = true
            progress = 1
            saveRecoveryNow()
            return
        }
        guard phase == .transcribing else { return }
        phase = .finishing
        finalizeTranscript()
        phase = .finished
        progress = 1
        saveRecoveryNow()
        cleanupResources()
    }

    private func stopWhisper() async {
        if phase == .paused { commitEditsAndCurrentOutput() }
        phase = .finishing
        freezeTimer()
        stopMicrophoneCapture()
        await pauseGate.resume()

        switch source {
        case .microphone:
            await whisperLiveBuffer?.finish()
            _ = await whisperTask?.result
        case .file:
            whisperTask?.cancel()
            _ = await whisperTask?.result
        case .recovered:
            break
        }

        guard phase.failedMessage == nil else { return }
        applyDeferredSegments()
        finalizeTranscript()
        phase = .finished
        progress = 1
        if case .file = source { elapsed = sourceDuration }
        saveRecoveryNow()
        cleanupResources()
    }

    private func finishWhisperAutomatically() {
        guard phase == .transcribing else { return }
        phase = .finishing
        applyDeferredSegments()
        finalizeTranscript()
        phase = .finished
        progress = 1
        elapsed = sourceDuration
        saveRecoveryNow()
        cleanupResources()
    }

    private func finishWhisperFileAutomatically(finalSegments: [TranscriptSegment]) {
        guard phase == .transcribing || phase == .finishing else { return }
        phase = .finishing
        progressIsIndeterminate = true
        activityDetail = L10n.text("正在应用置信度与末尾静音过滤，并整理时间戳")
        whisperPreviewSegments.removeAll()
        whisperPreviewFingerprints.removeAll()
        refreshGeneratedText()
        appendWhisperSegments(finalSegments)
        applyDeferredSegments()
        finalizeTranscript()
        phase = .finished
        progress = 1
        progressIsIndeterminate = false
        activityDetail = finalSegments.isEmpty ? L10n.text("未检测到可转写的语音") : L10n.text("转录与幻觉过滤已完成")
        elapsed = sourceDuration
        saveRecoveryNow()
        cleanupResources()
    }

    private func receiveWhisperPreviewSegments(_ newSegments: [TranscriptSegment]) {
        guard phase == .transcribing, !newSegments.isEmpty else { return }
        for segment in newSegments {
            let fingerprint = Self.segmentFingerprint(segment)
            if whisperPreviewFingerprints.insert(fingerprint).inserted {
                whisperPreviewSegments.append(segment)
            }
        }
        activityDetail = L10n.format("Whisper 正在生成文字 · 已出现 %lld 个片段", whisperPreviewSegments.count)
        refreshGeneratedText()
    }

    private func updateWhisperFileStage(_ stage: WhisperFileProcessor.Stage) {
        switch stage {
        case .converting(let value):
            progressIsIndeterminate = false
            activityDetail = L10n.format("正在转换为 16 kHz 单声道音频 · %@", value.formatted(.percent.precision(.fractionLength(0))))
        case .inferring(let value):
            if let value {
                progressIsIndeterminate = false
                activityDetail = L10n.format("VAD 与 Whisper 正在识别 · %@", value.formatted(.percent.precision(.fractionLength(0))))
            } else {
                progressIsIndeterminate = true
                activityDetail = L10n.text("VAD 已启用，Whisper 正在分析整段音频；首批文字生成后会立即显示")
            }
        case .finalizing:
            phase = .finishing
            progressIsIndeterminate = true
            activityDetail = L10n.text("推理完成，正在过滤末尾幻觉并整理文字")
        }
    }

    private func receiveWhisperSegments(_ newSegments: [TranscriptSegment]) {
        let filteredSegments: [TranscriptSegment]
        if case .microphone = source {
            let sanitized: [TranscriptSegment] = newSegments.compactMap { segment -> TranscriptSegment? in
                guard let text = MicrophoneTranscriptFilter.sanitizedStreamingText(segment.text) else { return nil }
                return TranscriptSegment(id: segment.id, startTime: segment.startTime, endTime: segment.endTime, text: text)
            }
            filteredSegments = MicrophoneTranscriptFilter.removingConsecutiveDuplicates(
                from: sanitized,
                after: segments.last
            )
        } else {
            filteredSegments = newSegments
        }
        guard !filteredSegments.isEmpty else { return }
        if phase == .paused {
            deferredSegments.append(contentsOf: filteredSegments)
            return
        }
        appendWhisperSegments(filteredSegments)
    }

    private func appendWhisperSegments(_ newSegments: [TranscriptSegment]) {
        var accepted: [TranscriptSegment] = []
        for segment in newSegments where accept(segment) {
            segments.append(segment)
            pendingFinalSegments.append(segment)
            appendStableText(segment.text)
            accepted.append(segment)
        }
        if !accepted.isEmpty { Task { await transcriptRepository.appendSourceSegments(accepted) } }
        refreshGeneratedText()
    }

    private var whisperLanguageCode: String {
        locale.language.languageCode?.identifier ?? "auto"
    }

    @available(macOS 26.0, *)
    private func finishAutomatically() async {
        guard phase == .transcribing else { return }
        phase = .finishing
        freezeTimer()
        do {
            _ = await analysisTask?.result
            guard phase.failedMessage == nil else { return }
            try await finishAnalyzerResults()
            finalizeTranscript()
            phase = .finished
            progress = 1
            elapsed = sourceDuration
            saveRecoveryNow()
            cleanupResources()
        } catch {
            fail(error)
        }
    }

    private func beginTimer() {
        startedAt = .now
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let startedAt = self.startedAt else { continue }
                let total = self.elapsedBeforeCurrentRun + startedAt.duration(to: .now)
                self.elapsed = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
            }
        }
    }

    private func freezeTimer() {
        if let startedAt {
            elapsedBeforeCurrentRun += startedAt.duration(to: .now)
            let components = elapsedBeforeCurrentRun.components
            elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
        startedAt = nil
        timerTask?.cancel()
    }

    private func cleanupResources() {
        timerTask?.cancel()
        transcriptRefreshTask?.cancel()
        transcriptRefreshTask = nil
        streamingTextAnimator.cancel()
        stopMicrophoneCapture()
        if isUsingSecurityScopedResource, case .file(let url) = source {
            url.stopAccessingSecurityScopedResource()
            isUsingSecurityScopedResource = false
        }
        if let temporaryAudioURL {
            try? FileManager.default.removeItem(at: temporaryAudioURL)
            self.temporaryAudioURL = nil
        }
        whisperContext = nil
        whisperLiveBuffer = nil
        appleSpeechStorage = nil
        analysisTask = nil
        resultsTask = nil
        feederTask = nil
        sherpaTask = nil
        sherpaFinishedWhilePaused = false
    }

    @available(macOS 26.0, *)
    private func finishAnalyzerResults() async throws {
        do {
            try await existingAppleSpeechState?.analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // A sequence can already be finalized by the framework when its input ends.
            // Preserve a completed local result instead of presenting that state race as failure.
            guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error
            }
        }
        // `finalizeAndFinishThroughEndOfInput()` closes the transcriber's result
        // sequence only after all pending final results have been delivered. A fixed
        // delay followed by cancellation truncates long files because the result
        // consumer can still be draining a large backlog after audio input reaches
        // 100%. Await the sequence's natural completion instead.
        _ = await resultsTask?.result
        if let message = phase.failedMessage {
            throw SessionError.resultCollectionFailed(message)
        }
    }

    private func fail(_ error: Error) {
        guard phase.failedMessage == nil, phase != .finished else { return }
        freezeTimer()
        stopMicrophoneCapture()
        phase = .failed(error.localizedDescription)
        saveRecoveryNow()
        cleanupResources()
    }

    private func scheduleRecoverySave() {
        guard hasRecoverableContent else { return }
        recoverySaveGeneration += 1
        let generation = recoverySaveGeneration
        recoverySaveTask?.cancel()
        recoverySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  let self,
                  self.recoverySaveGeneration == generation else { return }
            let snapshot = self.makeRecoverySnapshot()
            await self.recoveryWriter.save(snapshot)
        }
    }

    private func saveRecoveryNow() {
        guard hasRecoverableContent else { return }
        recoverySaveGeneration += 1
        let snapshot = makeRecoverySnapshot()
        recoverySaveTask?.cancel()
        recoverySaveTask = Task { [recoveryWriter] in
            await recoveryWriter.save(snapshot)
        }
    }

    private var hasRecoverableContent: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !segments.isEmpty
    }

    private func makeRecoverySnapshot() -> RecoverySnapshot {
        let sourceKind: RecoverySnapshot.SourceKind = switch source {
        case .microphone: .microphone
        case .file: .file
        case .recovered: .recovered
        }
        return RecoverySnapshot(
            id: recoveryID,
            schemaVersion: 2,
            journalRelativePath: "Sessions/\(recoveryID.uuidString)/transcript.jsonl",
            journalRecordCount: segments.count,
            journalGeneration: recoverySaveGeneration,
            sourceTitle: source.title,
            sourceKind: sourceKind,
            localeIdentifier: locale.identifier,
            configuration: configuration,
            translationConfiguration: translationConfiguration,
            transcriptText: transcriptText,
            translatedText: translatedText.isEmpty ? nil : translatedText,
            translatedSegments: translatedSegments.isEmpty ? nil : translatedSegments,
            segmentTranslations: segmentTranslations.isEmpty ? nil : segmentTranslations,
            segments: segments,
            hasManualEdits: hasManualEdits,
            elapsed: elapsed,
            progress: progress,
            createdAt: recoveryCreatedAt,
            updatedAt: Date()
        )
    }

    private func approximatelyEqual(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        abs(lhs.startTime - rhs.startTime) < 0.02
            && abs(lhs.endTime - rhs.endTime) < 0.02
            && lhs.text == rhs.text
    }

    private func accept(_ segment: TranscriptSegment) -> Bool {
        segmentFingerprints.insert(Self.segmentFingerprint(segment)).inserted
    }

    private nonisolated static func segmentFingerprint(_ segment: TranscriptSegment) -> String {
        let start = Int((segment.startTime * 50).rounded())
        let end = Int((segment.endTime * 50).rounded())
        return "\(start):\(end):\(segment.text)"
    }

    private func appendStableText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !stableGeneratedText.isEmpty { stableGeneratedText.append("\n") }
        stableGeneratedText.append(cleaned)
    }

    private func applyMicrophoneHallucinationFilter() {
        guard case .microphone = source else { return }
        let filtered = MicrophoneTranscriptFilter.removingTerminalBoilerplate(from: segments)
        guard filtered != segments else { return }
        segments = filtered
        segmentFingerprints = Set(filtered.map(Self.segmentFingerprint))
        pendingFinalSegments = pendingFinalSegments.filter { segmentFingerprints.contains(Self.segmentFingerprint($0)) }
        stableGeneratedText = filtered.map(\.text).joined(separator: "\n")
        lastGeneratedText = stableGeneratedText
        transcriptText = stableGeneratedText
        streamingTextAnimator.submit(stableGeneratedText, animated: false)
        Task { await transcriptRepository.replaceManualTranscript(text: stableGeneratedText, segments: filtered) }
    }

    private nonisolated static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max(Double((decibels + 60) / 60), 0), 1)
    }
}

private enum SessionError: LocalizedError {
    case requiresMacOS26
    case unsupportedLanguage(String)
    case noCompatibleAudioFormat
    case microphonePermissionDenied
    case noMicrophone
    case resultCollectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26: L10n.text("Apple 本地识别需要 macOS 26；当前系统可使用 Whisper、SenseVoice 或 Parakeet。")
        case .unsupportedLanguage(let language): L10n.format("本机不支持 %@ 的离线识别。", language)
        case .noCompatibleAudioFormat: L10n.text("无法找到兼容的音频格式。")
        case .microphonePermissionDenied: L10n.text("未获得麦克风权限。请在系统设置的“隐私与安全性”中允许访问。")
        case .noMicrophone: L10n.text("没有找到可用的音频输入设备。")
        case .resultCollectionFailed(let message): message
        }
    }
}

private extension TranscriptionPhase {
    var failedMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

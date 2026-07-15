import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit
import Speech
import SwiftUI

enum LiveCaptionInputMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case microphone
    case systemAudio
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "麦克风"
        case .systemAudio: "Mac 声音"
        case .both: "麦克风 + Mac 声音"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .both: "waveform.and.mic"
        }
    }
}

typealias LiveCaptionTargetLanguage = TranslationTargetLanguage

private enum LiveCaptionSource: String, Sendable {
    case microphone
    case systemAudio

    var label: String {
        switch self {
        case .microphone: "麦克风"
        case .systemAudio: "Mac"
        }
    }
}

struct LiveCaptionLine: Identifiable, Equatable, Sendable {
    let id: UUID
    var source: String
    var text: String
    var translatedText: String?
    var isFinal: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        text: String,
        translatedText: String? = nil,
        isFinal: Bool,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.translatedText = translatedText
        self.isFinal = isFinal
        self.updatedAt = updatedAt
    }
}

enum LiveCaptionDisplayFormatter {
    static func normalized(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LiveCaptionSlidingWindow {
    /// Fifteen visible updates per second keeps motion readable on 60 Hz panels
    /// while avoiding a continuously animated 60 fps marquee and its ghosting.
    static let updateInterval = Duration.milliseconds(67)

    static func nextFrame(current: String, target: String) -> String {
        guard current != target else { return current }
        guard target.hasPrefix(current) else { return target }

        let pending = target.dropFirst(current.count)
        let step = min(6, max(1, Int(ceil(Double(pending.count) / 8.0))))
        return current + String(pending.prefix(step))
    }
}

private struct PendingLiveTranslation: Sendable {
    let lineID: UUID
    let text: String
    let targetLanguage: TranslationTargetLanguage
    let isFinal: Bool
    let revision: Int
}

@MainActor
@Observable
final class LiveCaptionController {
    var inputMode: LiveCaptionInputMode {
        didSet { UserDefaults.standard.set(inputMode.rawValue, forKey: Self.inputModeKey) }
    }

    var localeIdentifier: String {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: Self.localeIdentifierKey) }
    }

    var isTranslationEnabled: Bool {
        didSet { UserDefaults.standard.set(isTranslationEnabled, forKey: Self.translationEnabledKey) }
    }

    var targetLanguage: LiveCaptionTargetLanguage {
        didSet { UserDefaults.standard.set(targetLanguage.rawValue, forKey: Self.targetLanguageKey) }
    }

    var showsOriginalText: Bool {
        didSet { UserDefaults.standard.set(showsOriginalText, forKey: Self.showsOriginalTextKey) }
    }

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isPreparingTranslation = false
    private(set) var lines: [LiveCaptionLine] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private var pipelines: [any LiveCaptionPipeline] = []
    @ObservationIgnored private let panelPresenter = LiveCaptionPanelPresenter()
    @ObservationIgnored private var translationWorker: Task<Void, Never>?
    @ObservationIgnored private var translationDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTranslation: PendingLiveTranslation?
    @ObservationIgnored private var translationCache: [String: String] = [:]
    @ObservationIgnored private var translationRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var partialFirstSeenAt: [UUID: Date] = [:]
    @ObservationIgnored private var partialLastEnqueuedAt: [UUID: Date] = [:]
    @ObservationIgnored private var nextTranslationRevision = 0
    @ObservationIgnored private var sourceLocale: Locale = .current

    private static let inputModeKey = "LiveCaptionInputMode"
    private static let localeIdentifierKey = "LiveCaptionLocaleIdentifier"
    private static let translationEnabledKey = "LiveCaptionTranslationEnabled"
    private static let targetLanguageKey = "LiveCaptionTargetLanguage"
    private static let showsOriginalTextKey = "LiveCaptionShowsOriginalText"
    private static let liveTranslationFeatureEnabled = false

    init() {
        inputMode = UserDefaults.standard.string(forKey: Self.inputModeKey)
            .flatMap(LiveCaptionInputMode.init(rawValue:)) ?? .microphone
        localeIdentifier = UserDefaults.standard.string(forKey: Self.localeIdentifierKey) ?? Locale.current.identifier
        isTranslationEnabled = Self.liveTranslationFeatureEnabled
            ? (UserDefaults.standard.object(forKey: Self.translationEnabledKey) as? Bool ?? false)
            : false
        targetLanguage = UserDefaults.standard.string(forKey: Self.targetLanguageKey)
            .flatMap(LiveCaptionTargetLanguage.init(rawValue:)) ?? .english
        showsOriginalText = UserDefaults.standard.object(forKey: Self.showsOriginalTextKey) as? Bool ?? true
    }

    var statusText: String {
        if let errorMessage { return errorMessage }
        if isPreparingTranslation { return "正在准备 Apple Translation…" }
        if isPaused { return "实时字幕已暂停" }
        return isRunning
            ? "正在监听 \(inputMode.title)"
            : "以悬浮窗显示本地实时字幕"
    }

    var primaryText: String {
        if isLiveTranslationActive {
            return LiveCaptionDisplayFormatter.normalized(latestTranslatedText ?? "正在等待 Apple Translation…")
        }
        return LiveCaptionDisplayFormatter.normalized(latestOriginalText)
    }

    var secondaryText: String? {
        if isLiveTranslationActive, showsOriginalText {
            return LiveCaptionDisplayFormatter.normalized(latestOriginalText)
        }
        return nil
    }

    var secondaryTextLabel: String? {
        isLiveTranslationActive && showsOriginalText ? "原文" : nil
    }

    func toggle(locale: Locale) async {
        if isRunning {
            await stop()
        } else {
            await start(locale: locale)
        }
    }

    func start(locale: Locale) async {
        guard !isRunning else { return }
        normalizeTargetLanguageForLiveTranslation(sourceLocale: locale)
        errorMessage = nil
        lines = []
        translationCache.removeAll(keepingCapacity: true)
        translationRevisions.removeAll(keepingCapacity: true)
        partialFirstSeenAt.removeAll(keepingCapacity: true)
        partialLastEnqueuedAt.removeAll(keepingCapacity: true)
        nextTranslationRevision = 0
        isPaused = false
        sourceLocale = locale
        panelPresenter.show(controller: self)

        do {
            if isLiveTranslationActive {
                isPreparingTranslation = true
                try await AppleTranslationCoordinator.shared.prepare(
                    sourceLocale: locale,
                    targetLanguage: targetLanguage,
                    quality: .lowLatency
                )
                isPreparingTranslation = false
            }
            try await startPipelines(locale: locale)
            isRunning = true
        } catch {
            isPreparingTranslation = false
            fail(error)
        }
    }

    func prepareTranslationForStart(sourceLocale: Locale, preferredTargetLanguage: TranslationTargetLanguage) {
        guard isLiveTranslationActive else { return }
        if targetLanguage == .system, preferredTargetLanguage != .system {
            targetLanguage = preferredTargetLanguage
        }
        normalizeTargetLanguageForLiveTranslation(sourceLocale: sourceLocale)
    }

    func toggleOriginalTextDisplay() {
        showsOriginalText.toggle()
    }

    func stop() async {
        cancelPendingTranslation()
        let runningPipelines = pipelines
        pipelines = []
        for pipeline in runningPipelines {
            await pipeline.stop()
        }
        isRunning = false
        isPaused = false
        panelPresenter.close()
    }

    func pause() async {
        guard isRunning, !isPaused else { return }
        cancelPendingTranslation()
        let runningPipelines = pipelines
        pipelines = []
        for pipeline in runningPipelines {
            await pipeline.stop()
        }
        isPaused = true
    }

    func resume() async {
        guard isRunning, isPaused else { return }
        errorMessage = nil
        do {
            try await startPipelines(locale: sourceLocale)
            isPaused = false
        } catch {
            fail(error)
        }
    }

#if DEBUG
    func showDesignPreview() {
        lines = [
            LiveCaptionLine(
                source: "Mac",
                text: "实时字幕会保留模型连续输出并按从左到右的阅读顺序持续追加窗口会稳定跟随最新内容",
                translatedText: "Live captions appear here and update naturally with speech.",
                isFinal: true
            )
        ]
        isTranslationEnabled = true
        isRunning = true
        isPaused = false
        errorMessage = nil
        panelPresenter.show(controller: self)
    }
#endif

    private func startPipelines(locale: Locale) async throws {
        let sources: [LiveCaptionSource] = switch inputMode {
        case .microphone: [.microphone]
        case .systemAudio: [.systemAudio]
        case .both: [.systemAudio, .microphone]
        }
        pipelines = []
        do {
            for source in sources {
                let pipeline: any LiveCaptionPipeline
                if #available(macOS 26.0, *) {
                    pipeline = AppleLiveCaptionPipeline(source: source, locale: locale) { [weak self] source, text, isFinal in
                        self?.receiveCaption(source: source, text: text, isFinal: isFinal)
                    } onError: { [weak self] error in
                        self?.fail(error)
                    }
                } else {
                    throw LiveCaptionError.requiresMacOS26
                }
                try await pipeline.start()
                pipelines.append(pipeline)
            }
        } catch {
            let started = pipelines
            pipelines = []
            for pipeline in started { await pipeline.stop() }
            throw error
        }
    }

    private func receiveCaption(source: LiveCaptionSource, text: String, isFinal: Bool) {
        guard let cleaned = MicrophoneTranscriptFilter.sanitizedStreamingText(text) else {
            if let last = lines.indices.last, lines[last].source == source.label, !lines[last].isFinal {
                lines.remove(at: last)
            }
            return
        }

        let now = Date()
        let displayText = cleaned

        let lineID: UUID
        if let last = lines.indices.last, lines[last].source == source.label, !lines[last].isFinal {
            lines[last].text = displayText
            lines[last].isFinal = isFinal
            lines[last].updatedAt = now
            lineID = lines[last].id
        } else {
            let line = LiveCaptionLine(source: source.label, text: displayText, isFinal: isFinal, updatedAt: now)
            lines.append(line)
            lineID = line.id
        }

        if lines.count > 5 {
            let removed = lines.prefix(lines.count - 5).map(\.id)
            for id in removed {
                translationRevisions.removeValue(forKey: id)
                partialFirstSeenAt.removeValue(forKey: id)
                partialLastEnqueuedAt.removeValue(forKey: id)
            }
            lines.removeFirst(lines.count - 5)
        }
        scheduleTranslation(for: lineID, text: displayText, isFinal: isFinal)
    }

    private func scheduleTranslation(for lineID: UUID?, text: String, isFinal: Bool) {
        guard isLiveTranslationActive, let lineID else { return }
        nextTranslationRevision += 1
        let revision = nextTranslationRevision
        translationRevisions[lineID] = revision
        let requestTargetLanguage = effectiveTargetLanguage(for: sourceLocale)
        let request = PendingLiveTranslation(
            lineID: lineID,
            text: text,
            targetLanguage: requestTargetLanguage,
            isFinal: isFinal,
            revision: revision
        )
        translationDebounceTask?.cancel()
        if isFinal {
            partialFirstSeenAt.removeValue(forKey: lineID)
            partialLastEnqueuedAt.removeValue(forKey: lineID)
            enqueueTranslation(request)
        } else {
            let now = Date()
            let firstSeen = partialFirstSeenAt[lineID] ?? now
            partialFirstSeenAt[lineID] = firstSeen
            let age = now.timeIntervalSince(firstSeen)
            let lastEnqueued = partialLastEnqueuedAt[lineID] ?? .distantPast
            if age >= 0.9, now.timeIntervalSince(lastEnqueued) >= 0.75 {
                partialLastEnqueuedAt[lineID] = now
                enqueueTranslation(request)
                return
            }

            let delay = max(0.25, min(0.55, 0.9 - age))
            translationDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.partialLastEnqueuedAt[lineID] = Date()
                }
                self?.enqueueTranslation(request)
            }
        }
    }

    private func enqueueTranslation(_ request: PendingLiveTranslation) {
        guard translationRevisions[request.lineID] == request.revision else { return }
        if !request.isFinal, pendingTranslation?.isFinal == true { return }
        let cacheKey = liveTranslationCacheKey(request)
        if let cached = translationCache[cacheKey],
           let index = lines.firstIndex(where: { $0.id == request.lineID }),
           canApplyTranslationResult(request, to: lines[index]) {
            lines[index].translatedText = cached
            return
        }
        pendingTranslation = request
        guard translationWorker == nil else { return }
        translationWorker = Task { [weak self] in
            while !Task.isCancelled, let self {
                guard let request = self.pendingTranslation else { break }
                self.pendingTranslation = nil
                do {
                    guard let output = try await AppleTranslationCoordinator.shared.translate(
                        texts: [request.text],
                        sourceLocale: self.sourceLocale,
                        targetLanguage: request.targetLanguage,
                        quality: .lowLatency
                    ).first else { continue }
                    guard !Task.isCancelled,
                          let index = self.lines.firstIndex(where: { $0.id == request.lineID }),
                          self.canApplyTranslationResult(request, to: self.lines[index]) else { continue }
                    self.translationCache[self.liveTranslationCacheKey(request)] = output
                    if self.translationCache.count > 80 {
                        self.translationCache.removeAll(keepingCapacity: true)
                    }
                    self.lines[index].translatedText = output
                } catch is CancellationError {
                    break
                } catch {
                    if request.isFinal { self.errorMessage = error.localizedDescription }
                }
            }
            self?.translationWorker = nil
        }
    }

    private func cancelPendingTranslation() {
        translationDebounceTask?.cancel()
        translationDebounceTask = nil
        translationWorker?.cancel()
        translationWorker = nil
        pendingTranslation = nil
    }

    private func canApplyTranslationResult(_ request: PendingLiveTranslation, to line: LiveCaptionLine) -> Bool {
        if request.isFinal {
            return line.isFinal
                && line.text == request.text
                && translationRevisions[request.lineID] == request.revision
        }
        return !line.isFinal && !line.text.isEmpty
    }

    private func liveTranslationCacheKey(_ request: PendingLiveTranslation) -> String {
        "\(sourceLocale.identifier)|\(request.targetLanguage.rawValue)|\(request.text)"
    }

    private var latestOriginalText: String {
        lines.last?.text ?? "等待声音…"
    }

    private var latestTranslatedText: String? {
        lines.reversed().compactMap(\.translatedText).first
    }

    private func normalizeTargetLanguageForLiveTranslation(sourceLocale: Locale) {
        guard isLiveTranslationActive,
              sourceLocale.language.languageCode == targetLanguage.locale.language.languageCode else { return }
        targetLanguage = sourceLocale.language.languageCode == TranslationTargetLanguage.english.locale.language.languageCode
            ? .chineseSimplified
            : .english
    }

    private func effectiveTargetLanguage(for sourceLocale: Locale) -> TranslationTargetLanguage {
        guard targetLanguage.locale.language.languageCode == sourceLocale.language.languageCode else { return targetLanguage }
        let replacement: TranslationTargetLanguage = sourceLocale.language.languageCode == TranslationTargetLanguage.english.locale.language.languageCode
            ? .chineseSimplified
            : .english
        targetLanguage = replacement
        return replacement
    }

    private var isLiveTranslationActive: Bool {
        Self.liveTranslationFeatureEnabled && isTranslationEnabled
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        isRunning = false
        isPaused = false
        isPreparingTranslation = false
        cancelPendingTranslation()
        let runningPipelines = pipelines
        pipelines = []
        Task {
            for pipeline in runningPipelines {
                await pipeline.stop()
            }
        }
    }
}

private enum LiveCaptionError: LocalizedError {
    case unsupportedLanguage(String)
    case noCompatibleAudioFormat
    case microphonePermissionDenied
    case noMicrophone
    case noDisplay
    case invalidSystemAudio
    case requiresMacOS26

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language): "本机不支持 \(language) 的 Apple 本地实时字幕。"
        case .noCompatibleAudioFormat: "无法找到兼容的实时字幕音频格式。"
        case .microphonePermissionDenied: "未获得麦克风权限。请在系统设置中允许声迹访问麦克风。"
        case .noMicrophone: "没有找到可用麦克风。"
        case .noDisplay: "未找到可采集的显示器。"
        case .invalidSystemAudio: "无法读取 Mac 系统声音。"
        case .requiresMacOS26: "Apple 本地实时字幕需要 macOS 26。"
        }
    }
}

@MainActor
private protocol LiveCaptionPipeline: AnyObject {
    func start() async throws
    func stop() async
}

@MainActor
@available(macOS 26.0, *)
private final class AppleLiveCaptionPipeline: LiveCaptionPipeline {
    private let source: LiveCaptionSource
    private let locale: Locale
    private let onCaption: (LiveCaptionSource, String, Bool) -> Void
    private let onError: (Error) -> Void

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var bridge: AnalyzerInputBridge?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    private var audioEngine: AVAudioEngine?
    private var microphoneConverter: AVAudioConverter?
    private var microphoneFormat: AVAudioFormat?
    private var hasMicrophoneTap = false

    private var screenStream: SCStream?
    private var screenOutput: ScreenAudioOutput?
    private let screenQueue = DispatchQueue(label: "ca.lixinchen.localscribe.live-caption-screen-audio")

    init(
        source: LiveCaptionSource,
        locale: Locale,
        onCaption: @escaping (LiveCaptionSource, String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.source = source
        self.locale = locale
        self.onCaption = onCaption
        self.onError = onError
    }

    func start() async throws {
        let selectedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        guard let selectedLocale else {
            throw LiveCaptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: selectedLocale, preset: .timeIndexedProgressiveTranscription)
        self.transcriber = transcriber
        try await installAssetsIfNeeded(for: transcriber)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveCaptionError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        let bridge = AnalyzerInputBridge()
        self.bridge = bridge
        collectResults(from: transcriber)
        analysisTask = Task { [weak self, analyzer, bridge] in
            do {
                _ = try await analyzer.analyzeSequence(bridge.stream)
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.onError(error) }
            }
        }

        switch source {
        case .microphone:
            try await startMicrophone(targetFormat: format)
        case .systemAudio:
            try await startSystemAudio(targetFormat: format)
        }
    }

    func stop() async {
        stopMicrophone()
        bridge?.finish()
        if let screenStream {
            try? await screenStream.stopCapture()
        }
        screenStream = nil
        screenOutput = nil
        _ = await analysisTask?.result
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // The framework may already have finalized when the input stream ends.
        }
        _ = await resultsTask?.result
        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        bridge = nil
    }

    private func installAssetsIfNeeded(for module: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [module])
        guard status != .installed else { return }
        guard status != .unsupported else {
            throw LiveCaptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    let text = String(result.text.characters)
                    self?.onCaption(self?.source ?? .microphone, text, result.isFinal)
                }
            } catch is CancellationError {
            } catch {
                self?.onError(error)
            }
        }
    }

    private func startMicrophone(targetFormat: AVAudioFormat) async throws {
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else { throw LiveCaptionError.microphonePermissionDenied }

        let engine = AVAudioEngine()
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            throw LiveCaptionError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: targetFormat) else {
            throw LiveCaptionError.noCompatibleAudioFormat
        }
        audioEngine = engine
        microphoneConverter = converter
        microphoneFormat = naturalFormat

        guard let bridge else { throw LiveCaptionError.noMicrophone }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { [weak self, bridge, converter] buffer, _ in
            do {
                let output = try AudioFileFeeder.convert(buffer, using: converter, to: targetFormat)
                _ = bridge.yield(AnalyzerInput(buffer: output))
            } catch {
                Task { @MainActor [weak self] in self?.onError(error) }
            }
        }
        hasMicrophoneTap = true
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        guard let engine = audioEngine else { return }
        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }
        engine.stop()
        audioEngine = nil
    }

    private func startSystemAudio(targetFormat: AVAudioFormat) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw LiveCaptionError.noDisplay }
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(targetFormat.sampleRate)
        configuration.channelCount = Int(targetFormat.channelCount)

        guard let bridge else { throw LiveCaptionError.invalidSystemAudio }
        let output = ScreenAudioOutput { [weak self, bridge] buffer in
            do {
                let converted: AVAudioPCMBuffer
                if buffer.format == targetFormat {
                    converted = buffer
                } else if let converter = AVAudioConverter(from: buffer.format, to: targetFormat) {
                    converted = try AudioFileFeeder.convert(buffer, using: converter, to: targetFormat)
                } else {
                    throw LiveCaptionError.noCompatibleAudioFormat
                }
                _ = bridge.yield(AnalyzerInput(buffer: converted))
            } catch {
                Task { @MainActor [weak self] in self?.onError(error) }
            }
        }
        screenOutput = output
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: screenQueue)
        screenStream = stream
        try await stream.startCapture()
    }
}

@MainActor
private final class WhisperLiveCaptionPipeline: LiveCaptionPipeline {
    private let source: LiveCaptionSource
    private let locale: Locale
    private let context: WhisperModelContext
    private let onCaption: (LiveCaptionSource, String, Bool) -> Void
    private let onError: (Error) -> Void

    private var liveBuffer: WhisperLiveSampleBuffer?
    private var inferenceTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var microphoneConverter: AVAudioConverter?
    private var hasMicrophoneTap = false
    private var screenStream: SCStream?
    private var screenOutput: ScreenAudioOutput?
    private let screenQueue = DispatchQueue(label: "ca.lixinchen.localscribe.live-caption-whisper-audio")

    init(
        source: LiveCaptionSource,
        locale: Locale,
        context: WhisperModelContext,
        onCaption: @escaping (LiveCaptionSource, String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.source = source
        self.locale = locale
        self.context = context
        self.onCaption = onCaption
        self.onError = onError
    }

    func start() async throws {
        let buffer = WhisperLiveSampleBuffer()
        liveBuffer = buffer
        switch source {
        case .microphone:
            try await startMicrophone(buffer: buffer)
        case .systemAudio:
            try await startSystemAudio(buffer: buffer)
        }

        let owner = self
        let source = self.source
        let language = locale.language.languageCode?.identifier ?? "auto"
        let context = self.context
        inferenceTask = Task.detached(priority: .userInitiated) { [owner, source, context, buffer] in
            do {
                while !Task.isCancelled {
                    if var chunk = await buffer.takeChunk(
                        minimumCount: WhisperAudio.sampleRate * 2,
                        maximumCount: WhisperAudio.sampleRate * 6
                    ) {
                        if chunk.isEmpty { break }
                        WhisperAudio.preprocess(&chunk)
                        guard WhisperAudio.hasSpeechEnergy(chunk) else { continue }
                        let segments = try await context.transcribe(
                            samples: chunk,
                            languageCode: language,
                            preserveContext: false,
                            mode: .realtime
                        )
                        let text = segments.map(\.text)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        if !text.isEmpty {
                            await owner.emit(source: source, text: text)
                        }
                    } else if await buffer.isFinishedAndEmpty {
                        break
                    } else {
                        try await Task.sleep(for: .milliseconds(60))
                    }
                }
            } catch is CancellationError {
            } catch {
                await owner.report(error)
            }
        }
    }

    func stop() async {
        stopMicrophone()
        if let screenStream {
            try? await screenStream.stopCapture()
        }
        screenStream = nil
        screenOutput = nil
        await liveBuffer?.finish()
        _ = await inferenceTask?.result
        inferenceTask = nil
        liveBuffer = nil
    }

    private func emit(source: LiveCaptionSource, text: String) {
        onCaption(source, text, true)
    }

    private func report(_ error: Error) {
        onError(error)
    }

    private func startMicrophone(buffer: WhisperLiveSampleBuffer) async throws {
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else { throw LiveCaptionError.microphonePermissionDenied }

        let engine = AVAudioEngine()
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else {
            throw LiveCaptionError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: WhisperAudio.format) else {
            throw WhisperEngineError.invalidAudio
        }
        WhisperAudio.configure(converter)
        audioEngine = engine
        microphoneConverter = converter
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: naturalFormat) { [weak self, buffer] input, _ in
            guard let converter = self?.microphoneConverter else { return }
            do {
                let samples = try WhisperAudio.convert(input, using: converter)
                Task { await buffer.append(samples) }
            } catch {
                Task { @MainActor [weak self] in self?.onError(error) }
            }
        }
        hasMicrophoneTap = true
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        guard let engine = audioEngine else { return }
        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }
        engine.stop()
        audioEngine = nil
        microphoneConverter = nil
    }

    private func startSystemAudio(buffer: WhisperLiveSampleBuffer) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw LiveCaptionError.noDisplay }
        let excludedApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = WhisperAudio.sampleRate
        configuration.channelCount = 1

        let output = ScreenAudioOutput { [weak self, buffer] input in
            do {
                let samples: [Float]
                if input.format == WhisperAudio.format {
                    samples = WhisperAudio.floatSamples(from: input)
                } else if let converter = AVAudioConverter(from: input.format, to: WhisperAudio.format) {
                    WhisperAudio.configure(converter)
                    samples = try WhisperAudio.convert(input, using: converter)
                } else {
                    throw WhisperEngineError.invalidAudio
                }
                Task { await buffer.append(samples) }
            } catch {
                Task { @MainActor [weak self] in self?.onError(error) }
            }
        }
        screenOutput = output
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: screenQueue)
        screenStream = stream
        try await stream.startCapture()
    }
}

private final class ScreenAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: @Sendable (AVAudioPCMBuffer) -> Void

    init(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.makePCMBuffer() else { return }
        handler(buffer)
    }
}

private extension CMSampleBuffer {
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var audioDescription = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &audioDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

@MainActor
private final class LiveCaptionPanelPresenter {
    private var panel: NSPanel?

    func show(controller: LiveCaptionController) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = LiveCaptionPanel(
            contentRect: storedFrame(),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "实时字幕"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.titlebarSeparatorStyle = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.minSize = NSSize(width: 440, height: 116)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let hostingView = NSHostingView(rootView: LiveCaptionPanelView(controller: controller))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 22
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        panel.delegate = CaptionPanelDelegate.shared
        CaptionPanelDelegate.shared.onMove = { [weak panel] in
            guard let panel else { return }
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "LiveCaptionPanelFrame")
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func storedFrame() -> NSRect {
        if let value = UserDefaults.standard.string(forKey: "LiveCaptionPanelFrame") {
            let rect = NSRectFromString(value)
            if rect.width >= 320, rect.height >= 120 { return rect }
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(x: screenFrame.midX - 300, y: screenFrame.minY + 96, width: 600, height: 128)
    }
}

private final class LiveCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CaptionPanelDelegate: NSObject, NSWindowDelegate {
    static let shared = CaptionPanelDelegate()
    var onMove: (() -> Void)?

    func windowDidMove(_ notification: Notification) {
        onMove?()
    }

    func windowDidResize(_ notification: Notification) {
        onMove?()
    }
}

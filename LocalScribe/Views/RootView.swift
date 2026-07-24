import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @State private var catalog = LanguageCatalog()
    @State private var preferences = RecognitionPreferences()
    @State private var translationPreferences = AppleTranslationPreferences()
    @State private var liveCaptions = LiveCaptionController()
    @State private var session: TranscriptionSessionModel?
    @State private var isShowingFileImporter = false
    @State private var fileImporterKind: FileImporterKind = .transcriptionMedia
    @State private var isShowingImportOptions = false
    @State private var pendingImportedTranscript: ImportedTranscript?
    @State private var importError: String?
    @State private var recoverySnapshot: RecoverySnapshot?

    var body: some View {
        NavigationStack {
            StartView(
                catalog: catalog,
                preferences: preferences,
                liveCaptions: liveCaptions,
                recoverySnapshot: recoverySnapshot,
                startMicrophone: startMicrophone,
                chooseFile: { showFileImporter(.transcriptionMedia) },
                chooseTranscript: { showFileImporter(.transcript) },
                restoreRecovery: restoreRecovery,
                clearRecovery: clearRecovery
            )
            .navigationDestination(isPresented: Binding(
                get: { session != nil },
                set: { shown in
                    if !shown { closeCurrentSession() }
                }
            )) {
                if let session {
                    TranscriptionView(
                        session: session,
                        catalog: catalog,
                        recognitionPreferences: preferences,
                        translationPreferences: translationPreferences,
                        close: closeCurrentSession,
                        restart: restartCurrentSession
                    )
                }
            }
        }
        .task {
            recoverySnapshot = RecoveryStore.load()
            await catalog.load()
#if DEBUG
            if ProcessInfo.processInfo.environment["LOCALSCRIBE_LIVE_CAPTION_PREVIEW"] == "1" {
                liveCaptions.showDesignPreview()
            }
            if ProcessInfo.processInfo.environment["LOCALSCRIBE_RESULT_PREVIEW"] == "1" {
                let preview = TranscriptionSessionModel(
                    source: .recovered("转录结果预览"),
                    locale: Locale(identifier: "en_US"),
                    configuration: RecognitionConfiguration(engine: .apple)
                )
                preview.transcriptText = "Some people say the secret to happiness is having no expectations. The transcript remains editable after recognition finishes."
                preview.elapsed = 18
                preview.phase = .finished
                session = preview
            }
#endif
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: fileImporterKind.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch fileImporterKind {
            case .transcriptionMedia:
                startSession(.file(url))
            case .transcript:
                do {
                    pendingImportedTranscript = try TranscriptImporter.load(url: url)
                    isShowingImportOptions = true
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "如何使用导入的稿件？",
            isPresented: $isShowingImportOptions,
            titleVisibility: .visible
        ) {
            Button("打开并编辑") { openImportedTranscript(continueWithMicrophone: false) }
            Button("保留稿件并继续麦克风转录") { openImportedTranscript(continueWithMicrophone: true) }
            Button("取消", role: .cancel) { pendingImportedTranscript = nil }
        } message: {
            Text("继续转录会进入准备页，等待你点击“开始转录”；新识别文字会追加到导入稿件之后。")
        }
        .alert("无法导入稿件", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? L10n.text("未知错误"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseTranscriptionFile)) { _ in
            guard session == nil else { return }
            showFileImporter(.transcriptionMedia)
        }
    }

    private func showFileImporter(_ kind: FileImporterKind) {
        fileImporterKind = kind
        isShowingFileImporter = true
    }

    private func startMicrophone() {
        startSession(.microphone)
    }

    private func startSession(_ source: TranscriptionSource) {
        let model = TranscriptionSessionModel(
            source: source,
            locale: catalog.selectedLocale,
            configuration: preferences.configuration
        )
        session = model
    }

    private func openImportedTranscript(continueWithMicrophone: Bool) {
        guard let imported = pendingImportedTranscript else { return }
        let locale = catalog.selectedLocale
        let configuration = preferences.configuration
        // Do not mutate any SwiftUI state from the confirmation action itself.
        // AppKit is still tearing down its alert sheet at that point; invalidating
        // the hosting hierarchy during the same display cycle can raise an
        // NSWindow constraint-update exception on macOS. Commit the import only
        // after the sheet animation is fully complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pendingImportedTranscript = nil
            session = TranscriptionSessionModel(
                imported: imported,
                continueWithMicrophone: continueWithMicrophone,
                locale: locale,
                configuration: configuration
            )
        }
    }

    private func restoreRecovery() {
        guard let recoverySnapshot else { return }
        session = TranscriptionSessionModel(snapshot: recoverySnapshot)
    }

    private func clearRecovery() {
        try? RecoveryStore.clear()
        recoverySnapshot = nil
    }

    private func closeCurrentSession() {
        guard let current = session else { return }
        Task {
            await current.cancel()
            await MainActor.run {
                recoverySnapshot = RecoveryStore.load()
                session = nil
            }
        }
    }

    private func restartCurrentSession() {
        guard let current = session else { return }
        let source = current.source
        Task {
            await current.cancel()
            await MainActor.run {
                let model = TranscriptionSessionModel(
                    source: source,
                    locale: catalog.selectedLocale,
                    configuration: preferences.configuration
                )
                session = model
            }
        }
    }
}

private enum FileImporterKind {
    case transcriptionMedia
    case transcript

    var allowedContentTypes: [UTType] {
        switch self {
        case .transcriptionMedia:
            [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        case .transcript:
            [
                .plainText,
                .json,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "srt") ?? .plainText,
                UTType(filenameExtension: "vtt") ?? .plainText
            ]
        }
    }
}

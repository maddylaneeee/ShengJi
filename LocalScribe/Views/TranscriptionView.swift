import SwiftUI

struct TranscriptionView: View {
    @Environment(\.locale) private var interfaceLocale
    @Bindable var session: TranscriptionSessionModel
    @Bindable var catalog: LanguageCatalog
    @Bindable var recognitionPreferences: RecognitionPreferences
    @Bindable var translationPreferences: AppleTranslationPreferences
    @Bindable var cursorInput: CursorInputController
    let close: () -> Void
    let restart: () -> Void

    @State private var isShowingExport = false
    @State private var exportFormat: TranscriptExportFormat = .txt
    @State private var exportDocument = TranscriptFileDocument(data: Data())
    @State private var isShowingFileExporter = false
    @State private var exportError: String?
    @State private var isShowingTranslation = false
    @State private var preflightTranslationEnabled = false
    @State private var exportUsesTranslation = false
    @State private var nllbModelManager = NLLBModelManager()
    @State private var isConfirmingRestart = false
    @State private var restartAfterExport = false
    @State private var copyStatus: String?
    @State private var editorSelection = NSRange(location: 0, length: 0)
    @State private var searchText = ""
    @State private var replacementText = ""
    @State private var firstEditNode: NSRange?
    @State private var secondEditNode: NSRange?
    @State private var editStatus: String?
    @State private var isAdvancedExpanded = false
    @State private var gemmaModelManager = GemmaModelManager()
    @State private var gemmaKind: GemmaOptimizationKind?
    @State private var gemmaModel: GemmaModel = .e2b
    @State private var gemmaPrompt = ""
    @State private var gemmaIsPreparing = false
    @State private var gemmaReady = false
    @State private var gemmaIsRunning = false
    @State private var gemmaProgress: (Int, Int)?
    @State private var gemmaError: String?
    @State private var gemmaFailures: [GemmaSegmentFailure] = []
    @State private var gemmaTask: Task<Void, Never>?
    @AppStorage("EnableGemmaE4B") private var enableGemmaE4B = false

    var body: some View {
        observedContent
    }

    private var presentedContent: some View {
        VStack(spacing: 0) {
            statusStrip
            Divider()
            if session.phase == .preparing {
                preflightPanel
                Divider()
            } else if session.phase == .finished {
                translationBar
                Divider()
            }
            if session.canEdit, !isShowingTranslation {
                editingToolsBar
                Divider()
            }
            transcriptEditor
        }
        .navigationTitle(session.displayTitle)
        .navigationSubtitle(session.phase.label)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { transportControls }
        .inspector(isPresented: $session.isShowingInspector) { inspector }
        .sheet(isPresented: $isShowingExport) { exportSheet }
        .fileExporter(
            isPresented: $isShowingFileExporter,
            document: exportDocument,
            contentType: exportFormat.contentType,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                if restartAfterExport { restart() }
            case .failure(let error):
                exportError = error.localizedDescription
            }
            restartAfterExport = false
        }
        .alert("重新开始？", isPresented: $isConfirmingRestart) {
            Button("取消", role: .cancel) {}
            Button("不保存，重新开始", role: .destructive) { restart() }
            Button("保存后重新开始") { prepareRestartExport() }
        } message: {
            Text(session.translatedText.isEmpty
                ? "是否先保存当前转录？新页面会等待你再次点击“开始转录”。"
                : "是否先保存当前译文？新页面会等待你再次点击“开始转录”。")
        }
        .alert("无法导出", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? L10n.text("未知错误"))
        }
        .alert("无法启用光标输入", isPresented: cursorInputErrorPresented) {
            Button("好") { cursorInput.clearError() }
        } message: {
            Text(cursorInput.errorMessage ?? L10n.text("未知错误"))
        }
    }

    private var primaryObservedContent: some View {
        presentedContent
        .onAppear {
            isAdvancedExpanded = false
            nllbModelManager.refresh()
            gemmaModelManager.refresh()
            syncPendingConfiguration()
        }
        .onChange(of: catalog.selectedLocaleIdentifier) { _, _ in syncPendingConfiguration() }
        .onChange(of: recognitionPreferences.configuration) { _, _ in syncPendingConfiguration() }
        .onChange(of: recognitionPreferences.advancedOptions) { _, _ in syncPendingConfiguration() }
        .onChange(of: translationPreferences.targetLanguage) { _, newTarget in
            handleTranslationTargetChange(newTarget)
        }
        .onChange(of: translationPreferences.provider) { _, newProvider in
            handleTranslationProviderChange(newProvider)
        }
        .onChange(of: preflightTranslationEnabled) { _, _ in syncPendingConfiguration() }
        .onChange(of: session.translatedText) { _, translatedText in
            if !translatedText.isEmpty { isShowingTranslation = true }
        }
        .onChange(of: nllbModelManager.isInstalled) { _, isInstalled in
            guard isInstalled else { return }
            syncPendingConfiguration()
            guard session.phase == .finished,
                  translationPreferences.provider == .nllb,
                  !selectedTranslationTargetMatchesSource else { return }
            session.translate(
                targetLanguage: translationPreferences.targetLanguage,
                provider: .nllb
            )
        }
    }

    private var observedContent: some View {
        primaryObservedContent
        .onChange(of: session.transcriptText) { _, text in
            if session.isCursorInput { cursorInput.sync(transcript: text) }
        }
        .onChange(of: session.phase) { _, phase in
            handleCursorSessionPhase(phase)
        }
        .onChange(of: gemmaModelManager.installedModels) { _, installed in
            guard installed.contains(gemmaModel), gemmaKind != nil else { return }
            prepareGemma()
        }
        .onChange(of: gemmaModel) { _, _ in
            guard gemmaKind != nil else { return }
            prepareGemma()
        }
        .onDisappear(perform: handleDisappear)
    }

    private var cursorInputErrorPresented: Binding<Bool> {
        Binding(
            get: { cursorInput.errorMessage != nil },
            set: { presented in
                if !presented { cursorInput.clearError() }
            }
        )
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            PhaseIndicator(phase: session.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.phase.label)
                    .font(.callout.weight(.medium))
                if session.phase.isActive, session.phase != .preparing {
                    Text(session.activityDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(session.activityDetail)
                }
            }
            Spacer()
            if session.isTranslating {
                if case .translating(let completed, let total) = session.translationProgress {
                    ProgressView(value: Double(completed), total: Double(total))
                        .frame(width: 90)
                    Text("\(activeTranslationProviderTitle)正在翻译 \(completed)/\(total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在准备翻译环境…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !session.translatedText.isEmpty {
                Picker("显示内容", selection: $isShowingTranslation) {
                    Text("原文").tag(false)
                    Text("译文").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()
            }
            if case .file = session.source, session.phase != .finished {
                if session.progressIsIndeterminate {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(session.activityDetail)
                } else {
                    HStack(spacing: 7) {
                        ProgressView(value: session.progress)
                            .frame(width: 110)
                        Text(session.progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(session.activityDetail)
                }
            }
            if session.canUndoAIChange {
                Button("撤销 AI 修改", systemImage: "arrow.uturn.backward.circle") {
                    session.undoLastAIChange()
                    editStatus = L10n.text("已撤销 AI 修改")
                    gemmaFailures = []
                }
                .buttonStyle(.bordered)
            }
            Label(session.elapsed.formattedDuration, systemImage: "clock")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var transcriptEditor: some View {
        ZStack(alignment: .topLeading) {
            if isShowingTranslation, !session.translatedText.isEmpty {
                TranscriptStreamView(
                    segments: session.displayTranslatedSegments,
                    totalCount: session.translatedSegments.count,
                    isActive: false,
                    animatedText: nil
                )
            } else if session.canEdit {
                HStack(spacing: 0) {
                    Spacer(minLength: 20)
                    TranscriptEditingTextView(text: $session.transcriptText, selection: $editorSelection)
                        .onChange(of: session.transcriptText) { _, _ in session.noteDirectEdit() }
                        .frame(maxWidth: 900)
                    Spacer(minLength: 20)
                }
            } else {
                TranscriptStreamView(
                    segments: session.displaySegments,
                    totalCount: session.segments.count,
                    isActive: session.phase.isActive,
                    animatedText: session.usesAnimatedStreamingDisplay ? session.animatedTranscriptText : nil
                )
            }

            if session.transcriptText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(placeholderTitle)
                        .font(.title3.weight(.medium))
                    Text(placeholderDetail)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }

    private var preflightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    preflightLanguagePicker
                    preflightEnginePicker
                    preflightModelControl
                    Spacer(minLength: 8)
                    preflightReadiness
                }

                VStack(alignment: .leading, spacing: 10) {
                    preflightLanguagePicker
                    HStack(spacing: 10) {
                        preflightEnginePicker
                        preflightModelControl
                    }
                    preflightReadiness
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Toggle("完成后自动翻译", isOn: $preflightTranslationEnabled)
                        .toggleStyle(.switch)
                    preflightTranslationServicePicker
                    preflightTranslationTargetPicker
                    Spacer(minLength: 8)
                    preflightTranslationStatus
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("完成后自动翻译", isOn: $preflightTranslationEnabled)
                        .toggleStyle(.switch)
                    HStack(spacing: 10) {
                        preflightTranslationServicePicker
                        preflightTranslationTargetPicker
                    }
                    preflightTranslationStatus
                }
            }

            Label(computePreferenceHint, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var preflightLanguagePicker: some View {
        Picker("识别语言", selection: $catalog.selectedLocaleIdentifier) {
            if !catalog.languages.contains(where: { $0.id == catalog.selectedLocaleIdentifier }) {
                Text(catalog.selectedLocaleIdentifier).tag(catalog.selectedLocaleIdentifier)
            }
            Section("推荐语言") {
                ForEach(catalog.recommendedLanguages) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            if !catalog.otherLanguages.isEmpty {
                Section("所有语言") {
                    ForEach(catalog.otherLanguages) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }
            }
        }
        .id("recognition-language-\(interfaceLocale.identifier)")
        .frame(minWidth: 180, maxWidth: 260)
        .disabled(catalog.isLoading)
    }

    private var computePreferenceHint: String {
        switch recognitionPreferences.engine {
        case .apple:
            L10n.text("macOS 会自动为内置识别选择合适的性能设置。")
        case .whisper:
            L10n.text("可用时自动使用 GPU 加速，否则回退到 CPU。")
        case .senseVoice, .parakeet:
            L10n.text("声迹会自动选择适合这台 Mac 的处理方式。")
        }
    }

    private var preflightEnginePicker: some View {
        Picker("识别模型", selection: Binding(
            get: { recognitionPreferences.engine != .apple },
            set: { useThirdParty in
                if useThirdParty {
                    if case .microphone = session.source {
                        recognitionPreferences.chooseEngine(.whisper)
                    } else {
                        recognitionPreferences.chooseThirdParty()
                    }
                } else {
                    recognitionPreferences.chooseDefault()
                }
            }
        )) {
            Label("默认", systemImage: "apple.logo").tag(false)
            Label("第三方模型", systemImage: "shippingbox").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 250, maxWidth: 330)
    }

    @ViewBuilder
    private var preflightModelControl: some View {
        if recognitionPreferences.engine.usesManagedModel {
            Menu {
                Section("Whisper · Metal") {
                    ForEach(WhisperModel.allCases.map(ManagedSpeechModel.whisper)) { model in
                        preflightModelButton(model)
                    }
                }
                if case .file = session.source {
                    Section("SenseVoice") {
                        ForEach(SenseVoiceModel.allCases.map(ManagedSpeechModel.senseVoice)) { model in
                            preflightModelButton(model)
                        }
                    }
                    Section("NVIDIA Parakeet") {
                        ForEach(ParakeetModel.allCases.map(ManagedSpeechModel.parakeet)) { model in
                            preflightModelButton(model)
                        }
                    }
                }
            } label: {
                Label(preflightModelTitle, systemImage: recognitionPreferences.engine.symbol)
            }
            .disabled(recognitionPreferences.downloadState.isDownloading)
        }
    }

    private func preflightModelButton(_ model: ManagedSpeechModel) -> some View {
        Button {
            recognitionPreferences.chooseModel(model)
        } label: {
            Label(
                "\(model.title) · \(model.sizeLabel)\(recognitionPreferences.installedModels.contains(model) ? L10n.text(" · 已下载") : "")",
                systemImage: model.engine.symbol
            )
        }
    }

    private var preflightModelTitle: String {
        "\(recognitionPreferences.selectedManagedModel.title)\(recognitionPreferences.selectedModelIsInstalled ? L10n.text(" · 已下载") : L10n.text(" · 未下载"))"
    }

    @ViewBuilder
    private var preflightReadiness: some View {
        switch recognitionPreferences.downloadState {
        case .idle:
            if canStartSession {
                Label("准备就绪", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label(preflightBlockedReason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        case .downloading(let model, let progress):
            ProgressView(value: progress)
                .frame(width: 92)
            Text("\(model.title) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption.monospacedDigit())
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private var preflightTranslationTargetPicker: some View {
        Picker("译为", selection: $translationPreferences.targetLanguage) {
            ForEach(TranslationTargetLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        }
        .frame(width: 150)
        .disabled(!preflightTranslationEnabled)
    }

    private var preflightTranslationServicePicker: some View {
        Picker("翻译服务", selection: $translationPreferences.provider) {
            ForEach(TranslationProvider.allCases) { provider in
                Text(provider.title).tag(provider)
            }
        }
        .frame(width: 150)
        .disabled(!preflightTranslationEnabled)
    }

    @ViewBuilder
    private var preflightTranslationStatus: some View {
        if preflightTranslationEnabled {
            if translationPreferences.provider == .nllb {
                HStack(spacing: 8) {
                    nllbModelStatus
                    if !isNLLBTranslationReady { nllbModelDownloadAction }
                }
            } else {
                Label("完成后由 \(translationPreferences.provider.title) 自动生成译文", systemImage: "translate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("返回", systemImage: "chevron.left") { close() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("检查器", systemImage: "sidebar.trailing") {
                session.isShowingInspector.toggle()
            }
            Button("导出", systemImage: "square.and.arrow.up") {
                isShowingExport = true
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var translationBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                translationLabel
                translationServicePicker
                translationTargetPicker
                translationStatus
                Spacer(minLength: 8)
                translationAction
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    translationLabel
                    translationStatus
                    Spacer()
                    translationAction
                }
                HStack(spacing: 10) {
                    translationServicePicker
                    translationTargetPicker
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var editingToolsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchAndReplaceControls }
                VStack(alignment: .leading, spacing: 8) { searchAndReplaceControls }
            }

            HStack(spacing: 8) {
                Label(selectionDescription, systemImage: "selection.pin.in.out")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button("设为节点 A") {
                    firstEditNode = editorSelection
                    editStatus = L10n.text("已设置节点 A")
                }
                .disabled(TranscriptTextEditing.validRange(editorSelection, in: session.transcriptText) == nil)

                Button("设为节点 B") {
                    secondEditNode = editorSelection
                    editStatus = L10n.text("已设置节点 B")
                }
                .disabled(TranscriptTextEditing.validRange(editorSelection, in: session.transcriptText) == nil)

                Menu("范围删除", systemImage: "scissors") {
                    Button("删除当前节点之前全部", systemImage: "text.badge.minus") {
                        applyEdit(TranscriptTextEditing.deletingBefore(session.transcriptText, node: editorSelection))
                    }
                    Button("删除当前节点之后全部", systemImage: "text.badge.minus") {
                        applyEdit(TranscriptTextEditing.deletingAfter(session.transcriptText, node: editorSelection))
                    }
                    Divider()
                    Button("删除节点 A 与 B 之间全部", systemImage: "arrow.left.and.right.text.vertical") {
                        guard let firstEditNode, let secondEditNode else { return }
                        applyEdit(TranscriptTextEditing.deletingBetween(
                            session.transcriptText,
                            first: firstEditNode,
                            second: secondEditNode
                        ))
                    }
                    .disabled(firstEditNode == nil || secondEditNode == nil)
                }

                if let editStatus {
                    Text(editStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var searchAndReplaceControls: some View {
        TextField("搜索词句", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)
            .onSubmit { findNext() }

        Button("查找下一个", systemImage: "magnifyingglass") { findNext() }
            .disabled(searchText.isEmpty)

        Divider().frame(height: 20)

        TextField("替换为…", text: $replacementText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)

        Button("替换所选", systemImage: "arrow.triangle.2.circlepath") {
            applyEdit(TranscriptTextEditing.replacing(
                session.transcriptText,
                range: editorSelection,
                with: replacementText
            ))
        }
        .disabled(editorSelection.length == 0)

        Button("删除所选", systemImage: "delete.left", role: .destructive) {
            applyEdit(TranscriptTextEditing.replacing(session.transcriptText, range: editorSelection, with: ""))
        }
        .disabled(editorSelection.length == 0)
    }

    private var selectionDescription: String {
        if editorSelection.length > 0 { return L10n.format("已选择 %lld 个字符", editorSelection.length) }
        return L10n.format("光标位置 %lld", editorSelection.location)
    }

    private func findNext() {
        guard let found = TranscriptTextEditing.find(searchText, in: session.transcriptText, after: editorSelection) else {
            editStatus = L10n.format("未找到“%@”", searchText)
            return
        }
        editorSelection = found
        editStatus = L10n.text("已找到")
    }

    private func applyEdit(_ result: (String, NSRange)?) {
        guard let (text, selection) = result else {
            editStatus = L10n.text("无法执行此操作")
            return
        }
        session.transcriptText = text
        editorSelection = selection
        firstEditNode = nil
        secondEditNode = nil
        editStatus = L10n.text("已修改")
    }

    private var translationLabel: some View {
        Label("翻译", systemImage: "translate")
            .font(.callout.weight(.semibold))
    }

    private var translationTargetPicker: some View {
        Picker("译为", selection: $translationPreferences.targetLanguage) {
            ForEach(TranslationTargetLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        }
        .frame(width: 170)
    }

    private var translationServicePicker: some View {
        Picker("服务", selection: $translationPreferences.provider) {
            ForEach(TranslationProvider.allCases) { provider in
                Text(provider.title).tag(provider)
            }
        }
        .frame(width: 150)
    }

    private var translationAction: some View {
        HStack(spacing: 8) {
            if !session.isCursorInput {
                Menu("AI 优化", systemImage: "sparkles") {
                    Button("纠错与润色", systemImage: "wand.and.stars") { chooseGemma(.proofread) }
                    Button("总结", systemImage: "text.alignleft") { chooseGemma(.summarize) }
                }
                .disabled(session.isTranslating || gemmaIsRunning || !GemmaHardwareSupport.isSupported)
                .help(GemmaHardwareSupport.isSupported ? "" : GemmaHardwareSupport.unsupportedReason)
            }
            if translationPreferences.provider == .nllb, !isNLLBTranslationReady {
                nllbModelDownloadAction
            }
            Button(session.translatedText.isEmpty ? "生成译文" : "重新翻译", systemImage: "sparkles") {
                session.translate(
                    targetLanguage: translationPreferences.targetLanguage,
                    provider: translationPreferences.provider
                )
            }
            .primaryActionStyle()
            .disabled(session.isTranslating || selectedTranslationTargetMatchesSource || !selectedTranslationProviderReady)
        }
    }

    @ViewBuilder
    private var translationStatus: some View {
        if selectedTranslationTargetMatchesSource {
            Text("目标语言与原文相同")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if translationPreferences.provider == .nllb, !isNLLBTranslationReady {
            nllbModelStatus
        } else if let error = session.translationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if session.isTranslating {
            if case .translating(let completed, let total) = session.translationProgress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(completed), total: Double(total))
                        .frame(width: 80)
                    Text("已翻译 \(completed)/\(total) 个片段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在准备翻译环境…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(translationPreferences.provider == .apple
                ? "Apple 本地翻译；首次使用可能需要下载语言包"
                : "NLLB 本机模型翻译")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedTranslationTargetMatchesSource: Bool {
        translationPreferences.targetLanguage.isEquivalent(to: session.locale)
    }

    private var selectedTranslationProviderReady: Bool {
        switch translationPreferences.provider {
        case .apple: true
        case .nllb: isNLLBTranslationReady
        }
    }

    private var isNLLBTranslationReady: Bool {
        NLLBTranslationRuntime.isRuntimeBundled && nllbModelManager.isInstalled
    }

    @ViewBuilder
    private var nllbModelStatus: some View {
        if !NLLBTranslationRuntime.isRuntimeBundled {
            Label("此版本无法使用离线翻译", systemImage: "exclamationmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            switch nllbModelManager.state {
            case .idle:
                if nllbModelManager.isInstalled {
                    Label("离线翻译已就绪", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("需下载离线翻译模型 · \(NLLBModelStore.sizeLabel)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("下载离线翻译模型 · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var nllbModelDownloadAction: some View {
        if NLLBTranslationRuntime.isRuntimeBundled {
            switch nllbModelManager.state {
            case .idle:
                if !nllbModelManager.isInstalled {
                    Button("下载模型", systemImage: "arrow.down.circle") {
                        nllbModelManager.download()
                    }
                    .buttonStyle(.bordered)
                    .help("下载 \(NLLBModelStore.title)，约 \(NLLBModelStore.sizeLabel)，CC-BY-NC-4.0")
                }
            case .downloading:
                Button("取消", systemImage: "xmark.circle") {
                    nllbModelManager.cancelDownload()
                }
                .buttonStyle(.bordered)
            case .failed:
                Button("重试", systemImage: "arrow.clockwise") {
                    nllbModelManager.download()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var activeTranslationProviderTitle: String {
        session.translationConfiguration?.provider.title ?? translationPreferences.provider.title
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            if session.canStart {
                if session.isCursorInput {
                    if cursorInput.isArmed {
                        Button("取消准备", systemImage: "xmark.circle") { cursorInput.finish() }
                    } else {
                        Button("准备开始", systemImage: "cursorarrow.motionlines") { armCursorInput() }
                            .keyboardShortcut(.defaultAction)
                            .primaryActionStyle()
                            .disabled(!canStartSession)
                    }
                } else {
                    Button("开始转录", systemImage: "record.circle") {
                        syncPendingConfiguration()
                        Task { await session.start() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .primaryActionStyle()
                    .disabled(!canStartSession)
                }
            } else if session.canPause {
                Button("暂停", systemImage: "pause.fill") { session.pause() }
                    .keyboardShortcut(.space, modifiers: [])
            } else if session.canResume {
                Button("继续", systemImage: "play.fill") { Task { await session.resume() } }
                    .keyboardShortcut(.space, modifiers: [])
                    .primaryActionStyle()
            }

            if session.canStop {
                Button("完成", systemImage: "stop.fill") {
                    Task {
                        await session.stop()
                        if session.isCursorInput { cursorInput.finish() }
                    }
                }
            }

            if session.phase == .finished {
                Button("重新开始", systemImage: "arrow.counterclockwise") {
                    isConfirmingRestart = true
                }
                Button("导出转录", systemImage: "square.and.arrow.up") { isShowingExport = true }
                    .primaryActionStyle()
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 14)
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
    }

    private var inspector: some View {
        Form {
            Section(session.isCursorInput ? "光标输入" : "转录") {
                LabeledContent("来源") {
                    Label(session.displayTitle, systemImage: session.displaySymbol)
                        .lineLimit(1)
                }
                LabeledContent("语言", value: session.languageName)
                if session.isImportedTranscript {
                    LabeledContent("类型", value: L10n.text("导入稿件"))
                } else {
                    LabeledContent("引擎", value: session.configuration.displayName)
                }
                LabeledContent("时长", value: session.elapsed.formattedDuration)
                LabeledContent("文字") {
                    Text("\(session.transcriptText.count) 字符")
                        .monospacedDigit()
                }
            }

            if !session.isCursorInput, session.phase == .finished {
                gemmaInspector
            }

            if !session.isImportedTranscript, advancedEngine != .apple {
                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isAdvancedExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                            Label("高级", systemImage: "slider.horizontal.3")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isAdvancedExpanded ? L10n.text("已展开") : L10n.text("已折叠"))

                    if isAdvancedExpanded {
                        advancedOptionsControls
                            .padding(.top, 6)
                            .disabled(!session.canStart)
                        if let status = session.computeBackendStatus {
                            Divider()
                                .padding(.vertical, 4)
                            LabeledContent("处理方式", value: status.detail)
                            if let fallback = status.fallbackReason {
                                Text(fallback)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if case .microphone = session.source, session.phase == .transcribing {
                Section("输入电平") {
                    AudioLevelMeter(level: session.audioLevel)
                        .accessibilityLabel("麦克风输入电平")
                        .accessibilityValue("\(Int(session.audioLevel * 100))%")
                }
            }

            Section("隐私") {
                Label(session.isImportedTranscript ? "稿件在本机处理" : "识别在本机完成", systemImage: "checkmark.shield")
                Text(session.isImportedTranscript ? "导入内容不会由本应用上传。" : "音频不会由本应用上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = session.phase {
                Section("问题") {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let configuration = session.translationConfiguration {
                Section("翻译") {
                    LabeledContent("服务", value: configuration.provider.inspectorName)
                    LabeledContent("目标语言", value: configuration.targetLanguage.title)
                    if let error = session.translationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if session.isTranslating {
                        if case .translating(let completed, let total) = session.translationProgress {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: Double(completed), total: Double(total))
                                Text("已翻译 \(completed)/\(total) 个片段")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } else {
                            ProgressView("正在准备翻译环境…")
                        }
                    } else if !session.translatedText.isEmpty {
                        Label("译文已生成并加入恢复快照", systemImage: "checkmark.circle.fill")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
    }

    @ViewBuilder
    private var gemmaInspector: some View {
        Section("AI 优化") {
            if !GemmaHardwareSupport.isSupported {
                Label(GemmaHardwareSupport.unsupportedReason, systemImage: "memorychip.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let gemmaKind {
                Picker("任务", selection: Binding(
                    get: { gemmaKind },
                    set: { chooseGemma($0) }
                )) {
                    ForEach(GemmaOptimizationKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                Picker("模型", selection: $gemmaModel) {
                    Text(GemmaModel.e2b.title).tag(GemmaModel.e2b)
                    if enableGemmaE4B { Text(GemmaModel.e4b.title).tag(GemmaModel.e4b) }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("提示词")
                        .font(.caption.weight(.medium))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $gemmaPrompt)
                            .frame(minHeight: 70, maxHeight: 110)
                        if gemmaPrompt.isEmpty {
                            Text(gemmaKind == .summarize
                                ? "可指定总结长度、重点、格式或需保留的信息"
                                : "可输入正确人名、术语或希望采用的表达方式")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }

                gemmaModelStatus

                if !gemmaFailures.isEmpty {
                    Label("\(gemmaFailures.count) 个片段未通过校验，已保留原文", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(gemmaFailures.prefix(8).map(\.message).joined(separator: "\n"))
                }

                if let gemmaError {
                    Label(gemmaError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    if gemmaIsRunning {
                        Button("取消", systemImage: "xmark.circle") { cancelGemma() }
                    } else {
                        Button("开始执行", systemImage: "sparkles") { startGemma() }
                            .primaryActionStyle()
                            .disabled(!gemmaReady || !gemmaModelManager.installedModels.contains(gemmaModel))
                    }
                    Spacer()
                    Button("不使用 AI") {
                        cancelGemma()
                        self.gemmaKind = nil
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("转录完成后，可选择本机 Gemma 进行纠错、润色或总结。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("纠错与润色") { chooseGemma(.proofread) }
                        .disabled(!GemmaHardwareSupport.isSupported)
                    Button("总结") { chooseGemma(.summarize) }
                        .disabled(!GemmaHardwareSupport.isSupported)
                }
            }
        }
    }

    @ViewBuilder
    private var gemmaModelStatus: some View {
        if !GemmaRuntime.isBundled {
            Label("当前版本没有 Gemma runtime", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        } else {
            switch gemmaModelManager.state {
            case .idle:
                if gemmaModelManager.installedModels.contains(gemmaModel) {
                    if gemmaIsPreparing {
                        ProgressView("正在释放识别/翻译模型并加载 Gemma…")
                    } else if gemmaReady {
                        Label("模型已加载，可开始", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("加载模型", systemImage: "memorychip") { prepareGemma() }
                    }
                } else {
                    HStack {
                        Text("需下载 \(gemmaModel.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("下载", systemImage: "arrow.down.circle") {
                            gemmaModelManager.download(gemmaModel)
                        }
                        .disabled(!GemmaHardwareSupport.isSupported)
                    }
                }
            case .downloading(let model, let progress):
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                    HStack {
                        Text("正在下载 \(model.title) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("取消") { gemmaModelManager.cancelDownload() }
                    }
                }
            case .failed(_, let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("重试") { gemmaModelManager.download(gemmaModel) }
                }
            }
        }
        if let gemmaProgress {
            ProgressView(value: Double(gemmaProgress.0), total: Double(max(gemmaProgress.1, 1))) {
                Text("已处理 \(gemmaProgress.0)/\(gemmaProgress.1) 批")
                    .font(.caption)
            }
        }
    }

    private func armCursorInput() {
        syncPendingConfiguration()
        _ = cursorInput.arm {
            Task { await session.start() }
        } stop: {
            Task { await session.stop() }
        }
    }

    private func chooseGemma(_ kind: GemmaOptimizationKind) {
        guard GemmaHardwareSupport.isSupported else {
            gemmaError = GemmaHardwareSupport.unsupportedReason
            session.isShowingInspector = true
            return
        }
        gemmaKind = kind
        gemmaFailures = []
        gemmaError = nil
        session.isShowingInspector = true
        prepareGemma()
    }

    private func prepareGemma() {
        gemmaTask?.cancel()
        gemmaReady = false
        gemmaError = nil
        guard GemmaModelStore.isInstalled(gemmaModel), GemmaRuntime.isBundled else { return }
        gemmaIsPreparing = true
        let model = gemmaModel
        gemmaTask = Task {
            do {
                try await GemmaOptimizationService.shared.prepare(model: model)
                guard !Task.isCancelled, gemmaModel == model else { return }
                gemmaReady = true
            } catch is CancellationError {
            } catch {
                gemmaError = error.localizedDescription
            }
            gemmaIsPreparing = false
        }
    }

    private func startGemma() {
        guard let gemmaKind else { return }
        gemmaTask?.cancel()
        gemmaIsRunning = true
        gemmaError = nil
        gemmaFailures = []
        gemmaProgress = nil
        let model = gemmaModel
        let prompt = gemmaPrompt
        let segments = session.segments
        let fallback = session.transcriptText
        gemmaTask = Task {
            do {
                let result = try await GemmaOptimizationService.shared.optimize(
                    segments: segments,
                    fallbackText: fallback,
                    kind: gemmaKind,
                    prompt: prompt,
                    model: model
                ) { completed, total in
                    Task { @MainActor in gemmaProgress = (completed, total) }
                }
                guard !Task.isCancelled else { return }
                gemmaFailures = result.failures
                if session.applyAIOptimization(result) {
                    editStatus = gemmaKind == .summarize
                        ? L10n.text("AI 总结已替换文字预览，可一键撤销")
                        : L10n.text("AI 优化已更新文字预览，可一键撤销")
                } else {
                    gemmaError = L10n.text("AI 没有返回可应用的文字，已保留原文。")
                }
            } catch is CancellationError {
            } catch {
                gemmaError = error.localizedDescription
            }
            gemmaIsRunning = false
            gemmaIsPreparing = false
            gemmaReady = false
            gemmaProgress = nil
        }
    }

    private func cancelGemma() {
        gemmaTask?.cancel()
        gemmaTask = nil
        gemmaIsRunning = false
        gemmaIsPreparing = false
        gemmaReady = false
        gemmaProgress = nil
        Task { await GemmaOptimizationService.shared.cancel() }
    }

    private func handleDisappear() {
        gemmaTask?.cancel()
        Task { await GemmaOptimizationService.shared.cancel() }
        if session.isCursorInput { cursorInput.finish() }
    }

    private func handleCursorSessionPhase(_ phase: TranscriptionPhase) {
        guard session.isCursorInput else { return }
        if phase == .finished {
            cursorInput.finish()
        } else if case .failed = phase {
            cursorInput.finish()
        }
    }

    private var advancedEngine: RecognitionEngine {
        session.canStart ? recognitionPreferences.engine : session.configuration.engine
    }

    @ViewBuilder
    private var advancedOptionsControls: some View {
        switch advancedEngine {
        case .apple:
            EmptyView()
        case .whisper:
            whisperAdvancedControls
        case .senseVoice:
            senseVoiceAdvancedControls
        case .parakeet:
            parakeetAdvancedControls
        }
    }

    private var whisperAdvancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("模型提示词")
                    .font(.caption.weight(.medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: promptBinding)
                        .font(.body)
                        .frame(minHeight: 68, maxHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .accessibilityLabel("模型提示词")
                    if recognitionPreferences.advancedOptions.whisper.initialPrompt.isEmpty {
                        Text("输入专有名词、人物名或上下文")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .help(L10n.text("提供术语或上下文，帮助模型优先识别这些词；不会自动加入转写结果。"))
                Toggle(
                    "每个解码窗口都携带提示词",
                    isOn: $recognitionPreferences.advancedOptions.whisper.carryInitialPrompt
                )
                .help(L10n.text("开启后，长音频的每个解码窗口都会重复使用提示词。"))
            }

            Divider()
            Text("解码")
                .font(.caption.weight(.semibold))

            advancedSlider(
                "Temperature",
                value: $recognitionPreferences.advancedOptions.whisper.temperature,
                range: 0...1,
                step: 0.05,
                help: "越低输出越稳定。通常保持 0；提高可增加候选多样性，也可能增加错误。"
            )
            if isFileSource {
                advancedSlider(
                    "温度回退增量",
                    value: $recognitionPreferences.advancedOptions.whisper.temperatureIncrement,
                    range: 0...1,
                    step: 0.05,
                    help: "文件转写质量不佳时，逐次提高 Temperature 重试。0 表示关闭回退。"
                )
                advancedStepper(
                    "Beam size",
                    value: $recognitionPreferences.advancedOptions.whisper.beamSize,
                    range: 1...20,
                    help: "同时比较的文字候选路径数。较大可能更准确，但会变慢；通常保持 5。"
                )
            }
            if isMicrophoneSource {
                advancedStepper(
                    "Best of",
                    value: $recognitionPreferences.advancedOptions.whisper.greedyBestOf,
                    range: 1...10,
                    help: "每次麦克风解码比较的候选数。较大可能更稳定，但会增加延迟；通常保持 3。"
                )
            }
            advancedStepper(
                "上下文 token 数",
                value: $recognitionPreferences.advancedOptions.whisper.maxTextContextTokens,
                range: 0...224,
                step: 16,
                help: "保留上一段文字作为后续识别的上下文。0 表示不保留；通常保持默认值。"
            )
            threadCountControl(value: $recognitionPreferences.advancedOptions.whisper.threadCount)

            Divider()
            Text("过滤与静音")
                .font(.caption.weight(.semibold))

            Toggle(
                "抑制空白输出",
                isOn: $recognitionPreferences.advancedOptions.whisper.suppressBlank
            )
            Toggle(
                "抑制非语音 token",
                isOn: $recognitionPreferences.advancedOptions.whisper.suppressNonSpeechTokens
            )
            advancedSlider(
                "压缩比阈值",
                value: $recognitionPreferences.advancedOptions.whisper.compressionRatioThreshold,
                range: 0...5,
                step: 0.1,
                help: "用于拒绝过度重复的输出。数值越低越严格；不确定时保持默认值。"
            )
            advancedSlider(
                "平均对数概率阈值",
                value: $recognitionPreferences.advancedOptions.whisper.logProbabilityThreshold,
                range: -5...0,
                step: 0.1,
                help: "用于拒绝低置信度输出。越接近 0 越严格；不确定时保持默认值。"
            )
            if isFileSource {
                advancedSlider(
                    "无语音阈值",
                    value: $recognitionPreferences.advancedOptions.whisper.noSpeechThreshold,
                    range: 0...1,
                    step: 0.05,
                    help: "高于此概率时将片段视为无语音。调高可减少幻听，但可能漏掉较轻的说话声。"
                )

                Divider()
                Text("语音活动检测")
                    .font(.caption.weight(.semibold))

                Toggle(
                    "长文件启用 VAD",
                    isOn: $recognitionPreferences.advancedOptions.whisper.useVAD
                )
                .help(L10n.text("先检测长文件中的说话区域，减少静音段的无效识别。"))
                advancedSlider(
                    "VAD 阈值",
                    value: $recognitionPreferences.advancedOptions.whisper.vadThreshold,
                    range: 0...1,
                    step: 0.05,
                    help: "判定为说话的灵敏度。调高可减少噪声误检，但可能漏掉轻声说话。"
                )
                .disabled(!recognitionPreferences.advancedOptions.whisper.useVAD)
                advancedStepper(
                    "最短静音（毫秒）",
                    value: $recognitionPreferences.advancedOptions.whisper.vadMinimumSilenceMilliseconds,
                    range: 100...2_000,
                    step: 50,
                    help: "达到这个静音时长后才切分语音。太短可能切碎句子，太长会延迟分段。"
                )
                .disabled(!recognitionPreferences.advancedOptions.whisper.useVAD)
            } else if isMicrophoneSource {
                advancedSlider(
                    "无语音阈值",
                    value: $recognitionPreferences.advancedOptions.whisper.realtimeNoSpeechThreshold,
                    range: 0...1,
                    step: 0.05,
                    help: "高于此概率时将片段视为无语音。调高可减少实时幻听，但可能漏掉较轻的说话声。"
                )
            }

            resetAdvancedOptionsButton
        }
    }

    private var senseVoiceAdvancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "逆文本归一化（ITN）",
                isOn: $recognitionPreferences.advancedOptions.senseVoice.useInverseTextNormalization
            )
            .help(L10n.text("将口语中的数字、日期等转换为更易阅读的书写形式。"))
            threadCountControl(value: $recognitionPreferences.advancedOptions.senseVoice.threadCount)
            resetAdvancedOptionsButton
        }
    }

    private var parakeetAdvancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "解码方式",
                selection: $recognitionPreferences.advancedOptions.parakeet.decodingMethod
            ) {
                ForEach(ParakeetDecodingMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .help(L10n.text("贪心搜索速度更快；改进束搜索会比较多条候选路径，可能更准确但更慢。"))
            if recognitionPreferences.advancedOptions.parakeet.decodingMethod == .modifiedBeamSearch {
                advancedStepper(
                    "最大有效路径数",
                    value: $recognitionPreferences.advancedOptions.parakeet.maxActivePaths,
                    range: 1...64,
                    help: "束搜索保留的候选路径数。较大可能更准确，但会占用更多计算资源。"
                )
            }
            advancedSlider(
                "空白 token 惩罚",
                value: $recognitionPreferences.advancedOptions.parakeet.blankPenalty,
                range: 0...5,
                step: 0.1,
                help: "提高后模型更不容易输出空白，可能减少漏字，但过高会增加误插入。"
            )
            threadCountControl(value: $recognitionPreferences.advancedOptions.parakeet.threadCount)
            resetAdvancedOptionsButton
        }
    }

    private func advancedSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        help: String
    ) -> some View {
        let safeValue = clampedBinding(value, to: range)
        return VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text(title))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    advancedDoubleField(title, value: safeValue)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(title))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        advancedDoubleField(title, value: safeValue)
                    }
                }
            }
            Slider(value: safeValue, in: range, step: step)
                .accessibilityLabel(L10n.text(title))
        }
        .help(L10n.text(help))
    }

    private func advancedStepper(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        help: String
    ) -> some View {
        let safeValue = clampedBinding(value, to: range)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.text(title))
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                advancedIntegerControls(title, value: safeValue, range: range, step: step)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(title))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    advancedIntegerControls(title, value: safeValue, range: range, step: step)
                }
            }
        }
        .help(L10n.text(help))
    }

    private func advancedDoubleField(
        _ title: String,
        value: Binding<Double>
    ) -> some View {
        TextField(
            value: value,
            format: .number.precision(.fractionLength(0...2))
        ) {
            Text(L10n.text(title))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(minWidth: 56, idealWidth: 64, maxWidth: 72)
    }

    private func advancedIntegerControls(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: 6) {
            TextField(value: value, format: .number) {
                Text(L10n.text(title))
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(minWidth: 56, idealWidth: 64, maxWidth: 72)

            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(L10n.text(title))
                .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func threadCountControl(value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("自动选择推理线程（推荐）", isOn: Binding(
                get: { value.wrappedValue == 0 },
                set: { usesAutomaticThreads in
                    value.wrappedValue = usesAutomaticThreads ? 0 : recommendedManualThreadCount
                }
            ))
            .help(L10n.text("控制识别时使用的 CPU 线程数。自动模式会根据这台 Mac 选择合适数量，通常最稳定。"))

            if value.wrappedValue != 0 {
                advancedStepper(
                    "线程数",
                    value: value,
                    range: 1...maximumManualThreadCount,
                    help: "更多线程不一定更快，过高可能造成资源争用。如果不确定，请重新开启自动模式。"
                )
            }
        }
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { recognitionPreferences.advancedOptions.whisper.initialPrompt },
            set: { recognitionPreferences.advancedOptions.whisper.initialPrompt = String($0.prefix(2_000)) }
        )
    }

    private func clampedBinding(
        _ value: Binding<Double>,
        to range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { newValue in
                guard newValue.isFinite else { return }
                value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private func clampedBinding(
        _ value: Binding<Int>,
        to range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private var isMicrophoneSource: Bool {
        if case .microphone = session.source { return true }
        return false
    }

    private var isFileSource: Bool {
        if case .file = session.source { return true }
        return false
    }

    private var maximumManualThreadCount: Int {
        RecognitionThreadPolicy.maximumManualCount
    }

    private var recommendedManualThreadCount: Int {
        RecognitionThreadPolicy.automaticCount
    }

    private var resetAdvancedOptionsButton: some View {
        Button("恢复模型默认参数", systemImage: "arrow.counterclockwise") {
            recognitionPreferences.resetAdvancedOptions(for: advancedEngine)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导出转录")
                        .font(.title2.weight(.semibold))
                    Text("选择格式，然后指定保存位置。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { isShowingExport = false }
                    .keyboardShortcut(.cancelAction)
            }

            List(TranscriptExportFormat.allCases, selection: $exportFormat) { format in
                HStack(spacing: 12) {
                    Image(systemName: format.symbol)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.title)
                        Text(format.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                .tag(format)
            }
            .listStyle(.inset)
            .frame(height: 290)

            HStack {
                if !session.translatedText.isEmpty {
                    Toggle("导出译文", isOn: $exportUsesTranslation)
                        .toggleStyle(.switch)
                }
                if session.hasManualEdits && (exportFormat == .srt || exportFormat == .webVTT) {
                    Label("编辑后的文字会按句子重新生成近似时间戳", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制到剪贴板", systemImage: "doc.on.doc") { copyToPasteboard() }
                if let copyStatus {
                    Text(copyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("选择保存位置…") { prepareExport() }
                    .keyboardShortcut(.defaultAction)
                    .primaryActionStyle()
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func prepareExport() {
        do {
            let useTranslation = exportUsesTranslation && !session.translatedText.isEmpty
            let data = try TranscriptExporter.makeData(
                format: exportFormat,
                title: defaultTitle,
                source: session.source.title,
                language: useTranslation ? (session.translationConfiguration?.targetLanguage.title ?? session.languageName) : session.languageName,
                duration: session.elapsed,
                text: useTranslation ? session.translatedText : session.transcriptText,
                segments: useTranslation ? session.translatedSegments : session.segments,
                hasManualEdits: useTranslation ? false : session.hasManualEdits,
                translations: useTranslation ? session.segmentTranslations : []
            )
            exportDocument = TranscriptFileDocument(data: data)
            isShowingExport = false
            isShowingFileExporter = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func prepareRestartExport() {
        exportFormat = .txt
        exportUsesTranslation = !session.translatedText.isEmpty
        restartAfterExport = true
        prepareExport()
    }

    private func copyToPasteboard() {
        let usesTranslation = exportUsesTranslation && !session.translatedText.isEmpty
        let text = usesTranslation ? session.translatedText : session.transcriptText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyStatus = L10n.text("已复制")
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyStatus == L10n.text("已复制") { copyStatus = nil }
        }
    }

    private var defaultTitle: String {
        if session.isCursorInput { return L10n.text("光标输入") }
        return switch session.source {
        case .microphone: L10n.text("麦克风转录")
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .recovered(let title): title
        }
    }

    private var defaultFilename: String { "\(defaultTitle).\(exportFormat.fileExtension)" }

    private var placeholderTitle: String {
        if session.isCursorInput, session.phase == .preparing {
            return L10n.text("配置光标输入")
        }
        return switch session.phase {
        case .preparing: L10n.text("选择设置，然后开始转录")
        case .failed: L10n.text("还没有可显示的文字")
        default: L10n.text("识别到的文字会显示在这里")
        }
    }

    private var placeholderDetail: String {
        if session.isCursorInput, session.phase == .preparing {
            return L10n.text("点击“准备开始”，再把文本光标放到目标 App，按 Command-Shift-S 开始。")
        }
        return switch session.phase {
        case .preparing: L10n.text("开始后会锁定当前语言、识别引擎和模型。")
        case .loadingModel, .preparingAudio, .transcribing, .finishing: session.activityDetail
        case .paused: L10n.text("已暂停。你现在可以直接编辑这段文字。")
        case .failed(let message): message
        case .finished: L10n.text("转录结果可以编辑、翻译或导出。")
        }
    }

    private var canStartSession: Bool {
        guard !catalog.isLoading else { return false }
        if case .microphone = session.source, !recognitionPreferences.engine.supportsRealtimeMicrophone {
            return false
        }
        if recognitionPreferences.engine == .apple {
            guard catalog.isSpeechAvailable else { return false }
        } else if !recognitionPreferences.selectedModelIsInstalled {
            return false
        }
        return true
    }

    private var preflightBlockedReason: String {
        if catalog.isLoading { return L10n.text("正在读取本地语言") }
        if case .microphone = session.source, !recognitionPreferences.engine.supportsRealtimeMicrophone {
            return L10n.text("当前引擎不支持麦克风实时转录")
        }
        if recognitionPreferences.engine == .apple, !catalog.isSpeechAvailable {
            return L10n.text("Apple 本地识别暂不可用")
        }
        if recognitionPreferences.engine.usesManagedModel, !recognitionPreferences.selectedModelIsInstalled {
            return L10n.text("需先下载识别模型")
        }
        return L10n.text("检查设置")
    }

    private func syncPendingConfiguration() {
        guard session.canStart else { return }
        if case .microphone = session.source, !recognitionPreferences.engine.supportsRealtimeMicrophone {
            recognitionPreferences.chooseEngine(.apple)
        }
        let translationConfiguration = preflightTranslationEnabled
            ? TranslationConfiguration(provider: translationPreferences.provider, targetLanguage: translationPreferences.targetLanguage)
            : nil
        session.configure(
            locale: catalog.selectedLocale,
            configuration: recognitionPreferences.configuration,
            translationConfiguration: translationConfiguration
        )
    }

    private func handleTranslationTargetChange(_ targetLanguage: TranslationTargetLanguage) {
        syncPendingConfiguration()
        guard session.phase == .finished else { return }
        guard session.translationConfiguration != nil || !session.translatedText.isEmpty else { return }
        if targetLanguage.isEquivalent(to: session.locale) {
            session.clearTranslation(targetLanguage: targetLanguage, provider: translationPreferences.provider)
        } else if selectedTranslationProviderReady {
            session.translate(targetLanguage: targetLanguage, provider: translationPreferences.provider)
        } else {
            session.clearTranslation(targetLanguage: targetLanguage, provider: translationPreferences.provider)
        }
    }

    private func handleTranslationProviderChange(_ provider: TranslationProvider) {
        if provider == .nllb { nllbModelManager.refresh() }
        syncPendingConfiguration()
        guard session.phase == .finished else { return }
        guard session.translationConfiguration != nil || !session.translatedText.isEmpty else { return }
        if selectedTranslationTargetMatchesSource || !selectedTranslationProviderReady {
            session.clearTranslation(targetLanguage: translationPreferences.targetLanguage, provider: provider)
        } else {
            session.translate(targetLanguage: translationPreferences.targetLanguage, provider: provider)
        }
    }
}

private struct TranscriptStreamView: View {
    let segments: [TranscriptSegment]
    let totalCount: Int
    let isActive: Bool
    let animatedText: String?

    @State private var followsLatest = true
    @State private var isProgrammaticScroll = false
    @State private var lastAnimatedScrollAt = Date.distantPast
    private let bottomID = "transcript-stream-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if totalCount > segments.count {
                            Text("为保持长任务流畅，当前显示最近 \(segments.count) 个片段；完整内容仍会保存并导出。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 4)
                        }
                        if let animatedText {
                            Text(animatedText)
                                .font(.system(size: 19))
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("animated-transcript")
                        } else {
                            ForEach(segments) { segment in
                                Text(segment.text)
                                    .font(.system(size: 19))
                                    .lineSpacing(8)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(segment.id)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting, !isProgrammaticScroll {
                        followsLatest = false
                    }
                }
                .onAppear { scrollToLatest(proxy, animated: false) }
                .onChange(of: segments.last?.id) { _, _ in
                    guard followsLatest else { return }
                    scrollToLatest(proxy, animated: true)
                }
                .onChange(of: animatedText?.count) { _, _ in
                    guard followsLatest, Date().timeIntervalSince(lastAnimatedScrollAt) >= 0.12 else { return }
                    lastAnimatedScrollAt = Date()
                    scrollToLatest(proxy, animated: false)
                }

                if !followsLatest, isActive {
                    Button {
                        followsLatest = true
                        scrollToLatest(proxy, animated: true)
                    } label: {
                        Label("回到最新内容", systemImage: "arrow.down.to.line")
                    }
                    .primaryActionStyle()
                    .padding(18)
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        isProgrammaticScroll = true
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            isProgrammaticScroll = false
        }
    }
}

private struct PhaseIndicator: View {
    let phase: TranscriptionPhase

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16)).frame(width: 20, height: 20)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch phase {
        case .transcribing: .red
        case .paused: .orange
        case .finished: .green
        case .failed: .red
        default: .accentColor
        }
    }
}

private struct AudioLevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(Double(index) / 12 < level ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(height: 8 + CGFloat(index % 4) * 3)
            }
        }
        .animation(.linear(duration: 0.12), value: level)
    }
}

import SwiftUI

struct TranscriptionView: View {
    @Bindable var session: TranscriptionSessionModel
    @Bindable var catalog: LanguageCatalog
    @Bindable var recognitionPreferences: RecognitionPreferences
    @Bindable var translationPreferences: AppleTranslationPreferences
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

    var body: some View {
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
        .navigationTitle(session.source.title)
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
            Text(exportError ?? "未知错误")
        }
        .onAppear {
            nllbModelManager.refresh()
            syncPendingConfiguration()
        }
        .onChange(of: catalog.selectedLocaleIdentifier) { _, _ in syncPendingConfiguration() }
        .onChange(of: recognitionPreferences.configuration) { _, _ in syncPendingConfiguration() }
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
                ProgressView().controlSize(.small)
                Text("\(activeTranslationProviderTitle)正在翻译")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            ForEach(catalog.languages) { language in
                Text(language.displayName).tag(language.id)
            }
        }
        .frame(minWidth: 180, maxWidth: 260)
        .disabled(catalog.isLoading)
    }

    private var computePreferenceHint: String {
        switch recognitionPreferences.engine {
        case .apple:
            "Apple 框架自行管理计算单元。"
        case .whisper:
            "当前 GGML 模型支持 Metal/CPU；没有 Core ML encoder 时不会使用 ANE。"
        case .senseVoice, .parakeet:
            "自动按 Core ML（优先 ANE）→ CPU 回退；实际计算单元由系统决定。"
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
                "\(model.title) · \(model.sizeLabel)\(recognitionPreferences.installedModels.contains(model) ? " · 已下载" : "")",
                systemImage: model.engine.symbol
            )
        }
    }

    private var preflightModelTitle: String {
        "\(recognitionPreferences.selectedManagedModel.title)\(recognitionPreferences.selectedModelIsInstalled ? " · 已下载" : " · 未下载")"
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
                    editStatus = "已设置节点 A"
                }
                .disabled(TranscriptTextEditing.validRange(editorSelection, in: session.transcriptText) == nil)

                Button("设为节点 B") {
                    secondEditNode = editorSelection
                    editStatus = "已设置节点 B"
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
        if editorSelection.length > 0 { return "已选择 \(editorSelection.length) 个字符" }
        return "光标位置 \(editorSelection.location)"
    }

    private func findNext() {
        guard let found = TranscriptTextEditing.find(searchText, in: session.transcriptText, after: editorSelection) else {
            editStatus = "未找到“\(searchText)”"
            return
        }
        editorSelection = found
        editStatus = "已找到"
    }

    private func applyEdit(_ result: (String, NSRange)?) {
        guard let (text, selection) = result else {
            editStatus = "无法执行此操作"
            return
        }
        session.transcriptText = text
        editorSelection = selection
        firstEditNode = nil
        secondEditNode = nil
        editStatus = "已修改"
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
            if translationPreferences.provider == .nllb, !isNLLBTranslationReady {
                nllbModelDownloadAction
            }
            Button(session.translatedText.isEmpty ? "生成译文" : "重新翻译", systemImage: "sparkles") {
                session.translate(
                    targetLanguage: translationPreferences.targetLanguage,
                    provider: translationPreferences.provider
                )
            }
            .buttonStyle(.borderedProminent)
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
            ProgressView().controlSize(.small)
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
            Label("NLLB 运行时不可用", systemImage: "exclamationmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            switch nllbModelManager.state {
            case .idle:
                if nllbModelManager.isInstalled {
                    Label("NLLB 模型已安装", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("NLLB 模型未安装 · \(NLLBModelStore.sizeLabel)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("下载 NLLB · \(progress.formatted(.percent.precision(.fractionLength(0))))")
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
                Button("开始转录", systemImage: "record.circle") {
                    syncPendingConfiguration()
                    Task { await session.start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStartSession)
            } else if session.canPause {
                Button("暂停", systemImage: "pause.fill") { session.pause() }
                    .keyboardShortcut(.space, modifiers: [])
            } else if session.canResume {
                Button("继续", systemImage: "play.fill") { Task { await session.resume() } }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }

            if session.canStop {
                Button("完成", systemImage: "stop.fill") { Task { await session.stop() } }
            }

            if session.phase == .finished {
                Button("重新开始", systemImage: "arrow.counterclockwise") {
                    isConfirmingRestart = true
                }
                Button("导出转录", systemImage: "square.and.arrow.up") { isShowingExport = true }
                    .buttonStyle(.borderedProminent)
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
            Section("转录") {
                LabeledContent("来源") {
                    Label(session.source.title, systemImage: session.source.symbol)
                        .lineLimit(1)
                }
                LabeledContent("语言", value: session.languageName)
                if session.isImportedTranscript {
                    LabeledContent("类型", value: "导入稿件")
                } else {
                    LabeledContent("引擎", value: session.configuration.displayName)
                }
                if !session.isImportedTranscript, let status = session.computeBackendStatus {
                    LabeledContent("计算后端", value: status.detail)
                    if let fallback = status.fallbackReason {
                        Text(fallback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("时长", value: session.elapsed.formattedDuration)
                LabeledContent("文字") {
                    Text("\(session.transcriptText.count) 字符")
                        .monospacedDigit()
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
                        ProgressView("正在本地翻译…")
                    } else if !session.translatedText.isEmpty {
                        Label("译文已生成并加入恢复快照", systemImage: "checkmark.circle.fill")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
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
                    .buttonStyle(.borderedProminent)
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
        copyStatus = "已复制"
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyStatus == "已复制" { copyStatus = nil }
        }
    }

    private var defaultTitle: String {
        switch session.source {
        case .microphone: "麦克风转录"
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .recovered(let title): title
        }
    }

    private var defaultFilename: String { "\(defaultTitle).\(exportFormat.fileExtension)" }

    private var placeholderTitle: String {
        switch session.phase {
        case .preparing: "选择设置，然后开始转录"
        case .failed: "还没有可显示的文字"
        default: "识别到的文字会显示在这里"
        }
    }

    private var placeholderDetail: String {
        switch session.phase {
        case .preparing: "开始后会锁定当前语言、识别引擎和模型。"
        case .loadingModel, .preparingAudio, .transcribing, .finishing: session.activityDetail
        case .paused: "已暂停。你现在可以直接编辑这段文字。"
        case .failed(let message): message
        case .finished: "转录结果可以编辑、翻译或导出。"
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
        if catalog.isLoading { return "正在读取本地语言" }
        if case .microphone = session.source, !recognitionPreferences.engine.supportsRealtimeMicrophone {
            return "当前引擎不支持麦克风实时转录"
        }
        if recognitionPreferences.engine == .apple, !catalog.isSpeechAvailable {
            return "Apple 本地识别暂不可用"
        }
        if recognitionPreferences.engine.usesManagedModel, !recognitionPreferences.selectedModelIsInstalled {
            return "需先下载识别模型"
        }
        return "检查设置"
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
                    .buttonStyle(.borderedProminent)
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

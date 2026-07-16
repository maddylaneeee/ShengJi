import SwiftUI

struct StartView: View {
    @Bindable var catalog: LanguageCatalog
    @Bindable var preferences: RecognitionPreferences
    @Bindable var liveCaptions: LiveCaptionController
    let recoverySnapshot: RecoverySnapshot?
    let startMicrophone: () -> Void
    let chooseFile: () -> Void
    let chooseTranscript: () -> Void
    let restoreRecovery: () -> Void
    let clearRecovery: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 18)
                hero
                if let recoverySnapshot {
                    recoveryCard(recoverySnapshot)
                }
                enginePanel
                importAndTranslationRow
                actionGrid
                liveCaptionCard
                privacyNote
                Spacer(minLength: 18)
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("声迹")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("选择文件", systemImage: "plus") { chooseFile() }
                    .disabled(!canChooseFile)
                    .mainMenuHoverFeedback(isEnabled: canChooseFile)
            }
        }
        .onAppear { syncLiveCaptionLanguageSelection() }
        .onChange(of: catalog.isLoading) { _, _ in syncLiveCaptionLanguageSelection() }
    }

    private func recoveryCard(_ snapshot: RecoverySnapshot) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("可以恢复上次转录")
                    .font(.headline)
                Text("\(snapshot.sourceTitle) · \(snapshot.configuration.displayName) · \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snapshot.shortPreview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Button("清除") { clearRecovery() }
                .controlSize(.small)
                .mainMenuHoverFeedback()
            Button("恢复") { restoreRecovery() }
                .buttonStyle(.borderedProminent)
                .mainMenuHoverFeedback()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 32, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("声迹")
                    .font(.title.weight(.semibold))
                Text("麦克风、音频和视频转文字；识别与翻译在这台 Mac 上完成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var actionGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(spacing: 12) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        StartActionButton(
            title: L10n.text("麦克风转录"),
            detail: L10n.text("进入后选择设置并手动开始"),
            symbol: "mic.fill",
            isEnabled: canStartMicrophone,
            action: startMicrophone
        )
        StartActionButton(
            title: L10n.text("音频或视频文件"),
            detail: L10n.text("导入后仍可切换模型与功能"),
            symbol: "folder.badge.plus",
            isEnabled: canChooseFile,
            action: chooseFile
        )
    }

    private var liveCaptionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("实时字幕悬浮窗")
                        .font(.headline)
                    Text(liveCaptions.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if liveCaptions.isRunning {
                    Button("停止字幕", systemImage: "stop.fill") {
                        Task { await liveCaptions.stop() }
                    }
                    .buttonStyle(.bordered)
                    .mainMenuHoverFeedback()
                } else {
                    Button("开启字幕", systemImage: "captions.bubble") {
                        Task {
                            await liveCaptions.start(locale: liveCaptionLocale)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartLiveCaptions)
                    .mainMenuHoverFeedback(isEnabled: canStartLiveCaptions)
                }
            }

            liveCaptionControls

            if liveCaptions.inputMode != .microphone {
                Label("采集 Mac 正在播放的声音时，macOS 可能会请求屏幕与系统音频录制权限。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var liveCaptionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    liveCaptionLanguageControl
                        .frame(width: 250, alignment: .leading)
                    liveCaptionInputControl
                        .frame(minWidth: 410, maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 14) {
                    liveCaptionLanguageControl
                    liveCaptionInputControl
                }
            }

            Label("实时字幕翻译已暂时关闭；转录完成后的翻译仍可在结果页使用。", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var liveCaptionLanguageControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("字幕语言")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("字幕语言", selection: $liveCaptions.localeIdentifier) {
                ForEach(catalog.languages) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(catalog.isLoading || liveCaptions.isRunning)
            .mainMenuHoverFeedback(isEnabled: !catalog.isLoading && !liveCaptions.isRunning)
        }
    }

    private var liveCaptionInputControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("声音来源")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("声音来源", selection: $liveCaptions.inputMode) {
                ForEach(LiveCaptionInputMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .disabled(liveCaptions.isRunning)
            .mainMenuHoverFeedback(isEnabled: !liveCaptions.isRunning)
        }
    }

    private var canStartMicrophone: Bool {
        !catalog.isLoading
            && preferences.supportsRealtimeMicrophone
            && (preferences.engine != .apple || catalog.isSpeechAvailable)
    }

    private var canStartLiveCaptions: Bool {
        !catalog.isLoading && catalog.isSpeechAvailable && liveCaptionSelectedLanguageExists
    }

    private var liveCaptionSelectedLanguageExists: Bool {
        catalog.languages.contains { $0.id == liveCaptions.localeIdentifier }
    }

    private var liveCaptionLocale: Locale {
        catalog.languages.first(where: { $0.id == liveCaptions.localeIdentifier })?.locale
            ?? catalog.selectedLocale
    }

    private var canChooseFile: Bool {
        !catalog.isLoading
            && preferences.isReady
            && (preferences.engine != .apple || catalog.isSpeechAvailable)
    }

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("转录后翻译", systemImage: "translate")
                        .font(.headline)
                    Text("结果页默认使用 Apple 翻译，也可切换到本机 NLLB。实时字幕翻译暂时关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "apple.logo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Apple 默认")
            }

            HStack(spacing: 12) {
                Label("首次使用某个语言组合时，macOS 可能下载语言资源。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Label("本机处理 · 可选 NLLB", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var importAndTranslationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            importPanel.frame(maxWidth: .infinity)
            translationPanel.frame(maxWidth: .infinity)
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("导入稿件", systemImage: "doc.badge.plus")
                        .font(.headline)
                    Text("打开 SRT、VTT、TXT、Markdown 或声迹 JSON。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入…", systemImage: "square.and.arrow.down") { chooseTranscript() }
                    .buttonStyle(.borderedProminent)
                    .mainMenuHoverFeedback()
            }

            Label("可直接编辑，也可保留现有文字并继续麦克风转录。", systemImage: "text.append")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    enginePanelTitle
                    Spacer(minLength: 12)
                    recognitionSourcePicker
                    if preferences.engine.usesManagedModel { thirdPartyModelMenu }
                }
                VStack(alignment: .leading, spacing: 10) {
                    enginePanelTitle
                    recognitionSourcePicker
                    if preferences.engine.usesManagedModel { thirdPartyModelMenu }
                }
            }

            if preferences.engine.usesManagedModel {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        modelStatus
                        modelManagementMenu
                        Spacer()
                        engineBadge
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        modelStatus
                        HStack { modelManagementMenu; engineBadge }
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var enginePanelTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("识别模型", systemImage: "cpu")
                .font(.headline)
            Text("默认使用 Apple Speech Framework；第三方模型仅在手动选择后启用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recognitionSourcePicker: some View {
        Picker("模型来源", selection: Binding(
            get: { preferences.engine != .apple },
            set: { $0 ? preferences.chooseThirdParty() : preferences.chooseDefault() }
        )) {
            Label("默认", systemImage: "apple.logo").tag(false)
            Label("第三方模型", systemImage: "shippingbox").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 270)
        .labelsHidden()
        .mainMenuHoverFeedback()
    }

    private var thirdPartyModelMenu: some View {
        Menu {
            Section("Whisper · Metal") {
                ForEach(WhisperModel.allCases.map(ManagedSpeechModel.whisper)) { model in
                    thirdPartyModelButton(model)
                }
            }
            Section("SenseVoice") {
                ForEach(SenseVoiceModel.allCases.map(ManagedSpeechModel.senseVoice)) { model in
                    thirdPartyModelButton(model)
                }
            }
            Section("NVIDIA Parakeet") {
                ForEach(ParakeetModel.allCases.map(ManagedSpeechModel.parakeet)) { model in
                    thirdPartyModelButton(model)
                }
            }
        } label: {
            Label(thirdPartyMenuTitle, systemImage: preferences.engine.usesManagedModel ? preferences.engine.symbol : "shippingbox")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .menuStyle(.button)
        .disabled(preferences.downloadState.isDownloading)
        .mainMenuHoverFeedback(isEnabled: !preferences.downloadState.isDownloading)
    }

    private func thirdPartyModelButton(_ model: ManagedSpeechModel) -> some View {
        Button {
            preferences.chooseModel(model)
        } label: {
            HStack {
                Label(modelMenuLabel(for: model), systemImage: model.engine.symbol)
                if preferences.selectedManagedModel == model {
                    Text("✓")
                }
            }
        }
    }

    private var thirdPartyMenuTitle: String {
        preferences.engine.usesManagedModel
            ? "\(preferences.selectedManagedModel.title)\(preferences.selectedModelIsInstalled ? L10n.text(" · 已下载") : L10n.text(" · 未下载"))"
            : L10n.text("第三方模型…")
    }

    private func modelMenuLabel(for model: ManagedSpeechModel) -> String {
        "\(model.title) · \(model.sizeLabel)\(preferences.installedModels.contains(model) ? L10n.text(" · 已下载") : "")"
    }

    private var installedManagedModels: [ManagedSpeechModel] {
        preferences.installedModels.sorted {
            if $0.engine.rawValue == $1.engine.rawValue {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.engine.rawValue < $1.engine.rawValue
        }
    }

    private var modelManagementMenu: some View {
        Menu {
            if installedManagedModels.isEmpty {
                Button("暂无已安装模型") {}
                    .disabled(true)
            } else {
                ForEach(installedManagedModels) { model in
                    Button(role: .destructive) {
                        try? preferences.remove(model)
                    } label: {
                        Label("卸载 \(model.id)", systemImage: "trash")
                    }
                }
            }
        } label: {
            Label("模型管理", systemImage: "externaldrive.badge.minus")
        }
        .controlSize(.small)
        .disabled(preferences.downloadState.isDownloading)
        .mainMenuHoverFeedback(isEnabled: !preferences.downloadState.isDownloading)
    }

    @ViewBuilder
    private var modelStatus: some View {
        let selected = preferences.selectedManagedModel
        switch preferences.downloadState {
        case .idle:
            if preferences.installedModels.contains(selected) {
                HStack(spacing: 8) {
                    Label("\(selected.title) 已可离线使用", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("卸载") { try? preferences.remove(selected) }
                        .controlSize(.small)
                        .mainMenuHoverFeedback()
                }
            } else {
                Label("选择后自动下载 \(selected.sizeLabel)", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        case .downloading(let model, let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(width: 150)
                Text("正在下载 \(model.title) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.callout)
                    .monospacedDigit()
                Button("取消") { preferences.cancelDownload() }
                    .controlSize(.small)
                    .mainMenuHoverFeedback()
            }
        case .failed(let model, let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(1)
                Button("重试") { preferences.download(model) }
                    .controlSize(.small)
                    .mainMenuHoverFeedback()
            }
        }
    }

    @ViewBuilder
    private var engineBadge: some View {
        switch preferences.engine {
        case .whisper:
            Label("Metal GPU", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .senseVoice, .parakeet:
            Label("文件转录 · CLI", systemImage: "terminal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .apple:
            EmptyView()
        }
    }

    private var privacyNote: some View {
        Label {
            Text("实时字幕识别在本机完成；首次使用相应语言时，macOS 可能需要下载语言资源。")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func syncLiveCaptionLanguageSelection() {
        guard !catalog.isLoading, !catalog.languages.isEmpty else { return }
        if !liveCaptionSelectedLanguageExists {
            liveCaptions.localeIdentifier = catalog.languages.first(where: \.isInstalled)?.id
                ?? catalog.selectedLocaleIdentifier
        }
    }
}

private struct StartActionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .padding(18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering && isEnabled ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary))
                .shadow(color: isHovering && isEnabled ? Color.accentColor.opacity(0.12) : .clear, radius: 8, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering && isEnabled ? Color.accentColor.opacity(0.40) : Color.primary.opacity(0.08))
        }
        .scaleEffect(isHovering && isEnabled && !reduceMotion ? 1.012 : 1)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private extension View {
    func mainMenuHoverFeedback(isEnabled: Bool = true) -> some View {
        modifier(MainMenuHoverFeedback(isEnabled: isEnabled))
    }
}

private struct MainMenuHoverFeedback: ViewModifier {
    let isEnabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.accentColor.opacity(0.10) : .clear)
                    .padding(-4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovering && isEnabled ? Color.accentColor.opacity(0.28) : .clear)
                    .padding(-4)
            }
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var updateController: AppUpdateController
    @Bindable var presentationPreferences: AppPresentationPreferences
    @Bindable var aiPromptPreferences: AIPromptPreferences
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var interfaceLocale
    @State private var permissionCenter = PermissionCenter()
    @State private var isConfirmingInstall = false
    @State private var installError: String?
    @State private var settingsError: String?
    @State private var isConfirmingUninstall = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var gemmaModelManager = GemmaModelManager.shared
    @State private var aiServices = AIServicePreferences.shared
    @State private var isShowingAIConfiguration = false
    @State private var isShowingPromptEditor = false
    @State private var isConfirmingGemma = false
    @AppStorage("EnableGemma") private var enableGemma = !GemmaHardwareSupport.requiresOptIn
    @AppStorage("EnableGemmaE4B") private var enableGemmaE4B = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            permissionsTab
                .tabItem {
                    Label("权限", systemImage: "hand.raised")
                }

            modelsTab
                .tabItem {
                    Label("模型", systemImage: "memorychip")
                }

            updatesTab
                .tabItem {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                }

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 560)
        .sheet(isPresented: $isShowingAIConfiguration) {
            AIServiceConfigurationView(preferences: aiServices)
                .environment(\.locale, presentationPreferences.language.locale)
        }
        .sheet(isPresented: $isShowingPromptEditor) {
            NavigationStack {
                AIPromptEditorView(preferences: aiPromptPreferences)
            }
            // A presented macOS sheet has its own hosting environment.
            .environment(\.locale, presentationPreferences.language.locale)
        }
        .alert("在低内存设备上启用 Gemma？", isPresented: $isConfirmingGemma) {
            Button("取消", role: .cancel) {}
            Button("仍然启用") { enableGemma = true }
        } message: {
            Text("Gemma 会占用大量内存，可能导致系统卡顿或内存压力过高。关闭其他大型应用后再使用；可随时在此关闭。")
        }
        .alert("安装更新？", isPresented: $isConfirmingInstall) {
            Button("稍后", role: .cancel) {}
            Button("安装并重新打开") {
                do {
                    try updateController.installAndRelaunch()
                } catch {
                    installError = error.localizedDescription
                }
            }
        } message: {
            Text("声迹会退出，替换当前应用，然后自动重新打开。")
        }
        .alert("无法安装更新", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("好") { installError = nil }
        } message: {
            Text(installError ?? L10n.text("未知错误"))
        }
        .alert("卸载声迹？", isPresented: $isConfirmingUninstall) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive) { uninstallApplication() }
        } message: {
            Text("应用会被移到废纸篓并退出。已下载的模型和转录恢复数据将保留。")
        }
        .alert("无法更改设置", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("好") { settingsError = nil }
        } message: {
            Text(settingsError ?? L10n.text("未知错误"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCenter.refresh()
        }
        .onChange(of: presentationPreferences.language) { _, language in
            ApplicationMenuLocalizer.apply(language)
        }
    }

    private var generalTab: some View {
        settingsPage(notes: [
            "语音识别、翻译和导出均在本机完成",
            "识别音频不会上传。选择云端 AI 后，任务文字稿会发送给所选服务；更新和模型下载访问对应官方来源。",
        ]) {
            Form {
                Section("外观与语言") {
                    Picker("程序语言", selection: $presentationPreferences.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .id("language-\(presentationPreferences.language.rawValue)")
                    .help("语言和外观更改会立即应用到声迹的所有窗口。")
                    Picker("外观", selection: $presentationPreferences.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .id("appearance-\(presentationPreferences.language.rawValue)")
                    .help("语言和外观更改会立即应用到声迹的所有窗口。")
                }

                Section("应用") {
                    Toggle("登录时自动启动声迹", isOn: Binding(
                        get: { launchesAtLogin },
                        set: updateLaunchAtLogin
                    ))
                    Button("在 Finder 中显示应用", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    Button("卸载声迹…", systemImage: "trash", role: .destructive) {
                        isConfirmingUninstall = true
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var permissionsTab: some View {
        settingsPage(notes: [
            "打开或导出时由你选择文件和保存位置",
            "伴随导出时选择保存文件夹，文字稿和音频保存到该文件夹。",
        ]) {
            Form {
                Section("录音与识别") {
                    permissionRow(
                        title: "麦克风",
                        detail: "用于麦克风转录和麦克风实时字幕。",
                        symbol: "mic",
                        state: permissionCenter.microphone,
                        request: { Task { await permissionCenter.requestMicrophone() } },
                        openSettings: { permissionCenter.openSystemSettings(for: .microphone) }
                    )
                    permissionRow(
                        title: "语音识别",
                        detail: "用于 Apple 本地识别和实时字幕。",
                        symbol: "waveform",
                        state: permissionCenter.speechRecognition,
                        request: { Task { await permissionCenter.requestSpeechRecognition() } },
                        openSettings: { permissionCenter.openSystemSettings(for: .speechRecognition) }
                    )
                    permissionRow(
                        title: "屏幕与系统音频录制",
                        detail: "仅在采集 Mac 正在播放的声音时使用。声迹不会录制屏幕画面。",
                        symbol: "speaker.wave.2",
                        state: permissionCenter.screenRecording,
                        request: { permissionCenter.requestScreenRecording() },
                        openSettings: { permissionCenter.openSystemSettings(for: .screenRecording) }
                    )
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { permissionCenter.refresh() }
    }

    private var modelsTab: some View {
        settingsPage(notes: modelsPageNotes) {
            Form {
                Section("AI 服务源") {
                    Toggle("使用自定义ai服务源", isOn: Binding(
                        get: { aiServices.isEnabled },
                        set: { enabled in
                            aiServices.setEnabled(enabled)
                            if enabled { isShowingAIConfiguration = true }
                        }
                    ))
                    .help(aiServices.privacyDescription)
                    if aiServices.isEnabled {
                        LabeledContent("当前服务", value: aiServices.provider.title)
                        LabeledContent("模型 ID", value: aiServices.configuration.modelID)
                        Text(aiServices.readinessError ?? L10n.text("已配置；可在配置菜单测试连接。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("配置…") { isShowingAIConfiguration = true }
                        Text("正在使用自定义服务源，不会下载或加载 Gemma。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Gemma 4") {
                    Toggle("启用 Gemma AI 功能", isOn: Binding(
                        get: { enableGemma },
                        set: { enabled in
                            if enabled && GemmaHardwareSupport.requiresOptIn {
                                isConfirmingGemma = true
                            } else {
                                enableGemma = enabled
                            }
                        }
                    ))
                    .disabled(aiServices.isEnabled)
                    .help("8 GB 及以下默认关闭，需手动确认启用。模型仅在点击 AI 功能后加载，任务结束后释放内存。")
                    if !aiServices.isEnabled && !GemmaHardwareSupport.isSupported {
                        Label(GemmaHardwareSupport.unsupportedReason, systemImage: "memorychip.fill")
                            .foregroundStyle(.red)
                    }
                    Toggle("启用 Gemma 4 E4B 选项", isOn: $enableGemmaE4B)
                        .disabled(aiServices.isEnabled || !GemmaHardwareSupport.isSupported)
                        .help("E2B 是默认模型。E4B 占用更多统一内存，仅在开启后出现在 AI 优化的模型列表中。")

                    gemmaModelRow(.e2b)
                    if enableGemmaE4B { gemmaModelRow(.e4b) }
                }

                if !NLLBHardwareSupport.isSupported {
                    Section("离线翻译") {
                        Label(NLLBHardwareSupport.unsupportedReason, systemImage: "memorychip.fill")
                    }
                }

                Section("AI 提示词") {
                    Button("编辑提示词…", systemImage: "square.and.pencil") {
                        isShowingPromptEditor = true
                    }
                    .help("仅开放安全的附加指令；模型协议和校验规则保持受保护。")
                }

                Section("来源") {
                    LabeledContent("模型", value: "Google Gemma 4 IT · Apache-2.0")
                    LabeledContent("运行环境", value: "llama.cpp b10333 · MIT")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { gemmaModelManager.refresh() }
    }

    private var modelsPageNotes: [String] {
        var notes = ["用于已完成转录的纠错、润色或总结"]
        if !aiServices.isEnabled {
            notes.append("模型由 llama.cpp 通过 Metal 在本机运行。稿件不会上传；开始加载前会释放声迹持有的识别和 NLLB 翻译运行环境，任务结束后也会退出 Gemma helper。")
        }
        notes.append("AI 输出可能出错。纠错结果会按片段 ID、数量、非空、长度、数字、链接、邮箱和时间表达进行校验；未通过的片段保留原文。重要内容仍需人工复核。")
        notes.append("NLLB 本机翻译模型需要至少 4 GB 内存；容量判断允许小幅误差。Apple 翻译仍可使用。")
        return notes
    }

    @ViewBuilder
    private func gemmaModelRow(_ model: GemmaModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch gemmaModelManager.state {
            case .downloading(let active, let progress) where active == model:
                ProgressView(value: progress)
                    .frame(width: 100)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                Button("取消") { gemmaModelManager.cancelDownload() }
            case .failed(let active, _) where active == model:
                Button("重试") { gemmaModelManager.download(model) }.disabled(aiServices.isEnabled)
            default:
                if gemmaModelManager.installedModels.contains(model) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("移除", role: .destructive) {
                        try? GemmaModelStore.remove(model)
                        gemmaModelManager.refresh()
                    }
                } else {
                    Button("下载", systemImage: "arrow.down.circle") {
                        gemmaModelManager.download(model)
                    }
                    .disabled(aiServices.isEnabled || gemmaModelManager.state.isDownloading || !GemmaHardwareSupport.isSupported)
                }
            }
        }
    }

    private var updatesTab: some View {
        Form {
            Section("自动更新") {
                Toggle("自动检查并下载更新", isOn: Binding(
                    get: { updateController.automaticUpdatesEnabled },
                    set: { updateController.setAutomaticUpdatesEnabled($0) }
                ))
                .help("开启后，声迹会在启动时及每隔六小时检查并下载更新；安装和重新打开应用前仍会征求你的确认。")
            }

            Section("当前版本") {
                LabeledContent("版本", value: "\(AppInfo.version) (\(AppInfo.build))")
                    .help("更新由声迹的官方 GitHub Release 提供。")
            }

            Section("检查更新") {
                HStack(spacing: 12) {
                    statusView
                    Spacer()
                    Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await updateController.checkForUpdates() }
                    }
                    .disabled(isBusy)
                }

                updateAction
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 0) {
            Form {
                Section("声迹") {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 52, height: 52)
                            .cornerRadius(10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("声迹")
                                .font(.title3.weight(.semibold))
                            Text("版本 \(AppInfo.version) (\(AppInfo.build))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("开源依赖与库") {
                    ForEach(AppInfo.dependencies) { dependency in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dependency.name)
                                    .font(.callout.weight(.medium))
                                Text(dependency.role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(dependency.license)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Button("打开", systemImage: "safari") {
                                openURL(dependency.url)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("打开 \(dependency.name)")
                        }
                    }
                }

                Section("相关文档") {
                    webButton("使用说明", url: AppInfo.documentationURL, symbol: "book")
                    webButton("GitHub 页面", url: AppInfo.githubURL, symbol: "chevron.left.forwardslash.chevron.right")
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
    }

    /// Wraps a settings tab and moves standalone explanatory notes into a hover-only info icon at the bottom.
    private func settingsPage<Content: View>(notes: [String], @ViewBuilder content: () -> Content) -> some View {
        let tooltip = notes.map { L10n.text($0) }.joined(separator: "\n\n")
        return VStack(spacing: 6) {
            content()
            HStack {
                Spacer()
                SettingsNotesIcon(text: tooltip)
                    .id("settings-notes-\(interfaceLocale.identifier)")
            }
            .padding(.horizontal, 20)
        }
        .padding(20)
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        state: AppPermissionState,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title))
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 12)
            Label(state.title, systemImage: state.symbol)
                .foregroundStyle(state == .authorized ? .green : .secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("\(L10n.text(title))：\(state.title)")
            if state.canRequest {
                Button("请求权限", action: request)
            } else if state.shouldOpenSettings {
                Button("打开系统设置", action: openSettings)
            }
        }
        .help(L10n.text(detail))
        .accessibilityElement(children: .contain)
        .accessibilityHint(L10n.text(detail))
    }

    @ViewBuilder
    private var statusView: some View {
        switch updateController.state {
        case .checking:
            ProgressView()
                .controlSize(.small)
            Text(updateController.statusText)
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 120)
            Text(updateController.statusText)
                .foregroundStyle(.secondary)
        case .available, .ready:
            Label(updateController.statusText, systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label(updateController.statusText, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .upToDate:
            Label(updateController.statusText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .idle:
            Label(updateController.statusText, systemImage: "clock")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updateController.state {
        case .available:
            Button("下载更新", systemImage: "arrow.down.circle") {
                Task { await updateController.downloadAvailableUpdate() }
            }
            .primaryActionStyle()
        case .ready:
            Button("安装并重新打开", systemImage: "checkmark.circle") {
                isConfirmingInstall = true
            }
            .primaryActionStyle()
        case .failed:
            Button("重置状态") { updateController.reset() }
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch updateController.state {
        case .checking, .downloading: true
        default: false
        }
    }

    private func webButton(_ title: String, url: URL, symbol: String) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Label(L10n.text(title), systemImage: symbol)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = SMAppService.mainApp.status
            launchesAtLogin = status == .enabled
            if enabled && status == .requiresApproval {
                settingsError = "请在“系统设置 > 通用 > 登录项与扩展”中允许声迹登录时启动。"
            }
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = error.localizedDescription
        }
    }

    private func uninstallApplication() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { _, error in
            Task { @MainActor in
                if let error {
                    settingsError = error.localizedDescription
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Info icon whose notes appear after a short hover, instead of waiting for the system tooltip delay.
private struct SettingsNotesIcon: View {
    let text: String
    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .padding(4)
            .contentShape(Rectangle())
            .background(HoverTrackingView(onHoverChange: hoverChanged))
            .onDisappear {
                hoverTask?.cancel()
                isPresented = false
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 360, alignment: .leading)
                    .padding(14)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("更多说明")
            .accessibilityHint(text)
    }

    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        guard hovering else {
            isPresented = false
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            isPresented = true
        }
    }
}

/// AppKit tracking area that reports hover in any window state; SwiftUI `onHover` does not fire reliably in the Settings window.
private struct HoverTrackingView: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }

    final class TrackingNSView: NSView {
        var onHoverChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    }
}

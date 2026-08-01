import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var updateController: AppUpdateController
    @Bindable var presentationPreferences: AppPresentationPreferences
    @Environment(\.openURL) private var openURL
    @State private var permissionCenter = PermissionCenter()
    @State private var isConfirmingInstall = false
    @State private var installError: String?
    @State private var settingsError: String?
    @State private var isConfirmingUninstall = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

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
    }

    private var generalTab: some View {
        Form {
            Section("外观与语言") {
                Picker("程序语言", selection: $presentationPreferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .id("language-\(presentationPreferences.language.rawValue)")
                Picker("外观", selection: $presentationPreferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .id("appearance-\(presentationPreferences.language.rawValue)")
                Text("语言和外观更改会立即应用到声迹的所有窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("隐私") {
                Label("语音识别、翻译和导出均在本机完成", systemImage: "lock.shield")
                Text("检查更新时访问官方 GitHub Release；下载模型时访问对应模型仓库。音频和转录文本不会由声迹上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var permissionsTab: some View {
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

            Section("文件") {
                Label("打开或导出时由你选择文件和保存位置", systemImage: "folder.badge.questionmark")
                Text("声迹不会请求访问整个文件夹；macOS 只授予你所选项目所需的访问权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear { permissionCenter.refresh() }
    }

    private var updatesTab: some View {
        Form {
            Section("自动更新") {
                Toggle("自动检查并下载更新", isOn: Binding(
                    get: { updateController.automaticUpdatesEnabled },
                    set: { updateController.setAutomaticUpdatesEnabled($0) }
                ))
                Text("开启后，声迹会在启动时及每隔六小时检查并下载更新；安装和重新打开应用前仍会征求你的确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("当前版本") {
                LabeledContent("版本", value: "\(AppInfo.version) (\(AppInfo.build))")
                Text("更新由 ShengJi 的官方 GitHub Release 提供。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text(L10n.text(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityElement(children: .contain)
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

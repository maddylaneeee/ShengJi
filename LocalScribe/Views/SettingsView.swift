import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var updateController: AppUpdateController
    @Environment(\.openURL) private var openURL
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

            updatesTab
                .tabItem {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                }

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 620, height: 500)
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
            Text(installError ?? "未知错误")
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
            Text(settingsError ?? "未知错误")
        }
    }

    private var generalTab: some View {
        Form {
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
                Text("检查更新时访问设置中的更新地址；下载模型时访问对应模型仓库。音频和转录文本不会由声迹上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var updatesTab: some View {
        Form {
            Section("当前版本") {
                LabeledContent("版本", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("应用标识", value: AppInfo.bundleIdentifier)
            }

            Section("更新来源") {
                TextField("更新说明地址", text: $updateController.manifestURLString)
                    .textFieldStyle(.roundedBorder)
                Text("更新说明是一个 JSON manifest，包含版本号、下载地址和 SHA-256。")
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
                            Text(AppInfo.displayName)
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
                    webButton("验收记录", url: AppInfo.acceptanceURL, symbol: "checkmark.seal")
                    webButton("SherpaOnnx 构建说明", url: AppInfo.sherpaBuildURL, symbol: "wrench.and.screwdriver")
                    webButton("GitHub 页面", url: AppInfo.githubURL, symbol: "chevron.left.forwardslash.chevron.right")
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
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
            .buttonStyle(.borderedProminent)
        case .ready:
            Button("安装并重新打开", systemImage: "checkmark.circle") {
                isConfirmingInstall = true
            }
            .buttonStyle(.borderedProminent)
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
                Label(title, systemImage: symbol)
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SubtitleBurnOutputMode: String, CaseIterable, Identifiable {
    case copy
    case replaceOriginal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: L10n.text("创建副本")
        case .replaceOriginal: L10n.text("直接烧录到原视频")
        }
    }
}

/// Copy vs. replace original. The mode always starts at "copy" and is never persisted.
struct SubtitleBurnOutputPicker: View {
    @Binding var outputMode: SubtitleBurnOutputMode
    let videoInfo: SubtitleBurnVideoInfo?
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("输出方式", selection: $outputMode) {
                ForEach(SubtitleBurnOutputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isDisabled)
            if outputMode == .replaceOriginal, let videoInfo, !videoInfo.canReplaceOriginal {
                Label("这个视频的格式无法原样写回，请选择“创建副本”。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if outputMode == .replaceOriginal {
                Label("会覆盖原视频，且无法恢复。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("烧录完成后另存为新视频，原视频保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Start button, progress, result, and the save/confirm flow for one burn.
struct SubtitleBurnActionBar: View {
    let videoInfo: SubtitleBurnVideoInfo?
    let cues: [SubtitleCue]
    var blockedReason: String?
    @Bindable var job: SubtitleBurnJob
    let outputMode: SubtitleBurnOutputMode
    @Bindable var preferences: SubtitleBurnPreferences = .shared
    @State private var isConfirmingReplace = false

    var body: some View {
        content
            .frame(minHeight: 32)
            .alert("直接烧录到原视频？", isPresented: $isConfirmingReplace) {
                Button("取消", role: .cancel) {}
                Button("烧录并替换原视频", role: .destructive) { startBurn(.replaceOriginal) }
            } message: {
                Text("烧录成功后会用新视频替换原文件，原视频无法恢复。")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch job.state {
        case .running(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                Text(L10n.format("正在烧录 %lld%%", Int64((progress * 100).rounded())))
                    .font(.callout.monospacedDigit())
                    .fixedSize()
                Button("取消") { job.cancel() }
            }
        default:
            HStack(spacing: 10) {
                statusLabel
                Spacer(minLength: 8)
                Button("开始烧录", systemImage: "captions.bubble") { begin() }
                    .primaryActionStyle()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch job.state {
        case .finished(let url):
            HStack(spacing: 8) {
                Label("烧录完成：\(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
        case .cancelled:
            Label("已取消，原视频未被修改。", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        default:
            if let blockedReason {
                Label(blockedReason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private var canStart: Bool {
        guard blockedReason == nil, videoInfo != nil, !cues.isEmpty, !job.isRunning else { return false }
        if outputMode == .replaceOriginal, videoInfo?.canReplaceOriginal != true { return false }
        return true
    }

    private func begin() {
        switch outputMode {
        case .copy:
            guard let videoInfo else { return }
            let panel = NSSavePanel()
            panel.directoryURL = videoInfo.url.deletingLastPathComponent()
            panel.nameFieldStringValue = videoInfo.suggestedCopyName
            if let type = UTType(filenameExtension: videoInfo.outputExtension) { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            if destination.standardizedFileURL == videoInfo.url.standardizedFileURL {
                isConfirmingReplace = true
                return
            }
            startBurn(.copy(destination))
        case .replaceOriginal:
            isConfirmingReplace = true
        }
    }

    private func startBurn(_ output: SubtitleBurnOutput) {
        guard let videoInfo else { return }
        job.start(info: videoInfo, cues: cues, style: preferences.effectiveStyle, output: output)
    }
}

/// Always-visible style controls (font, size, position, background, shadow).
struct SubtitleStyleControls: View {
    @Bindable var preferences: SubtitleBurnPreferences
    var isDisabled = false
    @State private var families: [String] = []

    static let shadowPresets: [(name: String, color: SubtitleBurnColor)] = [
        ("黑色", .black),
        ("深灰", SubtitleBurnColor(red: 0.2, green: 0.2, blue: 0.2)),
        ("深蓝", SubtitleBurnColor(red: 0.05, green: 0.12, blue: 0.35)),
        ("深红", SubtitleBurnColor(red: 0.4, green: 0.04, blue: 0.04)),
        ("白色", SubtitleBurnColor(red: 1, green: 1, blue: 1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("字幕样式", systemImage: "paintpalette")
                    .font(.headline)
                Spacer()
                Button("恢复默认", systemImage: "arrow.counterclockwise") { preferences.resetToDefault() }
                    .controlSize(.small)
                    .disabled(preferences.style == .default || isDisabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow(alignment: .center) {
                    rowLabel("字体")
                    Picker("字体", selection: Binding(
                        get: { preferences.effectiveStyle.fontFamily ?? "" },
                        set: { preferences.style.fontFamily = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("系统字体").tag("")
                        Divider()
                        ForEach(families, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow(alignment: .center) {
                    rowLabel("字号")
                    slider($preferences.style.fontSizePercent, SubtitleBurnStyle.fontSizeRange, step: 0.5,
                           value: "\(preferences.style.fontSizePercent.formatted(.number.precision(.fractionLength(1))))%",
                           accessibility: "字号")
                }
                GridRow(alignment: .center) {
                    rowLabel("位置")
                    Picker("位置", selection: $preferences.style.position) {
                        ForEach(SubtitleBurnPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow(alignment: .center) {
                    rowLabel("边距")
                    slider($preferences.style.marginPercent, SubtitleBurnStyle.marginRange, step: 1,
                           value: "\(Int(preferences.style.marginPercent))%", accessibility: "边距")
                }
                GridRow(alignment: .center) {
                    rowLabel("背景")
                    HStack(spacing: 10) {
                        Toggle("显示背景", isOn: $preferences.style.backgroundEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        slider($preferences.style.backgroundOpacity, SubtitleBurnStyle.backgroundOpacityRange, step: 0.05,
                               value: "\(Int((preferences.style.backgroundOpacity * 100).rounded()))%", accessibility: "背景不透明度")
                            .disabled(!preferences.style.backgroundEnabled)
                    }
                }
                GridRow(alignment: .center) {
                    rowLabel("阴影")
                    HStack(spacing: 10) {
                        Toggle("显示阴影", isOn: $preferences.style.shadowEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        shadowSwatches
                            .disabled(!preferences.style.shadowEnabled)
                            .opacity(preferences.style.shadowEnabled ? 1 : 0.4)
                    }
                }
                GridRow(alignment: .center) {
                    rowLabel("阴影宽度")
                    slider($preferences.style.shadowWidth, SubtitleBurnStyle.shadowWidthRange, step: 1,
                           value: "\(Int(preferences.style.shadowWidth))", accessibility: "阴影宽度")
                        .disabled(!preferences.style.shadowEnabled)
                }
            }
            .disabled(isDisabled)
        }
        .onAppear {
            if families.isEmpty { families = SubtitleFontCatalog.families() }
        }
    }

    private func rowLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .fixedSize()
    }

    private var shadowSwatches: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.shadowPresets.enumerated()), id: \.offset) { _, preset in
                let selected = preferences.style.shadowColor == preset.color
                Button {
                    preferences.style.shadowColor = preset.color
                } label: {
                    Circle()
                        .fill(Color(nsColor: preset.color.nsColor))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                        .padding(2)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(preset.name))
                .accessibilityLabel(L10n.text(preset.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker("自定义阴影颜色", selection: Binding(
                get: { Color(nsColor: preferences.style.shadowColor.nsColor) },
                set: { preferences.style.shadowColor = SubtitleBurnColor(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help(Text("自定义阴影颜色"))
        }
    }

    private func slider(_ binding: Binding<Double>, _ range: ClosedRange<Double>, step: Double, value: String,
                        accessibility: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Slider(value: binding, in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(Text(accessibility))
                .accessibilityValue(value)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Renders the first cue over a real video frame (or a neutral canvas) with the current style.
struct SubtitlePreviewFrame: View {
    let videoInfo: SubtitleBurnVideoInfo?
    let cues: [SubtitleCue]
    let style: SubtitleBurnStyle
    @State private var image: CGImage?

    private var aspectRatio: CGFloat {
        guard let size = videoInfo?.size, size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    private var taskID: String {
        "\(videoInfo?.url.path ?? "")|\(cues.first?.text ?? "")|\(cues.count)|\(String(describing: style))"
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("字幕预览")
        .task(id: taskID) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            image = await renderPreview()
        }
    }

    private func renderPreview() async -> CGImage? {
        let sample = cues.first ?? SubtitleCue(startTime: 0, endTime: 1, text: L10n.text("字幕预览 Subtitle Preview"))
        let time = sample.startTime + min((sample.endTime - sample.startTime) / 2, 1)
        let previewCues = [SubtitleCue(startTime: sample.startTime, endTime: sample.endTime, text: sample.text)]
        if let videoInfo,
           let frame = try? await SubtitleBurner.previewImage(videoURL: videoInfo.url, cues: previewCues, style: style, at: time) {
            return frame
        }
        let size = videoInfo?.size ?? CGSize(width: 1280, height: 720)
        let canvas = CIImage(color: CIColor(red: 0.32, green: 0.38, blue: 0.46)).cropped(to: CGRect(origin: .zero, size: size))
        let output = SubtitleFrameCompositor(cues: previewCues, style: style).composite(canvas, at: time, renderSize: size)
        return CIContext().createCGImage(output, from: canvas.extent)
    }
}

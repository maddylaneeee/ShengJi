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

/// Output mode, style, preview, and progress for one burn. Shared by the
/// standalone page and the export sheet. The output mode always starts at
/// "copy" and is never persisted.
struct SubtitleBurnPanel: View {
    let videoInfo: SubtitleBurnVideoInfo?
    let cues: [SubtitleCue]
    var blockedReason: String?
    @Bindable var job: SubtitleBurnJob
    var previewMaxHeight: CGFloat = 260
    @Bindable var preferences: SubtitleBurnPreferences = .shared
    @State private var outputMode: SubtitleBurnOutputMode = .copy
    @State private var isConfirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            outputPicker
            SubtitleStyleDisclosure(preferences: preferences, videoInfo: videoInfo, cues: cues, previewMaxHeight: previewMaxHeight)
            Divider()
            actionRow
        }
        .alert("直接烧录到原视频？", isPresented: $isConfirmingReplace) {
            Button("取消", role: .cancel) {}
            Button("烧录并替换原视频", role: .destructive) { startBurn(.replaceOriginal) }
        } message: {
            Text("烧录成功后会用新视频替换原文件，原视频无法恢复。")
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("输出方式")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("输出方式", selection: $outputMode) {
                ForEach(SubtitleBurnOutputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(job.isRunning)
            if outputMode == .replaceOriginal, let videoInfo, !videoInfo.canReplaceOriginal {
                Label("这个视频的格式无法原样写回，请选择“创建副本”。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if outputMode == .replaceOriginal {
                Label("会覆盖原视频，且无法恢复。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch job.state {
        case .running(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 260)
                Text(L10n.format("正在烧录 %lld%%", Int64((progress * 100).rounded())))
                    .font(.callout.monospacedDigit())
                Spacer()
                Button("取消") { job.cancel() }
            }
        default:
            HStack(spacing: 10) {
                statusLabel
                Spacer(minLength: 8)
                Button("开始烧录", systemImage: "captions.bubble") { begin() }
                    .primaryActionStyle()
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

/// Collapsed-by-default style section with a live preview frame.
struct SubtitleStyleDisclosure: View {
    @Bindable var preferences: SubtitleBurnPreferences
    let videoInfo: SubtitleBurnVideoInfo?
    let cues: [SubtitleCue]
    var previewMaxHeight: CGFloat = 260
    @State private var isExpanded = false
    @State private var families: [String] = []

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                controls
                SubtitlePreviewFrame(videoInfo: videoInfo, cues: cues, style: preferences.effectiveStyle, maxHeight: previewMaxHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            Label("字幕样式", systemImage: "paintpalette")
                .font(.headline)
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded, families.isEmpty { families = SubtitleFontCatalog.families() }
        }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["LOCALSCRIBE_BURN_STYLE_EXPANDED"] == "1" { isExpanded = true }
        }
#endif
    }

    private var controls: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("字体").gridColumnAlignment(.trailing)
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
                .frame(maxWidth: 280, alignment: .leading)
            }
            GridRow {
                Text("字号")
                sliderRow(value: $preferences.style.fontSizePercent, range: SubtitleBurnStyle.fontSizeRange, step: 0.5,
                          label: "\(preferences.style.fontSizePercent.formatted(.number.precision(.fractionLength(1))))%",
                          accessibility: "字号")
            }
            GridRow {
                Text("位置")
                HStack(spacing: 12) {
                    Picker("位置", selection: $preferences.style.position) {
                        ForEach(SubtitleBurnPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text("边距")
                    sliderRow(value: $preferences.style.marginPercent, range: SubtitleBurnStyle.marginRange, step: 1,
                              label: "\(Int(preferences.style.marginPercent))%", accessibility: "边距")
                }
            }
            GridRow {
                Text("背景")
                HStack(spacing: 12) {
                    Toggle("显示背景", isOn: $preferences.style.backgroundEnabled)
                    sliderRow(value: $preferences.style.backgroundOpacity, range: SubtitleBurnStyle.backgroundOpacityRange, step: 0.05,
                              label: "\(Int((preferences.style.backgroundOpacity * 100).rounded()))%", accessibility: "背景不透明度")
                        .disabled(!preferences.style.backgroundEnabled)
                }
            }
            GridRow {
                Text("阴影")
                HStack(spacing: 12) {
                    ColorPicker("阴影颜色", selection: Binding(
                        get: { Color(nsColor: preferences.style.shadowColor.nsColor) },
                        set: { preferences.style.shadowColor = SubtitleBurnColor(NSColor($0)) }
                    ), supportsOpacity: false)
                    Text("宽度")
                    sliderRow(value: $preferences.style.shadowWidth, range: SubtitleBurnStyle.shadowWidthRange, step: 1,
                              label: "\(Int(preferences.style.shadowWidth))", accessibility: "阴影宽度")
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button("恢复默认", systemImage: "arrow.counterclockwise") { preferences.resetToDefault() }
                    .controlSize(.small)
                    .disabled(preferences.style == .default)
            }
        }
    }

    private func sliderRow(value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String, accessibility: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range, step: step)
                .frame(minWidth: 120, maxWidth: 200)
                .accessibilityLabel(Text(accessibility))
                .accessibilityValue(label)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }
}

/// Renders the first cue over a real video frame (or a neutral canvas) with the current style.
struct SubtitlePreviewFrame: View {
    let videoInfo: SubtitleBurnVideoInfo?
    let cues: [SubtitleCue]
    let style: SubtitleBurnStyle
    var maxHeight: CGFloat = 260
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
        .frame(maxWidth: 420, maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

import SwiftUI
import UniformTypeIdentifiers

/// The transcript currently shown in the result page, prepared for burning into its source video.
struct SubtitleBurnSessionSource: Equatable {
    let videoURL: URL
    let cues: [SubtitleCue]
    let isTranslation: Bool
    let approximateTimeline: Bool

    static func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

/// Full burn page: files and style on the left, a large live preview and the
/// start button on the right. Opened from the home screen (files can be chosen
/// or dropped) or from a finished video transcription (files are locked to the
/// session's video and the text currently shown).
struct SubtitleBurnView: View {
    var sessionSource: SubtitleBurnSessionSource?
    let close: () -> Void

    @State private var job = SubtitleBurnJob()
    @State private var outputMode: SubtitleBurnOutputMode = .copy
    @Bindable private var preferences: SubtitleBurnPreferences = .shared
    @State private var videoURL: URL?
    @State private var videoInfo: SubtitleBurnVideoInfo?
    @State private var videoError: String?
    @State private var isInspectingVideo = false
    @State private var subtitleURL: URL?
    @State private var subtitleDocument: SubtitleDocument?
    @State private var subtitleError: String?
    @State private var isLoadingSubtitles = false
    @State private var importerTarget: ImporterTarget = .video
    @State private var isShowingImporter = false
    @State private var dropTarget: ImporterTarget?

    private enum ImporterTarget {
        case video
        case subtitles

        var contentTypes: [UTType] {
            switch self {
            case .video:
                SubtitleBurner.videoContentTypes
            case .subtitles:
                SubtitleFileParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
                    + [.plainText, .text, .json, .xml]
            }
        }
    }

    init(sessionSource: SubtitleBurnSessionSource? = nil, close: @escaping () -> Void) {
        self.sessionSource = sessionSource
        self.close = close
    }

    private var isLocked: Bool { sessionSource != nil }
    private var cues: [SubtitleCue] { sessionSource?.cues ?? subtitleDocument?.cues ?? [] }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card { filesSection }
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("输出方式", systemImage: "square.and.arrow.down.on.square")
                                .font(.headline)
                            SubtitleBurnOutputPicker(outputMode: $outputMode, videoInfo: videoInfo, isDisabled: job.isRunning)
                        }
                    }
                    card { SubtitleStyleControls(preferences: preferences, isDisabled: job.isRunning) }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .frame(width: 400)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("预览", systemImage: "eye")
                        .font(.headline)
                    Spacer()
                    if let first = cues.first {
                        Text(L10n.format("预览第一条字幕 · %@", first.startTime.formattedDuration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SubtitlePreviewFrame(videoInfo: videoInfo, cues: cues, style: preferences.effectiveStyle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SubtitleBurnActionBar(videoInfo: videoInfo, cues: cues, blockedReason: blockedReason,
                                      job: job, outputMode: outputMode, preferences: preferences)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.text("烧录字幕"))
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: importerTarget.contentTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importerTarget {
            case .video: chooseVideo(url)
            case .subtitles: chooseSubtitles(url)
            }
        }
        .onAppear {
            if let sessionSource, videoURL == nil { chooseVideo(sessionSource.videoURL) }
#if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if !isLocked, videoURL == nil, let path = environment["LOCALSCRIBE_BURN_VIDEO"] { chooseVideo(URL(fileURLWithPath: path)) }
            if !isLocked, subtitleURL == nil, let path = environment["LOCALSCRIBE_BURN_SUBTITLES"] { chooseSubtitles(URL(fileURLWithPath: path)) }
            if environment["LOCALSCRIBE_OPEN_COLOR_PANEL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSColorPanel.shared.orderFront(nil) }
            }
#endif
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isLocked {
            ToolbarItem(placement: .primaryAction) {
                Button("回退到预览页面", systemImage: "arrow.uturn.backward") { close() }
                    .labelStyle(.titleAndIcon)
                    .disabled(job.isRunning)
                    .help(Text("回到转录结果，继续修改或导出"))
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button("返回", systemImage: "chevron.left") { close() }
                    .disabled(job.isRunning)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Files

    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sessionSource {
                Label("来自转录结果", systemImage: "lock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                videoRow
                lockedSubtitleRow(sessionSource)
            } else {
                videoRow
                subtitleRow
            }
        }
    }

    private var videoRow: some View {
        fileRow(
            target: .video,
            title: "视频文件",
            symbol: "film",
            fileName: videoURL?.lastPathComponent,
            emptyHint: "拖入视频，或点“选择…”",
            detail: {
                if isInspectingVideo {
                    Label("正在读取视频…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else if let videoError {
                    Label(videoError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if let videoInfo {
                    Label(videoInfo.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Text("MP4、MOV、M4V 等 macOS 可以播放的视频").foregroundStyle(.secondary)
                }
            }
        )
    }

    private var subtitleRow: some View {
        fileRow(
            target: .subtitles,
            title: "字幕文件",
            symbol: "captions.bubble",
            fileName: subtitleURL?.lastPathComponent,
            emptyHint: "拖入字幕，或点“选择…”",
            detail: {
                VStack(alignment: .leading, spacing: 3) {
                    if isLoadingSubtitles {
                        Label("正在检查字幕…", systemImage: "hourglass").foregroundStyle(.secondary)
                    } else if let subtitleError {
                        Label(subtitleError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else if let subtitleDocument {
                        Label(subtitleSummary(subtitleDocument), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        ForEach(subtitleDocument.warnings(videoDuration: videoInfo?.duration), id: \.message) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } else {
                        Text("SRT、WebVTT、声迹 JSON、ASS/SSA、SBV、TTML/DFXP").foregroundStyle(.secondary)
                    }
                }
            }
        )
    }

    private func lockedSubtitleRow(_ source: SubtitleBurnSessionSource) -> some View {
        fileRow(
            target: .subtitles,
            title: "字幕",
            symbol: source.isTranslation ? "translate" : "text.alignleft",
            fileName: source.isTranslation ? L10n.text("将烧录：译文（当前显示的内容）") : L10n.text("将烧录：原文（当前显示的内容）"),
            emptyHint: "",
            detail: {
                VStack(alignment: .leading, spacing: 3) {
                    if source.cues.isEmpty {
                        Label("没有可烧录的文字。", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else {
                        Label(L10n.format("%lld 条", Int64(source.cues.count)), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    if source.approximateTimeline {
                        Label("编辑后时间轴为近似值，字幕可能与画面不同步。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        )
    }

    private func fileRow<Detail: View>(
        target: ImporterTarget,
        title: LocalizedStringKey,
        symbol: String,
        fileName: String?,
        emptyHint: LocalizedStringKey,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        let isTargeted = dropTarget == target
        let row = HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if let fileName {
                    Text(fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(emptyHint).font(.callout).foregroundStyle(.tertiary)
                }
                detail().font(.caption)
            }
            Spacer(minLength: 6)
            if !isLocked {
                Button("选择…") {
                    importerTarget = target
                    isShowingImporter = true
                }
                .controlSize(.small)
                .disabled(job.isRunning)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(isLocked ? 0.06 : 0.12),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isLocked ? [] : [5, 3]))
        }
        .contentShape(Rectangle())

        return Group {
            if isLocked {
                row
            } else {
                row.dropDestination(for: URL.self) { urls, _ in
                    guard !job.isRunning, let url = urls.first else { return false }
                    switch target {
                    case .video: chooseVideo(url)
                    case .subtitles: chooseSubtitles(url)
                    }
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTarget = target } else if dropTarget == target { dropTarget = nil }
                }
            }
        }
    }

    private func subtitleSummary(_ document: SubtitleDocument) -> String {
        let count = L10n.format("%lld 条", Int64(document.cues.count))
        return "\(document.format.title) · \(count) · \(document.firstStart.formattedDuration)–\(document.lastEnd.formattedDuration)"
    }

    private var blockedReason: String? {
        if videoInfo == nil { return isInspectingVideo ? nil : L10n.text("请选择可用的视频文件。") }
        if cues.isEmpty {
            if isLoadingSubtitles { return nil }
            return isLocked ? L10n.text("没有可烧录的文字。") : L10n.text("请选择可用的字幕文件。")
        }
        return nil
    }

    private func chooseVideo(_ url: URL) {
        job.reset()
        videoURL = url
        videoInfo = nil
        videoError = nil
        isInspectingVideo = true
        Task {
            do {
                let info = try await SubtitleBurner.inspect(videoURL: url)
                guard videoURL == url else { return }
                videoInfo = info
            } catch {
                guard videoURL == url else { return }
                videoError = error.localizedDescription
            }
            isInspectingVideo = false
        }
    }

    /// Parses off the main thread so very large subtitle files do not stall the UI.
    private func chooseSubtitles(_ url: URL) {
        job.reset()
        subtitleURL = url
        subtitleDocument = nil
        subtitleError = nil
        isLoadingSubtitles = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SubtitleDocument, SubtitleLoadFailure> in
                do { return .success(try SubtitleFileParser.load(url: url)) }
                catch { return .failure(SubtitleLoadFailure(message: error.localizedDescription)) }
            }.value
            guard subtitleURL == url else { return }
            switch result {
            case .success(let document): subtitleDocument = document
            case .failure(let failure): subtitleError = failure.message
            }
            isLoadingSubtitles = false
        }
    }
}

private struct SubtitleLoadFailure: Error, Sendable {
    let message: String
}

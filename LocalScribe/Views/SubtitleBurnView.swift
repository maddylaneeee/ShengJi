import SwiftUI
import UniformTypeIdentifiers

/// Standalone page: choose a video and a timed subtitle file, then burn.
struct SubtitleBurnView: View {
    let close: () -> Void

    @State private var job = SubtitleBurnJob()
    @State private var videoURL: URL?
    @State private var videoInfo: SubtitleBurnVideoInfo?
    @State private var videoError: String?
    @State private var isInspectingVideo = false
    @State private var subtitleURL: URL?
    @State private var subtitleDocument: SubtitleDocument?
    @State private var subtitleError: String?
    @State private var importerTarget: ImporterTarget = .video
    @State private var isShowingImporter = false

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    videoRow
                    Divider().padding(.vertical, 12)
                    subtitleRow
                }
                .padding(18)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                SubtitleBurnPanel(
                    videoInfo: videoInfo,
                    cues: subtitleDocument?.cues ?? [],
                    blockedReason: blockedReason,
                    job: job
                )
                .padding(18)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L10n.text("烧录字幕"))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("返回", systemImage: "chevron.left") { close() }
                    .disabled(job.isRunning)
            }
        }
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: importerTarget.contentTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importerTarget {
            case .video: chooseVideo(url)
            case .subtitles: chooseSubtitles(url)
            }
        }
#if DEBUG
        .onAppear {
            let environment = ProcessInfo.processInfo.environment
            if videoURL == nil, let path = environment["LOCALSCRIBE_BURN_VIDEO"] { chooseVideo(URL(fileURLWithPath: path)) }
            if subtitleURL == nil, let path = environment["LOCALSCRIBE_BURN_SUBTITLES"] { chooseSubtitles(URL(fileURLWithPath: path)) }
        }
#endif
        .dropDestination(for: URL.self) { urls, _ in
            guard !job.isRunning else { return false }
            for url in urls {
                if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) || type.conforms(to: .video) {
                    chooseVideo(url)
                } else {
                    chooseSubtitles(url)
                }
            }
            return !urls.isEmpty
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("烧录字幕")
                    .font(.title2.weight(.semibold))
                Text("把带时间戳的字幕渲染进视频画面；处理在这台 Mac 上完成。也可以把文件拖到这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var videoRow: some View {
        fileRow(
            title: "视频文件",
            symbol: "film",
            fileName: videoURL?.lastPathComponent,
            detail: {
                if isInspectingVideo {
                    Label("正在读取视频…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else if let videoError {
                    Label(videoError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if let videoInfo {
                    Label(videoInfo.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Text("支持 MP4、MOV、M4V 等 macOS 可以播放的视频").foregroundStyle(.secondary)
                }
            },
            choose: { importerTarget = .video; isShowingImporter = true }
        )
    }

    private var subtitleRow: some View {
        fileRow(
            title: "字幕文件",
            symbol: "captions.bubble",
            fileName: subtitleURL?.lastPathComponent,
            detail: {
                VStack(alignment: .leading, spacing: 4) {
                    if let subtitleError {
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
            },
            choose: { importerTarget = .subtitles; isShowingImporter = true }
        )
    }

    private func fileRow<Detail: View>(
        title: LocalizedStringKey,
        symbol: String,
        fileName: String?,
        @ViewBuilder detail: () -> Detail,
        choose: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                if let fileName {
                    Text(fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                detail().font(.caption)
            }
            Spacer(minLength: 8)
            Button("选择…", action: choose)
                .buttonStyle(.bordered)
                .disabled(job.isRunning)
        }
    }

    private func subtitleSummary(_ document: SubtitleDocument) -> String {
        let count = L10n.format("%lld 条", Int64(document.cues.count))
        return "\(document.format.title) · \(count) · \(document.firstStart.formattedDuration)–\(document.lastEnd.formattedDuration)"
    }

    private var blockedReason: String? {
        if videoInfo == nil { return L10n.text("请选择可用的视频文件。") }
        if subtitleDocument == nil { return L10n.text("请选择可用的字幕文件。") }
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

    private func chooseSubtitles(_ url: URL) {
        job.reset()
        subtitleURL = url
        do {
            subtitleDocument = try SubtitleFileParser.load(url: url)
            subtitleError = nil
        } catch {
            subtitleDocument = nil
            subtitleError = error.localizedDescription
        }
    }
}

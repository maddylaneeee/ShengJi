import SwiftUI

struct TranscribeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false
    @State private var showQuickSettings = true

    var body: some View {
        VStack(spacing: 0) {
            workflowHeader
            Divider()
            liveWorkspace
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            model.addInputFiles(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.tint, lineWidth: 3)
                    .padding(18)
            }
        }
    }

    private var workflowHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                sourceControls
                    .frame(maxWidth: .infinity, alignment: .leading)
                modelReadiness
                    .frame(width: 260, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 14) {
                outputSummary
                Spacer()
                Button {
                    model.revealOutputDirectory()
                } label: {
                    Label("Outputs", systemImage: "folder")
                }

                Button {
                    model.cancelRun()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!model.isRunning)

                Button {
                    model.startTranscription()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
                .help(model.canTranscribeReason ?? "Start transcription")
            }

            if let reason = model.canTranscribeReason, !model.isRunning {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.pickInputFiles()
                } label: {
                    Label("Local Files", systemImage: "plus")
                }

                Button {
                    model.clearInputFiles()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.inputFiles.isEmpty || model.isRunning)

                TextField("URL", text: $model.mediaURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.downloadMedia() }

                Button {
                    model.downloadMedia()
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
                .disabled(model.isDownloadingMedia || model.mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if model.isDownloadingMedia || !model.mediaDownloadProgress.detail.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.mediaDownloadProgress.title.isEmpty ? "Download" : model.mediaDownloadProgress.title)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(model.mediaDownloadProgress.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ProgressView(value: model.mediaDownloadProgress.fraction)
                }
            }
        }
    }

    private var modelReadiness: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.modelLoadState.title, systemImage: model.modelLoadState == .ready ? "checkmark.circle.fill" : "shippingbox")
                    .font(.headline)
                Spacer()
                if model.modelLoadState == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(model.modelLoadProgress.detail.isEmpty ? model.modelLoadState.detail : model.modelLoadProgress.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            ProgressView(value: model.modelLoadProgress.fraction)
        }
    }

    private var outputSummary: some View {
        HStack(spacing: 12) {
            Label(model.outputFormats.map(\.title).sorted().joined(separator: ", "), systemImage: "doc.badge.gearshape")
                .lineLimit(1)
            Divider()
                .frame(height: 20)
            Text(URL(fileURLWithPath: model.outputDirectory.isEmpty ? model.defaultOutputURL.path : model.outputDirectory).path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private var liveWorkspace: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 760
            Group {
                if compact {
                    VStack(spacing: 0) {
                        transcriptColumn
                        Divider()
                        queuePanel
                            .frame(height: min(340, max(230, proxy.size.height * 0.38)))
                    }
                } else {
                    HStack(spacing: 0) {
                        transcriptColumn
                        Divider()
                        queuePanel
                            .frame(width: min(430, max(340, proxy.size.width * 0.34)))
                    }
                }
            }
        }
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            transcriptPanel
            Divider()
            quickSettingsPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Transcript", systemImage: "text.alignleft")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.isRunning {
                    ProgressView(value: model.runProgress.fraction)
                        .frame(width: 180)
                    Text("\(model.runProgress.currentIndex)/\(model.runProgress.totalFiles)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.transcriptText = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .disabled(model.transcriptText.isEmpty)
            }

            ScrollView {
                Text(model.transcriptText.isEmpty ? "No transcript yet." : model.transcriptText)
                    .foregroundStyle(model.transcriptText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.transcriptText.isEmpty && model.inputFiles.isEmpty {
                    ContentUnavailableView(
                        "Drop audio or video files",
                        systemImage: "waveform.badge.plus"
                    )
                    .padding()
                }
            }
        }
        .padding(20)
    }

    private var quickSettingsPanel: some View {
        DisclosureGroup(isExpanded: $showQuickSettings) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Task", selection: $model.task) {
                    ForEach(WhisperTask.allCases) { task in
                        Text(task.title).tag(task)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Picker("Language", selection: $model.language) {
                        Text("Auto").tag("auto")
                        Text("EN").tag("en")
                        Text("ZH").tag("zh")
                        Text("JA").tag("ja")
                        Text("KO").tag("ko")
                    }
                    .frame(width: 180)

                    Toggle(isOn: $model.printTimestamps) {
                        Image(systemName: "clock")
                    }
                    .toggleStyle(.checkbox)
                    .help("Timestamps")

                    Toggle(isOn: $model.useMetal) {
                        Image(systemName: "gpu")
                    }
                    .toggleStyle(.checkbox)
                    .help("Metal")

                    Toggle(isOn: $model.enableVAD) {
                        Image(systemName: "waveform")
                    }
                    .toggleStyle(.checkbox)
                    .help("VAD")
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Run Options", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Queue", systemImage: "list.bullet")
                    .font(.headline)
                Spacer()
                Button {
                    model.clearInputFiles()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear")
                .disabled(model.inputFiles.isEmpty || model.isRunning)
            }

            if model.inputFiles.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.inputFiles, id: \.path) { file in
                        QueueRow(file: file)
                            .listRowInsets(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
                    }
                    .onDelete(perform: model.removeInputFiles)
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var model: AppModel
    let file: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(file.lastPathComponent)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 8) {
                Text(file.pathExtension.uppercased().isEmpty ? "MEDIA" : file.pathExtension.uppercased())
                Text(fileSize)
                Text(sourceText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(outputBasePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button {
                    model.openFile(file)
                } label: {
                    Image(systemName: "play.circle")
                }
                .help("Open")

                Button {
                    model.revealInFinder(file)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal")

                Button(role: .destructive) {
                    model.removeInputFile(file)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove")
                .disabled(model.isRunning)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Open", systemImage: "play.circle") {
                model.openFile(file)
            }
            Button("Reveal", systemImage: "folder") {
                model.revealInFinder(file)
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                model.removeInputFile(file)
            }
            .disabled(model.isRunning)
        }
    }

    private var iconName: String {
        let ext = file.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext) { return "film" }
        return "waveform"
    }

    private var sourceText: String {
        let cachePath = model.appSupportURL.appendingPathComponent("cache", isDirectory: true).path
        return file.path.hasPrefix(cachePath) ? "URL" : "Local"
    }

    private var fileSize: String {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var outputBasePath: String {
        let directory = URL(fileURLWithPath: model.outputDirectory.isEmpty ? model.defaultOutputURL.path : model.outputDirectory)
        return directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent).path
    }

    private var statusText: String {
        if model.isRunning, model.runProgress.currentFile == file {
            return model.runProgress.phase.rawValue
        }
        if let record = model.history.first(where: { $0.inputName == file.lastPathComponent }) {
            return record.succeeded ? "Done" : "Failed"
        }
        return "Queued"
    }

    private var statusColor: Color {
        switch statusText {
        case "Done": .green
        case "Failed": .red
        case "Converting", "Transcribing": .accentColor
        default: .secondary
        }
    }
}

struct StatusBadge: View {
    let text: String
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: running ? "progress.indicator" : "checkmark.circle")
            Text(text)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }
}

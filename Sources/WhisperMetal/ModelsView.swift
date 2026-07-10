import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Models"))
                        .font(.largeTitle.weight(.semibold))
                    Text(L.t("Download or import GGML models used by whisper.cpp."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshModels()
                } label: {
                    Label(L.t("Refresh"), systemImage: "arrow.clockwise")
                }
                Button {
                    model.pickModelFile()
                } label: {
                    Label(L.t("Import"), systemImage: "square.and.arrow.down")
                }
            }

            List {
                Section(L.t("Installed")) {
                    if model.availableModels.isEmpty {
                        ContentUnavailableView(L.t("No installed models"), systemImage: "shippingbox")
                    } else {
                        ForEach(model.availableModels, id: \.path) { url in
                            InstalledModelRow(url: url, selected: model.modelPath == url.path, isVAD: false)
                        }
                    }
                }

                Section(L.t("Download")) {
                    ForEach(DownloadableModel.all) { item in
                        DownloadableModelRow(item: item, isVAD: false)
                    }
                }

                Section(L.t("Voice Activity Models")) {
                    ForEach(model.availableVADModels, id: \.path) { url in
                        InstalledModelRow(url: url, selected: model.vadModelPath == url.path, isVAD: true)
                    }
                    ForEach(DownloadableModel.vad) { item in
                        DownloadableModelRow(item: item, isVAD: true)
                    }
                }
            }

            if model.isDownloadingModel || !model.modelDownloadProgress.detail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.modelDownloadProgress.title)
                        .font(.headline)
                    ProgressView(value: model.modelDownloadProgress.fraction)
                    Text(model.modelDownloadProgress.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .background(.background)
    }
}

private struct InstalledModelRow: View {
    @EnvironmentObject private var model: AppModel
    let url: URL
    let selected: Bool
    let isVAD: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                if isVAD {
                    model.vadModelPath = url.path
                } else {
                    model.selectModel(url.path)
                }
                model.saveSettings()
            } label: {
                Label(L.t("Use"), systemImage: "checkmark")
            }
            .disabled(selected)

            Button(role: .destructive) {
                model.deleteModel(url)
            } label: {
                Image(systemName: "trash")
            }
            .help(L.t("Delete"))
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button(L.t("Use"), systemImage: "checkmark") {
                if isVAD {
                    model.vadModelPath = url.path
                } else {
                    model.selectModel(url.path)
                }
                model.saveSettings()
            }
            Button(L.t("Delete"), systemImage: "trash", role: .destructive) {
                model.deleteModel(url)
            }
        }
    }
}

private struct DownloadableModelRow: View {
    @EnvironmentObject private var model: AppModel
    let item: DownloadableModel
    let isVAD: Bool

    var body: some View {
        let installed = model.isModelInstalled(item)
        let url = model.installedModelURL(item)

        HStack(spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(installed ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                Text("\(item.fileName), \(item.size)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Text(L.t("Installed"))
                    .foregroundStyle(.secondary)
                Button {
                    if isVAD {
                        model.vadModelPath = url.path
                    } else {
                        model.selectModel(url.path)
                    }
                    model.saveSettings()
                } label: {
                    Label(L.t("Use"), systemImage: "checkmark")
                }
                Button(role: .destructive) {
                    model.deleteModel(url)
                } label: {
                    Image(systemName: "trash")
                }
                .help(L.t("Delete"))
                .buttonStyle(.borderless)
            } else {
                Button {
                    model.downloadModel(item)
                } label: {
                    Label(L.t("Download"), systemImage: "arrow.down.circle")
                }
                .disabled(model.isDownloadingModel)
            }
        }
    }
}

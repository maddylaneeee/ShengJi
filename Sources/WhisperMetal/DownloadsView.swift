import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("YouTube / URL Downloads"))
                            .font(.largeTitle.weight(.semibold))
                        Text(L.t("YouTube uses yt-dlp. Direct URLs use streaming or accelerated download when available."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refreshYtDlpStatus()
                    } label: {
                        Label(L.t("Refresh"), systemImage: "arrow.clockwise")
                    }
                }

                GroupBox(L.t("yt-dlp Runtime")) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Path") {
                            Text(model.ytdlpPath.isEmpty ? "Not installed" : model.ytdlpPath)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Version", value: model.ytdlpVersion)
                        HStack {
                            Button {
                                model.updateYtDlp()
                            } label: {
                                Label(L.t("Update yt-dlp"), systemImage: "arrow.down.circle")
                            }
                            .disabled(model.isDownloadingMedia)

                            if model.isDownloadingMedia && model.mediaDownloadProgress.title == "yt-dlp" {
                                ProgressView(value: model.mediaDownloadProgress.fraction)
                                    .frame(maxWidth: 220)
                                Text(model.mediaDownloadProgress.detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox(L.t("Download Media")) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField(L.t("Video or playlist URL"), text: $model.mediaURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.downloadMedia() }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L.t("Output folder"))
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(model.mediaDownloadDirectory)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Button {
                                    model.pickMediaDownloadDirectory()
                                } label: {
                                    Image(systemName: "folder")
                                }
                            }
                        }

                        HStack {
                            Toggle(L.t("Audio only"), isOn: $model.mediaAudioOnly)
                            Toggle(L.t("Add downloaded files to queue"), isOn: $model.addDownloadedToQueue)
                            Toggle(L.t("Keep downloaded files"), isOn: $model.keepDownloadedMedia)
                            Spacer()
                        }

                        HStack {
                            Button {
                                model.downloadMedia()
                            } label: {
                                Label(L.t("Download Media"), systemImage: "arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isDownloadingMedia || model.mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                model.cancelMediaDownload()
                            } label: {
                                Label(L.t("Cancel"), systemImage: "stop.fill")
                            }
                            .disabled(!model.isDownloadingMedia)
                        }

                        if model.isDownloadingMedia || !model.mediaDownloadProgress.detail.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.mediaDownloadProgress.title)
                                    .font(.headline)
                                ProgressView(value: model.mediaDownloadProgress.fraction)
                                Text(model.mediaDownloadProgress.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

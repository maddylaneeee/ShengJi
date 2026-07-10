import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(AppModel.Section.allCases) { section in
                    Label(L.t(section.rawValue), systemImage: section.symbol)
                        .tag(section as AppModel.Section?)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            content
                .navigationTitle(L.t((model.selection ?? .transcribe).rawValue))
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            model.pickInputFiles()
                        } label: {
                            Label("Add Files", systemImage: "plus")
                        }
                        .help("Add local media files")

                        Button {
                            model.downloadMedia()
                        } label: {
                            Label("Download URL", systemImage: "link.badge.plus")
                        }
                        .help("Download the URL entered on the Transcribe page")
                        .disabled(model.isDownloadingMedia || model.mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            model.revealOutputDirectory()
                        } label: {
                            Label("Outputs", systemImage: "folder")
                        }
                        .help("Open output folder")
                    }

                    ToolbarItemGroup {
                        Button {
                            model.startTranscription()
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .disabled(!model.canRun)

                        Button {
                            model.cancelRun()
                        } label: {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                        .disabled(!model.isRunning)
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide output and decoding settings")
                    }
                }
                .inspector(isPresented: $model.showInspector) {
                    InspectorPanel()
                        .inspectorColumnWidth(min: 360, ideal: 420, max: 520)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection ?? .transcribe {
        case .transcribe:
            TranscribeView()
        case .downloads:
            DownloadsView()
        case .models:
            ModelsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}

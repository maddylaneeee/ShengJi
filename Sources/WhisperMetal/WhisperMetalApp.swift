import SwiftUI

@main
struct WhisperMetalApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 620)
                .task {
                    await model.startup()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files...") {
                    model.pickInputFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Start Transcription") {
                    model.startTranscription()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canRun)

                Button("Cancel Current Run") {
                    model.cancelRun()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isRunning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640)
                .padding(20)
        }
    }
}

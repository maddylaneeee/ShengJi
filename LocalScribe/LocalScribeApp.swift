import AppKit
import SwiftUI
import Translation

@main
struct LocalScribeApp: App {
    @State private var updateController = AppUpdateController()

    init() {
        CLIController.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 840, minHeight: 600)
                .translationTask(AppleTranslationCoordinator.shared.configuration) { session in
                    await AppleTranslationCoordinator.shared.run(session: session)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("从文件转录…") {
                    NotificationCenter.default.post(name: .chooseTranscriptionFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("检查更新…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }

        Settings {
            SettingsView(updateController: updateController)
        }
    }
}

extension Notification.Name {
    static let chooseTranscriptionFile = Notification.Name("chooseTranscriptionFile")
}

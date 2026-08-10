import AppKit
import SwiftUI
import Translation

@main
struct LocalScribeApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var updateController = AppUpdateController()
    @State private var presentationPreferences = AppPresentationPreferences()

    init() {
        CLIController.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView(updateController: updateController)
                .frame(minWidth: 840, minHeight: 600)
                .environment(\.locale, presentationPreferences.language.locale)
                .preferredColorScheme(presentationPreferences.appearance.colorScheme)
                .onAppear {
                    ApplicationMenuLocalizer.apply(presentationPreferences.language)
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                        updateController.startAutomaticUpdates()
                    }
                }
                .onChange(of: presentationPreferences.language) { _, language in
                    ApplicationMenuLocalizer.apply(language)
                }
                .translationTask(AppleTranslationCoordinator.shared.configuration) { session in
                    await AppleTranslationCoordinator.shared.run(session: session)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            LocalizedAppCommands(language: presentationPreferences.language)
        }

        Settings {
            SettingsView(
                updateController: updateController,
                presentationPreferences: presentationPreferences
            )
            .environment(\.locale, presentationPreferences.language.locale)
            .preferredColorScheme(presentationPreferences.appearance.colorScheme)
        }
    }
}

private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        GemmaProcessRegistry.terminateAll()
    }
}

private struct LocalizedAppCommands: Commands {
    let language: AppLanguage

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("麦克风转录", languageCode: language.languageCode)) {
                NotificationCenter.default.post(name: .startMicrophoneTranscription, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button(L10n.text("从文件转录…", languageCode: language.languageCode)) {
                NotificationCenter.default.post(name: .chooseTranscriptionFile, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
            Button(L10n.text("导入稿件…", languageCode: language.languageCode)) {
                NotificationCenter.default.post(name: .chooseTranscriptFile, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button(L10n.text("检查更新…", languageCode: language.languageCode)) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

extension Notification.Name {
    static let startMicrophoneTranscription = Notification.Name("startMicrophoneTranscription")
    static let chooseTranscriptionFile = Notification.Name("chooseTranscriptionFile")
    static let chooseTranscriptFile = Notification.Name("chooseTranscriptFile")
}

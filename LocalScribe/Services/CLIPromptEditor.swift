import AppKit
import CoreGraphics
import SwiftUI

/// `LocalScribe --cli prompts edit`: opens the prompt editor in its own window
/// inside the CLI process and exits when the window closes.
@MainActor
enum CLIPromptEditor {
    static func run() -> Int32 {
        guard hasGraphicalSession else {
            fputs(L10n.format("错误：%@\n", L10n.text("`prompts edit` 需要在已登录的图形会话中运行（例如本机“终端”），无法在 SSH 等无界面环境中打开窗口。")), stderr)
            return 1
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        let preferences = AIPromptPreferences()
        let language = AppPresentationPreferences().language
        let controller = WindowController()
        let root = NavigationStack {
            AIPromptEditorView(preferences: preferences, onDone: { controller.close() })
        }
        .environment(\.locale, language.locale)
        .frame(minWidth: 560, minHeight: 520)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("编辑 AI 提示词")
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = controller
        controller.window = window

        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        application.run()

        AIPromptPreferences.postExternalChange()
        print(L10n.text("已保存提示词。"))
        return 0
    }

    private static var hasGraphicalSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    @MainActor
    private final class WindowController: NSObject, NSWindowDelegate {
        weak var window: NSWindow?

        func close() { window?.close() }

        func windowWillClose(_ notification: Notification) {
            let application = NSApplication.shared
            application.stop(nil)
            // `stop` takes effect after the next event; post one so `run` returns now.
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) {
                application.postEvent(event, atStart: true)
            }
        }
    }
}

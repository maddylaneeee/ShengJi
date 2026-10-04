import AppKit

@MainActor
final class ApplicationMenuLocalizationController {
    private let menu: () -> NSMenu?
    private var language: AppLanguage = .system
    private var observers: [NSObjectProtocol] = []
    private var updateQueued = false

    init(menu: @escaping () -> NSMenu?) {
        self.menu = menu
        // SwiftUI may replace standard menu titles after the language observer runs.
        // AppKit posts these notifications for title and submenu changes as well.
        for name in [NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let changed = notification.object as? NSMenu, changed === self.menu() else { return }
                    self.scheduleUpdate()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func apply(_ language: AppLanguage) {
        self.language = language
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        guard !updateQueued else { return }
        updateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateTitles()
            self.updateQueued = false
        }
    }

    private func updateTitles() {
        guard let items = menu()?.items, items.count >= 6 else { return }
        let keys = ["声迹", "菜单：文件", "菜单：编辑", "菜单：显示", "菜单：窗口", "菜单：帮助"]
        for (item, key) in zip(items, keys) {
            let title = L10n.text(key, languageCode: language.languageCode)
            // Avoid writing unchanged properties and recursively notifying ourselves.
            if item.title != title { item.title = title }
            if let submenu = item.submenu, submenu.title != title { submenu.title = title }
        }
    }
}

@MainActor
enum ApplicationMenuLocalizer {
    private static let controller = ApplicationMenuLocalizationController { NSApp.mainMenu }
    static func apply(_ language: AppLanguage) { controller.apply(language) }
}

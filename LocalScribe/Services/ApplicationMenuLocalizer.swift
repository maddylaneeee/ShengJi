import AppKit

@MainActor
enum ApplicationMenuLocalizer {
    static func apply(_ language: AppLanguage) {
        DispatchQueue.main.async {
            guard let items = NSApp.mainMenu?.items, items.count >= 6 else { return }
            let titles = ["声迹", "菜单：文件", "菜单：编辑", "菜单：显示", "菜单：窗口", "菜单：帮助"].map {
                L10n.text($0, languageCode: language.languageCode)
            }
            for (index, title) in titles.enumerated() {
                let item = items[index]
                item.title = title
                item.submenu?.title = title
            }
        }
    }
}

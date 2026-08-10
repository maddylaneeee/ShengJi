import AppKit

@MainActor
enum ApplicationMenuLocalizer {
    static func apply(_ language: AppLanguage) {
        applyNow(language)
        // SwiftUI rebuilds the command menus after a locale change. Reapply on
        // the next run-loop turns so the rebuilt native menu keeps the chosen language.
        DispatchQueue.main.async { applyNow(language) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { applyNow(language) }
    }

    private static func applyNow(_ language: AppLanguage) {
        guard let items = NSApp.mainMenu?.items, items.count >= 6 else { return }
        let titles = ["声迹", "菜单：文件", "菜单：编辑", "菜单：显示", "菜单：窗口", "菜单：帮助"].map {
            L10n.text($0, languageCode: language.languageCode)
        }
        for (index, title) in titles.enumerated() {
            let item = items[index]
            item.title = title
            item.submenu?.title = title
        }
        for item in items {
            localize(menu: item.submenu, language: language)
        }
    }

    private static func localize(menu: NSMenu?, language: AppLanguage) {
        guard let menu else { return }
        for item in menu.items {
            let selector = item.action.map(NSStringFromSelector)
            if let selector, let key = actionKeys[selector] {
                item.title = L10n.text(key, languageCode: language.languageCode)
            } else if let key = titleKeys[item.title] {
                item.title = L10n.text(key, languageCode: language.languageCode)
            }
            if let submenu = item.submenu {
                if let key = titleKeys[submenu.title] {
                    let title = L10n.text(key, languageCode: language.languageCode)
                    item.title = title
                    submenu.title = title
                }
                localize(menu: submenu, language: language)
            }
        }
    }

    private static let actionKeys: [String: String] = [
        "orderFrontStandardAboutPanel:": "关于声迹",
        "showSettingsWindow:": "设置…",
        "hide:": "隐藏声迹",
        "hideOtherApplications:": "隐藏其他",
        "unhideAllApplications:": "全部显示",
        "terminate:": "退出声迹",
        "undo:": "撤销",
        "redo:": "重做",
        "cut:": "剪切",
        "copy:": "复制",
        "paste:": "粘贴",
        "selectAll:": "全选",
        "performClose:": "关闭窗口",
        "miniaturize:": "最小化",
        "zoom:": "缩放",
        "arrangeInFront:": "前置全部窗口",
        "toggleFullScreen:": "进入全屏幕"
    ]

    private static let titleKeys: [String: String] = [
        "Settings…": "设置…",
        "设置…": "设置…",
        "Check for Updates…": "检查更新…",
        "检查更新…": "检查更新…",
        "Services": "服务",
        "服务": "服务",
        "Speech": "语音",
        "语音": "语音",
        "Start Speaking": "开始朗读",
        "开始朗读": "开始朗读",
        "Stop Speaking": "停止朗读",
        "停止朗读": "停止朗读",
        "Help": "菜单：帮助",
        "帮助": "菜单：帮助"
    ]
}

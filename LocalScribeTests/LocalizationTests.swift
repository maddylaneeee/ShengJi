import AVFoundation
import Speech
import XCTest
@testable import LocalScribe

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseResourcesAreBundled() throws {
        let english = try XCTUnwrap(localizationBundle(language: "en"))
        let chinese = try XCTUnwrap(localizationBundle(language: "zh-Hans"))

        XCTAssertEqual(english.localizedString(forKey: "声迹", value: nil, table: nil), "LocalScribe")
        XCTAssertEqual(english.localizedString(forKey: "开始转录", value: nil, table: nil), "Start Transcription")
        XCTAssertEqual(chinese.localizedString(forKey: "声迹", value: nil, table: nil), "声迹")
        XCTAssertEqual(
            english.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"),
            "LocalScribe"
        )
        XCTAssertEqual(
            chinese.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"),
            "声迹"
        )
    }

    func testEveryRuntimeLocalizationKeyHasEnglishAndChineseValues() throws {
        let english = try XCTUnwrap(localizationBundle(language: "en"))
        let chinese = try XCTUnwrap(localizationBundle(language: "zh-Hans"))
        let keys = [
            "自动",
            "最快，适合快速草稿",
            "正在下载 %@",
            "模型文件不完整（应为 %lld 字节，实际为 %lld 字节）。",
            "以悬浮窗显示本地实时字幕",
            "程序语言",
            "权限",
            "离线翻译已就绪",
            "推荐语言",
            "自动检查并下载更新",
        ]

        for key in keys {
            XCTAssertNotEqual(english.localizedString(forKey: key, value: nil, table: nil), key)
            XCTAssertEqual(chinese.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }

    func testEnglishAndChineseLocalizationKeySetsMatch() throws {
        let english = try localizationDictionary(language: "en")
        let chinese = try localizationDictionary(language: "zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
    }

    func testMenuBarTitlesAreLocalizedForBothAppLanguages() throws {
        let english = try XCTUnwrap(localizationBundle(language: "en"))
        let chinese = try XCTUnwrap(localizationBundle(language: "zh-Hans"))
        XCTAssertEqual(english.localizedString(forKey: "菜单：文件", value: nil, table: nil), "File")
        XCTAssertEqual(chinese.localizedString(forKey: "菜单：文件", value: nil, table: nil), "文件")
        XCTAssertEqual(english.localizedString(forKey: "菜单：显示", value: nil, table: nil), "View")
        XCTAssertEqual(chinese.localizedString(forKey: "菜单：显示", value: nil, table: nil), "显示")
    }

    func testLiveCaptionInputTitlesFollowAppLanguageWithoutRestart() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppLanguage.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.defaultsKey)
            }
        }

        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(LiveCaptionInputMode.microphone.title, "麦克风")
        XCTAssertEqual(LiveCaptionInputMode.systemAudio.title, "Mac 声音")
        XCTAssertEqual(LiveCaptionInputMode.both.title, "麦克风 + Mac 声音")

        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(LiveCaptionInputMode.microphone.title, "Microphone")
        XCTAssertEqual(LiveCaptionInputMode.systemAudio.title, "Mac Audio")
        XCTAssertEqual(LiveCaptionInputMode.both.title, "Microphone + Mac Audio")
    }

    @MainActor
    func testPresentationPreferencesPersistAndInvalidValuesFallBackToSystem() throws {
        let suiteName = "LocalizationTests.PresentationPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unsupported", forKey: AppLanguage.defaultsKey)
        defaults.set("unsupported", forKey: AppAppearance.defaultsKey)
        let preferences = AppPresentationPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.appearance, .system)

        preferences.language = .english
        preferences.appearance = .dark
        XCTAssertEqual(defaults.string(forKey: AppLanguage.defaultsKey), AppLanguage.english.rawValue)
        XCTAssertEqual(defaults.string(forKey: AppAppearance.defaultsKey), AppAppearance.dark.rawValue)
    }

    @MainActor
    func testPermissionStateMappings() {
        XCTAssertEqual(PermissionCenter.state(for: AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionCenter.state(for: AVAuthorizationStatus.authorized), .authorized)
        XCTAssertEqual(PermissionCenter.state(for: AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionCenter.state(for: SFSpeechRecognizerAuthorizationStatus.restricted), .restricted)
    }

    @MainActor
    func testRecommendedLanguagesPutEnglishBeforeDeviceLanguageWithoutDuplicates() {
        let languages = [
            LanguageOption(locale: Locale(identifier: "zh_CN"), isInstalled: true),
            LanguageOption(locale: Locale(identifier: "en_US"), isInstalled: false),
            LanguageOption(locale: Locale(identifier: "fr_FR"), isInstalled: false),
        ]

        let recommended = LanguageCatalog.recommendations(
            from: languages,
            deviceLocale: Locale(identifier: "zh_CN")
        )

        XCTAssertEqual(recommended.map(\.id), ["en_US", "zh_CN"])
    }

    @MainActor
    func testRecommendedLanguagesShowOnlyDeviceEnglishWhenDeviceUsesEnglish() {
        let languages = [
            LanguageOption(locale: Locale(identifier: "en_US"), isInstalled: false),
            LanguageOption(locale: Locale(identifier: "en_CA"), isInstalled: true),
            LanguageOption(locale: Locale(identifier: "zh_CN"), isInstalled: true),
        ]

        let recommended = LanguageCatalog.recommendations(
            from: languages,
            deviceLocale: Locale(identifier: "en_CA")
        )

        XCTAssertEqual(recommended.map(\.id), ["en_CA"])
    }

    private func localizationBundle(language: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    private func localizationDictionary(language: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(localizationBundle(language: language))
        let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

}

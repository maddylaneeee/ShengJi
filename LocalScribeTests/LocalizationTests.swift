import XCTest
@testable import LocalScribe

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseResourcesAreBundled() throws {
        let english = try XCTUnwrap(localizationBundle(language: "en"))
        let chinese = try XCTUnwrap(localizationBundle(language: "zh-Hans"))

        XCTAssertEqual(english.localizedString(forKey: "声迹", value: nil, table: nil), "ShengJi")
        XCTAssertEqual(english.localizedString(forKey: "开始转录", value: nil, table: nil), "Start Transcription")
        XCTAssertEqual(chinese.localizedString(forKey: "声迹", value: nil, table: nil), "声迹")
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
        ]

        for key in keys {
            XCTAssertNotEqual(english.localizedString(forKey: key, value: nil, table: nil), key)
            XCTAssertEqual(chinese.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }

    private func localizationBundle(language: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

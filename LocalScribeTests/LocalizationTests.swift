import XCTest
@testable import LocalScribe

final class LocalizationTests: XCTestCase {
    func testPrivacyDescriptionsAreBundledForEveryLanguage() throws {
        for language in ["en", "zh-Hans", "ja"] {
            let bundle = try XCTUnwrap(localizationBundle(language: language))
            for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription",
                        "NSScreenCaptureUsageDescription", "NSSpeechRecognitionUsageDescription",
                        "NSFileProviderDomainUsageDescription"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertNotEqual(value, key, "\(language): \(key)")
            }
        }
    }

    func testAllLanguagesHaveMatchingKeysAndFormatArguments() throws {
        let english = try localizationDictionary(language: "en")
        let format = try NSRegularExpression(pattern: "%[-+0 #]*[0-9]*(?:\\.[0-9]+)?(?:ll|l|z)?[@diufgs]")
        func placeholders(_ text: String) -> [String] {
            format.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for language in ["zh-Hans", "ja"] {
            let localized = try localizationDictionary(language: language)
            XCTAssertEqual(Set(english.keys), Set(localized.keys), language)
            for (key, value) in english {
                let translation = try XCTUnwrap(localized[key], "Missing \(language): \(key)")
                XCTAssertFalse(translation.isEmpty, key)
                XCTAssertEqual(placeholders(value), placeholders(translation), "Format mismatch \(language): \(key)")
            }
        }
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

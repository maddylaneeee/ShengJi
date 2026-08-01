import AppKit
import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "AppLanguage"

    var id: String { rawValue }

    var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "AppAppearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .light: L10n.text("浅色")
        case .dark: L10n.text("深色")
        }
    }
}

@MainActor
@Observable
final class AppPresentationPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: AppAppearance.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: AppAppearance.defaultsKey) ?? "") ?? .system
    }
}

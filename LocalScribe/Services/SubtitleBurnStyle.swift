import AppKit
import Foundation
import Observation

enum SubtitleBurnPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom
    case top

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottom: L10n.text("底部")
        case .top: L10n.text("顶部")
        }
    }
}

struct SubtitleBurnColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = SubtitleBurnColor(red: 0, green: 0, blue: 0)

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    /// Accepts `#RRGGBB` or `RRGGBB`.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// Visual style for burned subtitles. Sizes are relative to the video's
/// shorter side so portrait and landscape videos look consistent.
struct SubtitleBurnStyle: Codable, Equatable, Sendable {
    static let fontSizeRange: ClosedRange<Double> = 3...10
    static let marginRange: ClosedRange<Double> = 2...20
    static let backgroundOpacityRange: ClosedRange<Double> = 0...0.8
    static let shadowWidthRange: ClosedRange<Double> = 0...10

    /// Font family name; `nil` means the system font.
    var fontFamily: String?
    var fontSizePercent: Double = 5
    var position: SubtitleBurnPosition = .bottom
    var marginPercent: Double = 6
    var backgroundEnabled = false
    var backgroundOpacity: Double = 0.45
    var shadowColor: SubtitleBurnColor = .black
    var shadowWidth: Double = 5

    static let `default` = SubtitleBurnStyle()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubtitleBurnStyle()
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSizePercent = (try? container.decode(Double.self, forKey: .fontSizePercent)) ?? defaults.fontSizePercent
        position = (try? container.decode(SubtitleBurnPosition.self, forKey: .position)) ?? defaults.position
        marginPercent = (try? container.decode(Double.self, forKey: .marginPercent)) ?? defaults.marginPercent
        backgroundEnabled = (try? container.decode(Bool.self, forKey: .backgroundEnabled)) ?? defaults.backgroundEnabled
        backgroundOpacity = (try? container.decode(Double.self, forKey: .backgroundOpacity)) ?? defaults.backgroundOpacity
        shadowColor = (try? container.decode(SubtitleBurnColor.self, forKey: .shadowColor)) ?? defaults.shadowColor
        shadowWidth = (try? container.decode(Double.self, forKey: .shadowWidth)) ?? defaults.shadowWidth
        self = clamped()
    }

    func clamped() -> SubtitleBurnStyle {
        var style = self
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        style.fontSizePercent = clamp(fontSizePercent, Self.fontSizeRange, 5)
        style.marginPercent = clamp(marginPercent, Self.marginRange, 6)
        style.backgroundOpacity = clamp(backgroundOpacity, Self.backgroundOpacityRange, 0.45)
        style.shadowWidth = clamp(shadowWidth, Self.shadowWidthRange, 5)
        if let family = style.fontFamily?.trimmingCharacters(in: .whitespaces), family.isEmpty { style.fontFamily = nil }
        return style
    }

    /// Resolves the configured font, falling back to the system font when the family is missing.
    func font(size: CGFloat) -> NSFont {
        if let fontFamily, SubtitleFontCatalog.isInstalled(fontFamily),
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 8, size: size)
            ?? NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}

enum SubtitleFontCatalog {
    static func families() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }
}

/// Persists the burn style (including the font). The output mode
/// (copy vs. replace original) is intentionally never persisted.
@MainActor
@Observable
final class SubtitleBurnPreferences {
    static let defaultsKey = "subtitleBurn.style.v1"
    static let shared = SubtitleBurnPreferences()

    private let defaults: UserDefaults

    var style: SubtitleBurnStyle {
        didSet {
            let clamped = style.clamped()
            if clamped != style { style = clamped; return }
            if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(SubtitleBurnStyle.self, from: data) {
            style = stored
        } else {
            style = .default
        }
    }

    func resetToDefault() {
        style = .default
    }

    /// The style actually used for rendering: a missing font family falls back to the system font.
    var effectiveStyle: SubtitleBurnStyle {
        var resolved = style
        if let family = resolved.fontFamily, !SubtitleFontCatalog.isInstalled(family) { resolved.fontFamily = nil }
        return resolved
    }
}

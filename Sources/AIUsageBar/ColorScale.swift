import AppKit
import Foundation
import SwiftUI

/// A plain sRGB colour, storable in `UserDefaults` and comparable, unlike `NSColor` or `Color`.
struct RGBA: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// nil when the colour cannot be converted to sRGB (a pattern colour, say); callers keep
    /// whatever they had rather than crash.
    init?(_ color: NSColor) {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }
}

/// One band's colour: either the system tint it always had, or a colour the user picked.
enum BandColor: Codable, Equatable {
    case system
    case custom(RGBA)
}

/// The user-customisable version of the scale `UsageColor` used to hardcode: three cutoffs
/// (percent, ascending) splitting the 1...100 range into four bands, and a colour per band.
/// `.default` reproduces the original fixed 75/85/95 scale and its system colours exactly.
struct ColorScale: Codable, Equatable {
    var mediumCutoff: Double
    var highCutoff: Double
    var criticalCutoff: Double
    var low: BandColor
    var medium: BandColor
    var high: BandColor
    var critical: BandColor

    static let `default` = ColorScale(mediumCutoff: 75, highCutoff: 85, criticalCutoff: 95,
                                      low: .system, medium: .system, high: .system, critical: .system)

    init(mediumCutoff: Double, highCutoff: Double, criticalCutoff: Double,
         low: BandColor, medium: BandColor, high: BandColor, critical: BandColor) {
        self.mediumCutoff = mediumCutoff
        self.highCutoff = highCutoff
        self.criticalCutoff = criticalCutoff
        self.low = low
        self.medium = medium
        self.high = high
        self.critical = critical
    }

    /// Field by field, so a scale saved by an older build (or one missing a key a later build
    /// adds) keeps what it has and takes the default for the rest, instead of the whole scale
    /// failing to decode and resetting the user's colours.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ColorScale.default
        mediumCutoff = try container.decodeIfPresent(Double.self, forKey: .mediumCutoff) ?? fallback.mediumCutoff
        highCutoff = try container.decodeIfPresent(Double.self, forKey: .highCutoff) ?? fallback.highCutoff
        criticalCutoff = try container.decodeIfPresent(Double.self, forKey: .criticalCutoff) ?? fallback.criticalCutoff
        low = try container.decodeIfPresent(BandColor.self, forKey: .low) ?? fallback.low
        medium = try container.decodeIfPresent(BandColor.self, forKey: .medium) ?? fallback.medium
        high = try container.decodeIfPresent(BandColor.self, forKey: .high) ?? fallback.high
        critical = try container.decodeIfPresent(BandColor.self, forKey: .critical) ?? fallback.critical
    }

    /// The default scale, already encoded, for `@AppStorage` defaults and the screenshot
    /// renderer's pinned domain.
    static let defaultData: Data = (try? JSONEncoder().encode(ColorScale.default)) ?? Data()

    /// Clamps each cutoff to 1...100, then enforces a strict ascending order with at least a
    /// 1 point gap between neighbours: later cutoffs are pushed up first, and if that runs
    /// into the 100 ceiling, earlier ones are pulled back down to make room.
    func normalized() -> ColorScale {
        var scale = self
        scale.mediumCutoff = Self.clamp(scale.mediumCutoff)
        scale.highCutoff = Self.clamp(scale.highCutoff)
        scale.criticalCutoff = Self.clamp(scale.criticalCutoff)

        if scale.highCutoff < scale.mediumCutoff + 1 { scale.highCutoff = scale.mediumCutoff + 1 }
        if scale.criticalCutoff < scale.highCutoff + 1 { scale.criticalCutoff = scale.highCutoff + 1 }

        if scale.criticalCutoff > 100 {
            scale.criticalCutoff = 100
            if scale.highCutoff > scale.criticalCutoff - 1 { scale.highCutoff = scale.criticalCutoff - 1 }
            if scale.mediumCutoff > scale.highCutoff - 1 { scale.mediumCutoff = scale.highCutoff - 1 }
        }
        return scale
    }

    private static func clamp(_ value: Double) -> Double { min(100, max(1, value)) }

    func level(for percent: Double) -> UsageColor.Level {
        switch percent {
        case ..<mediumCutoff: return .low
        case ..<highCutoff: return .medium
        case ..<criticalCutoff: return .high
        default: return .critical
        }
    }

    func band(for level: UsageColor.Level) -> BandColor {
        switch level {
        case .low: return low
        case .medium: return medium
        case .high: return high
        case .critical: return critical
        }
    }

    /// Read/write access to one band by level, for the settings view's bindings.
    subscript(level: UsageColor.Level) -> BandColor {
        get { band(for: level) }
        set {
            switch level {
            case .low: low = newValue
            case .medium: medium = newValue
            case .high: high = newValue
            case .critical: critical = newValue
            }
        }
    }

    func nsColor(for level: UsageColor.Level) -> NSColor {
        switch band(for: level) {
        case .system: return Self.systemNSColor(for: level)
        case .custom(let rgba): return rgba.nsColor
        }
    }

    func color(for level: UsageColor.Level) -> Color {
        switch band(for: level) {
        case .system: return Self.systemColor(for: level)
        case .custom(let rgba): return rgba.color
        }
    }

    // The two system palettes are not the same RGB values (SwiftUI's Color.green is not
    // NSColor.systemGreen), so each is resolved separately rather than derived from the other.
    private static func systemNSColor(for level: UsageColor.Level) -> NSColor {
        switch level {
        case .low: return .systemGreen
        case .medium: return .systemYellow
        case .high: return .systemRed
        case .critical: return UsageColor.darkRed
        }
    }

    private static func systemColor(for level: UsageColor.Level) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        case .critical: return Color(nsColor: UsageColor.darkRed)
        }
    }

    /// nil or garbage data falls back to `.default`; anything decoded is normalised so a
    /// hand-edited default never hands out an inverted or out-of-range scale.
    static func decode(_ data: Data?) -> ColorScale {
        guard let data, let decoded = try? JSONDecoder().decode(ColorScale.self, from: data) else { return .default }
        return decoded.normalized()
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

extension UsageColor.Icon {
    /// The band each fixed icon colour stands for, so a custom scale can still be asked "what
    /// colour is `.red` today".
    var level: UsageColor.Level {
        switch self {
        case .green: return .low
        case .yellow: return .medium
        case .red: return .high
        case .darkRed: return .critical
        }
    }
}

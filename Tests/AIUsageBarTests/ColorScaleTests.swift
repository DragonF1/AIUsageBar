import AppKit
import SwiftUI
import XCTest
@testable import AIUsageBar

/// `ColorScale` is the user-customisable version of the fixed 75/85/95 scale `UsageColor` used
/// to hardcode; these tests lock the default scale down to the original pixels, then exercise
/// the custom-band and normalisation paths a settings UI can produce.
final class ColorScaleTests: XCTestCase {
    private func customScale(mediumCutoff: Double, highCutoff: Double, criticalCutoff: Double) -> ColorScale {
        ColorScale(mediumCutoff: mediumCutoff, highCutoff: highCutoff, criticalCutoff: criticalCutoff,
                  low: .system, medium: .system, high: .system, critical: .system)
    }

    func testDefaultReproducesOriginalCutoffs() {
        let scale = ColorScale.default
        XCTAssertEqual(scale.level(for: 74.9), .low)
        XCTAssertEqual(scale.level(for: 75), .medium)
        XCTAssertEqual(scale.level(for: 84.9), .medium)
        XCTAssertEqual(scale.level(for: 85), .high)
        XCTAssertEqual(scale.level(for: 94.9), .high)
        XCTAssertEqual(scale.level(for: 95), .critical)
    }

    func testDefaultSystemColoursResolveToOriginalNSColors() {
        let scale = ColorScale.default
        XCTAssertEqual(scale.nsColor(for: .low), .systemGreen)
        XCTAssertEqual(scale.nsColor(for: .medium), .systemYellow)
        XCTAssertEqual(scale.nsColor(for: .high), .systemRed)
        XCTAssertEqual(scale.nsColor(for: .critical), UsageColor.darkRed)
    }

    func testDefaultSystemColoursResolveToOriginalSwiftUIColors() {
        let scale = ColorScale.default
        XCTAssertEqual(scale.color(for: .low), Color.green)
        XCTAssertEqual(scale.color(for: .medium), Color.yellow)
        XCTAssertEqual(scale.color(for: .high), Color.red)
        XCTAssertEqual(scale.color(for: .critical), Color(nsColor: UsageColor.darkRed))
    }

    func testCustomBandOverridesOnlyThatBand() {
        var scale = ColorScale.default
        let purple = RGBA(red: 0.5, green: 0, blue: 0.5)
        scale.medium = .custom(purple)
        XCTAssertEqual(scale.color(for: .medium), purple.color)
        XCTAssertEqual(scale.nsColor(for: .medium), purple.nsColor)
        // The other three bands stay on the system palette.
        XCTAssertEqual(scale.color(for: .low), Color.green)
        XCTAssertEqual(scale.color(for: .high), Color.red)
        XCTAssertEqual(scale.color(for: .critical), Color(nsColor: UsageColor.darkRed))
    }

    func testNormalizedClampsToRange() {
        let scale = customScale(mediumCutoff: -5, highCutoff: 500, criticalCutoff: 500).normalized()
        XCTAssertGreaterThanOrEqual(scale.mediumCutoff, 1)
        XCTAssertLessThanOrEqual(scale.mediumCutoff, 100)
        XCTAssertLessThanOrEqual(scale.highCutoff, 100)
        XCTAssertLessThanOrEqual(scale.criticalCutoff, 100)
        XCTAssertTrue(scale.mediumCutoff < scale.highCutoff)
        XCTAssertTrue(scale.highCutoff < scale.criticalCutoff)
    }

    func testNormalizedFixesInvertedOrder() {
        let scale = customScale(mediumCutoff: 90, highCutoff: 80, criticalCutoff: 70).normalized()
        XCTAssertTrue(scale.mediumCutoff < scale.highCutoff)
        XCTAssertTrue(scale.highCutoff < scale.criticalCutoff)
        XCTAssertLessThanOrEqual(scale.criticalCutoff, 100)
    }

    func testNormalizedHandlesCrowdingAgainstTheCeiling() {
        let scale = customScale(mediumCutoff: 100, highCutoff: 100, criticalCutoff: 100).normalized()
        XCTAssertTrue(scale.mediumCutoff < scale.highCutoff)
        XCTAssertTrue(scale.highCutoff < scale.criticalCutoff)
        XCTAssertLessThanOrEqual(scale.criticalCutoff, 100)
    }

    func testCodableRoundTrip() {
        var scale = ColorScale.default
        scale.mediumCutoff = 60
        scale.low = .custom(RGBA(red: 0.1, green: 0.2, blue: 0.3))
        scale.critical = .system
        let decoded = ColorScale.decode(scale.encoded())
        XCTAssertEqual(decoded, scale)
    }

    func testDecodeKeepsWhatAnOlderPayloadHasAndDefaultsTheRest() throws {
        // A payload from a build that only knew two cutoffs and one colour.
        let partial = Data("""
        {"mediumCutoff": 40, "highCutoff": 60, "low": {"custom": {"_0": {"red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1}}}}
        """.utf8)
        let decoded = ColorScale.decode(partial)
        XCTAssertEqual(decoded.mediumCutoff, 40)
        XCTAssertEqual(decoded.highCutoff, 60)
        XCTAssertEqual(decoded.criticalCutoff, ColorScale.default.criticalCutoff)
        XCTAssertEqual(decoded.low, .custom(RGBA(red: 0.1, green: 0.2, blue: 0.3)))
        XCTAssertEqual(decoded.medium, .system)
        XCTAssertEqual(decoded.critical, .system)
    }

    func testAutoTintTitleQuotesTheHighCutoff() {
        XCTAssertEqual(MenuBarMetric.auto.title(scale: .default), "Auto (5-hour, weekly from 85%)")
        XCTAssertEqual(MenuBarMetric.auto.title(scale: customScale(mediumCutoff: 50, highCutoff: 70, criticalCutoff: 90)),
                       "Auto (5-hour, weekly from 70%)")
        XCTAssertEqual(MenuBarMetric.session.title(scale: .default), "5-hour window")
    }

    func testDecodeFallsBackOnGarbage() {
        XCTAssertEqual(ColorScale.decode(nil), .default)
        XCTAssertEqual(ColorScale.decode(Data([0x00, 0x01, 0x02, 0xFF])), .default)
    }

    func testRGBAFromNSColorRoundTrips() throws {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let rgba = try XCTUnwrap(RGBA(color))
        XCTAssertEqual(rgba.red, 0.2, accuracy: 0.001)
        XCTAssertEqual(rgba.green, 0.4, accuracy: 0.001)
        XCTAssertEqual(rgba.blue, 0.6, accuracy: 0.001)
        XCTAssertEqual(rgba.alpha, 1, accuracy: 0.001)
    }

    func testIconLevelBridge() {
        XCTAssertEqual(UsageColor.Icon.green.level, .low)
        XCTAssertEqual(UsageColor.Icon.yellow.level, .medium)
        XCTAssertEqual(UsageColor.Icon.red.level, .high)
        XCTAssertEqual(UsageColor.Icon.darkRed.level, .critical)
    }

    func testLevelFollowsCustomCutoffs() {
        let scale = customScale(mediumCutoff: 50, highCutoff: 55, criticalCutoff: 90)
        XCTAssertEqual(UsageColor.level(for: 60, scale: scale), .high)
    }

    func testIconFollowsWeeklyFromCustomHighCutoff() {
        let scale = customScale(mediumCutoff: 50, highCutoff: 70, criticalCutoff: 95)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 70, metric: .auto, scale: scale), .red)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 69.9, metric: .auto, scale: scale), .green)
    }

    @MainActor func testMenuBarTitleIconColorHonoursCustomScale() throws {
        var scale = ColorScale.default
        let blue = RGBA(red: 0, green: 0, blue: 1)
        scale.low = .custom(blue)
        let title = MenuBarTitle(tab: .claude, session: 10, weekly: 0, isStale: false, metric: .auto, scale: scale)
        let resolved = try XCTUnwrap(title.iconColor.usingColorSpace(.sRGB))
        XCTAssertEqual(resolved.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(resolved.greenComponent, 0, accuracy: 0.001)
        XCTAssertEqual(resolved.blueComponent, 1, accuracy: 0.001)
    }
}

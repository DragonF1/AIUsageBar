import AppKit
import XCTest
@testable import AIUsageBar

/// `MenuBarWidth` pads the shown tab's title out to the other tab's width so switching tabs never
/// changes the status item's width. The numbers below are the live measurements the design was
/// checked against: "8% / 32%" and "100% / 100%" in the menu bar font beside an 18pt mark.
final class MenuBarWidthTests: XCTestCase {
    private let short: CGFloat = 60.85131072998047
    private let long: CGFloat = 85.78178334236145

    // MARK: - trailingPadding

    func testPadsTheNarrowerTabUpToTheWiderOneInWholePoints() {
        // ceil(60.85) = 61, ceil(85.78) = 86: the short title needs 25 more points.
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: short, currentImageWidth: 18,
                                                   otherTextWidth: long, otherImageWidth: 18)
        XCTAssertEqual(padding, 25)
    }

    func testTheWiderTabNeedsNoPadding() {
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: long, currentImageWidth: 18,
                                                   otherTextWidth: short, otherImageWidth: 18)
        XCTAssertEqual(padding, 0)
    }

    func testEqualWidthsNeedNoPadding() {
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: short, currentImageWidth: 18,
                                                   otherTextWidth: short, otherImageWidth: 18)
        XCTAssertEqual(padding, 0)
    }

    func testAWiderMarkOnTheOtherTabCountsTowardsThePadding() {
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: short, currentImageWidth: 18,
                                                   otherTextWidth: short, otherImageWidth: 22)
        XCTAssertEqual(padding, 4)
    }

    func testAnIconOnlyTabIsPaddedByTheWholeOtherText() {
        // An empty template draws the icon alone; the other tab's whole text width is the gap.
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: 0, currentImageWidth: 18,
                                                   otherTextWidth: long, otherImageWidth: 18)
        XCTAssertEqual(padding, 86)
    }

    // MARK: - pad

    private func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: MenuBarTitle.font, .foregroundColor: NSColor.labelColor])
    }

    func testPaddingAddsExactlyThatManyPointsToTheMeasuredWidth() {
        let original = title("8% / 32%")
        let padded = MenuBarWidth.pad(original, by: 25, font: MenuBarTitle.font)
        XCTAssertEqual(padded.size().width, original.size().width + 25, accuracy: 0.001)
        XCTAssertEqual(padded.string, "8% / 32% ")
    }

    func testPaddingSmallerThanASpaceStillComesOutExact() {
        // The kern goes negative when the gap is under a space width; the advance is still the gap.
        let original = title("8% / 32%")
        let padded = MenuBarWidth.pad(original, by: 1, font: MenuBarTitle.font)
        XCTAssertEqual(padded.size().width, original.size().width + 1, accuracy: 0.001)
    }

    func testZeroPaddingReturnsTheTitleUntouched() {
        let original = title("8% / 32%")
        XCTAssertTrue(MenuBarWidth.pad(original, by: 0, font: MenuBarTitle.font) === original)
        XCTAssertTrue(MenuBarWidth.pad(original, by: -3, font: MenuBarTitle.font) === original)
    }

    func testAnEmptyTitleCanBePaddedIntoAPlainGap() {
        let padded = MenuBarWidth.pad(title(""), by: 40, font: MenuBarTitle.font)
        XCTAssertEqual(padded.size().width, 40, accuracy: 0.001)
    }

    func testPaddedShortTitleRoundsUpToTheLongTitlesWidth() {
        // End to end with the real font: after padding, the short title rounds up to the same
        // whole width AppKit would give the long one, which is what keeps the item still.
        let shortTitle = title("8% / 32%")
        let longTitle = title("100% / 100%")
        let padding = MenuBarWidth.trailingPadding(currentTextWidth: shortTitle.size().width, currentImageWidth: 18,
                                                   otherTextWidth: longTitle.size().width, otherImageWidth: 18)
        let padded = MenuBarWidth.pad(shortTitle, by: padding, font: MenuBarTitle.font)
        XCTAssertEqual(ceil(padded.size().width), ceil(longTitle.size().width))
    }
}

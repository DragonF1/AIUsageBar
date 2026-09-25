import XCTest
@testable import AIUsageBar

/// `PopoverTicker.shouldAdvanceNow` decides whether the popover's 1s tick is worth a state
/// write: every second while a reset is under a minute away, so its seconds count down live,
/// otherwise only when the minute rolled over.
final class PopoverTickerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000) // an arbitrary whole minute

    func testAdvancesEverySecondWhenTheSoonestResetIsUnderAMinuteAway() {
        let previous = base
        let current = base.addingTimeInterval(1)
        let soonestReset = base.addingTimeInterval(45)
        XCTAssertTrue(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }

    func testDoesNotAdvanceWithinTheSameMinuteWhenNothingIsCloseEnough() {
        let previous = base
        let current = base.addingTimeInterval(1)
        let soonestReset = base.addingTimeInterval(600) // 10 minutes out
        XCTAssertFalse(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }

    func testAdvancesWhenNoResetIsShowingButTheMinuteRolledOver() {
        let previous = base.addingTimeInterval(59)
        let current = base.addingTimeInterval(60)
        XCTAssertTrue(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: nil))
    }

    func testDoesNotAdvanceMidMinuteWithNoResetShowing() {
        let previous = base.addingTimeInterval(10)
        let current = base.addingTimeInterval(11)
        XCTAssertFalse(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: nil))
    }

    func testAdvancesOnTheTickThatCrossesTheResetInstant() {
        // The reset lands between two ticks mid-minute: the second tick must still advance, or
        // the popover would show "1s left" for a limit that already reset until the minute rolls.
        let previous = base.addingTimeInterval(30)
        let current = base.addingTimeInterval(31)
        let soonestReset = base.addingTimeInterval(30.5)
        XCTAssertTrue(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }

    func testAResetThatPassedBeforeThePreviousTickDoesNotForceEverySecondTicks() {
        let previous = base.addingTimeInterval(31)
        let current = base.addingTimeInterval(32)
        let soonestReset = base.addingTimeInterval(30.5) // already crossed on an earlier tick
        XCTAssertFalse(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }

    func testAResetThatHasAlreadyPassedDoesNotForceEverySecondTicks() {
        let previous = base
        let current = base.addingTimeInterval(1)
        let soonestReset = base.addingTimeInterval(-5) // already reset
        XCTAssertFalse(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }

    func testAResetExactlyOnTheSixtySecondBoundaryDoesNotForceEverySecondTicks() {
        let previous = base
        let current = base.addingTimeInterval(1)
        let soonestReset = current.addingTimeInterval(60) // 60s from current is not "under a minute away"
        XCTAssertFalse(PopoverTicker.shouldAdvanceNow(previous: previous, current: current, soonestReset: soonestReset))
    }
}

import XCTest
@testable import AIUsageBar

final class MenuBarTemplateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_120_800)

    func testDefaultTemplateMatchesTheOriginalLayout() {
        let values = MenuBarValues(sessionPercent: 34, weeklyPercent: 58, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render(Preferences.defaultMenuBarFormat, values: values), " 34% / 58%")
    }

    func testEmptyTemplateDrawsNothing() {
        let values = MenuBarValues(sessionPercent: 34, weeklyPercent: 58, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("", values: values), "")
    }

    func testUnknownTokenPassesThroughVerbatim() {
        let values = MenuBarValues(sessionPercent: 34, weeklyPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{5h} {oops}", values: values), "34% {oops}")
    }

    func testFiveHourAndWeekTokens() {
        let values = MenuBarValues(sessionPercent: 12, weeklyPercent: 88, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{5h}|{week}", values: values), "12%|88%")
    }

    func testShowRemainingFlipsBothPercentTokens() {
        let values = MenuBarValues(sessionPercent: 34, weeklyPercent: 42, sessionResetsAt: nil, weeklyResetsAt: nil,
                                    todayCost: nil, now: now, showRemaining: true)
        XCTAssertEqual(MenuBarTemplate.render("{5h}/{week}", values: values), "66%/58%")
    }

    func testResetTokensCountDownFromNow() {
        let values = MenuBarValues(sessionPercent: nil, weeklyPercent: nil,
                                    sessionResetsAt: now.addingTimeInterval(130 * 60),
                                    weeklyResetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600),
                                    todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{reset5h} {resetWeek}", values: values), "2h 10m 3d 4h")
    }

    func testResetTokensAreADashWhenMissingOrPast() {
        let missing = MenuBarValues(sessionPercent: nil, weeklyPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                     todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{reset5h}", values: missing), "–")

        let past = MenuBarValues(sessionPercent: nil, weeklyPercent: nil,
                                  sessionResetsAt: now.addingTimeInterval(-5), weeklyResetsAt: nil,
                                  todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{reset5h}", values: past), "–")
    }

    func testCostTokenFormatsDollarsOrADashWhenMissing() {
        let withCost = MenuBarValues(sessionPercent: nil, weeklyPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                      todayCost: 12.3, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{cost}", values: withCost), "$12.30")

        let withoutCost = MenuBarValues(sessionPercent: nil, weeklyPercent: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
                                         todayCost: nil, now: now, showRemaining: false)
        XCTAssertEqual(MenuBarTemplate.render("{cost}", values: withoutCost), "–")
    }

    func testTokensListsExactlyTheFiveSubstitutions() {
        XCTAssertEqual(MenuBarTemplate.tokens, ["{5h}", "{week}", "{reset5h}", "{resetWeek}", "{cost}"])
    }
}

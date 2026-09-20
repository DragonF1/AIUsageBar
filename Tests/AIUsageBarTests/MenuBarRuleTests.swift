import XCTest
@testable import AIUsageBar

final class MenuBarRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_120_800)

    private func values(session: Double? = nil, weekly: Double? = nil, showRemaining: Bool = false) -> MenuBarValues {
        MenuBarValues(sessionPercent: session, weeklyPercent: weekly, sessionResetsAt: nil, weeklyResetsAt: nil,
                     todayCost: nil, now: now, showRemaining: showRemaining)
    }

    // MARK: - Codable

    func testCodableRoundTripPercentRule() throws {
        let rule = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(80)),
                               format: "HOT {5h}")
        let decoded = try XCTUnwrap(MenuBarRule.decodeList(MenuBarRule.encodeList([rule])).first)
        XCTAssertEqual(decoded, rule)
    }

    func testCodableRoundTripBandRule() throws {
        let rule = MenuBarRule(condition: MenuBarCondition(window: .weekly, comparison: .under, threshold: .band(.high)),
                               format: "{week}")
        let decoded = try XCTUnwrap(MenuBarRule.decodeList(MenuBarRule.encodeList([rule])).first)
        XCTAssertEqual(decoded, rule)
    }

    // MARK: - Lenient decoding

    func testDecodeListDropsUnreadableRulesAndKeepsTheGoodOne() {
        let json = """
        [
          {"id": "11111111-1111-1111-1111-111111111111",
           "condition": {"window": "monthly", "comparison": "atLeast", "threshold": {"percent": {"_0": 10}}},
           "format": "bad window"},
          {"tokens": {"_0": 1}},
          42,
          {"id": "22222222-2222-2222-2222-222222222222",
           "condition": {"window": "session", "comparison": "atLeast", "threshold": {"percent": {"_0": 80}}},
           "format": "HOT {5h}"}
        ]
        """
        let decoded = MenuBarRule.decodeList(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.format, "HOT {5h}")
    }

    func testDecodeListNilOrGarbageIsEmpty() {
        XCTAssertEqual(MenuBarRule.decodeList(nil), [])
        XCTAssertEqual(MenuBarRule.decodeList(Data([0x00, 0x01, 0xFF])), [])
    }

    func testMissingIdGetsAFreshUUIDEachDecode() throws {
        let json = """
        [{"condition": {"window": "session", "comparison": "atLeast", "threshold": {"percent": {"_0": 50}}}, "format": "x"}]
        """
        let first = try XCTUnwrap(MenuBarRule.decodeList(Data(json.utf8)).first)
        let second = try XCTUnwrap(MenuBarRule.decodeList(Data(json.utf8)).first)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Level

    func testLevelRawValuesAndOrderStable() {
        XCTAssertEqual(UsageColor.Level.low.rawValue, "low")
        XCTAssertEqual(UsageColor.Level.medium.rawValue, "medium")
        XCTAssertEqual(UsageColor.Level.high.rawValue, "high")
        XCTAssertEqual(UsageColor.Level.critical.rawValue, "critical")
        XCTAssertLessThan(UsageColor.Level.low, .medium)
        XCTAssertLessThan(UsageColor.Level.medium, .high)
        XCTAssertLessThan(UsageColor.Level.high, .critical)
        XCTAssertFalse(UsageColor.Level.critical < .low)
    }

    // MARK: - Matching

    func testFirstMatchWinsInOrder() {
        let first = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(10)),
                                format: "first")
        let second = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(50)),
                                 format: "second")
        let winner = MenuBarRules.winner(for: values(session: 80), rules: [first, second], scale: .default)
        XCTAssertEqual(winner?.format, "first")
    }

    func testAtLeastIsInclusiveForPercent() {
        let condition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(80))
        XCTAssertTrue(condition.matches(values(session: 80), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 79.9), scale: .default))
    }

    func testUnderIsStrictForPercent() {
        let condition = MenuBarCondition(window: .session, comparison: .under, threshold: .percent(80))
        XCTAssertTrue(condition.matches(values(session: 79.9), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 80), scale: .default))
    }

    func testBandHonoursACustomScale() {
        let condition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .band(.medium))
        var custom = ColorScale.default
        custom.mediumCutoff = 60
        XCTAssertTrue(condition.matches(values(session: 65), scale: custom))
        XCTAssertFalse(condition.matches(values(session: 65), scale: .default), "65% is still Low on the default 75 cutoff")
    }

    func testBandUnderIsStrict() {
        let condition = MenuBarCondition(window: .session, comparison: .under, threshold: .band(.high))
        XCTAssertTrue(condition.matches(values(session: 84.9), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 85), scale: .default))
    }

    func testNilPercentNeverMatches() {
        let percentCondition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(0))
        let bandCondition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .band(.low))
        XCTAssertFalse(percentCondition.matches(values(), scale: .default))
        XCTAssertFalse(bandCondition.matches(values(), scale: .default))
    }

    func testWeeklyWindowReadsWeeklyPercent() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(50))
        XCTAssertTrue(condition.matches(values(session: 10, weekly: 60), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 90, weekly: 10), scale: .default))
    }

    // MARK: - Resolver

    func testFallbackWhenNoRulesOrNoneMatch() {
        XCTAssertEqual(MenuBarRules.format(for: values(session: 80), rules: [], fallback: "fallback", scale: .default), "fallback")
        let rule = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(90)),
                               format: "hot")
        XCTAssertEqual(MenuBarRules.format(for: values(session: 80), rules: [rule], fallback: "fallback", scale: .default), "fallback")
    }

    func testPercentTestReadsUsedEvenWhenShowRemainingIsOn() {
        let rule = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(70)),
                               format: "{5h}")
        let v = values(session: 80, showRemaining: true)
        let format = MenuBarRules.format(for: v, rules: [rule], fallback: "fallback", scale: .default)
        XCTAssertEqual(format, "{5h}")
        XCTAssertEqual(MenuBarTemplate.render(format, values: v), "20%")
    }
}

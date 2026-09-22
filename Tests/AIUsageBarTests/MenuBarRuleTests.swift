import XCTest
@testable import AIUsageBar

final class MenuBarRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_120_800)

    private func values(session: Double? = nil, weekly: Double? = nil, showRemaining: Bool = false,
                        readings: [QuotaReading] = []) -> MenuBarValues {
        MenuBarValues(sessionPercent: session, weeklyPercent: weekly, sessionResetsAt: nil, weeklyResetsAt: nil,
                     todayCost: nil, now: now, showRemaining: showRemaining, readings: readings)
    }

    private func reading(id: String, product: String = "Claude Code", name: String = "Fable weekly",
                         window: QuotaReading.Window = .weekly, percent: Double, resetsAt: Date? = nil,
                         scope: String = "claude|Fable|", scopeName: String = "Fable") -> QuotaReading {
        QuotaReading(id: id, product: product, name: name, window: window, percent: percent, resetsAt: resetsAt,
                    scope: scope, scopeName: scopeName)
    }

    // MARK: - Comparison titles

    /// The picker walks `allCases` in declaration order, so this also pins that order: least to
    /// most.
    func testComparisonTitlesAndOrder() {
        XCTAssertEqual(MenuBarComparison.allCases.map(\.title),
                       ["less than", "less than or equal to", "equal to", "greater than or equal to", "greater than"])
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

    func testCodableRoundTripNewComparisonCases() throws {
        let rules = [
            MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atMost, threshold: .percent(30)), format: "a"),
            MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .equal, threshold: .percent(50)), format: "b"),
            MenuBarRule(condition: MenuBarCondition(window: .weekly, comparison: .over, threshold: .band(.medium)), format: "c"),
        ]
        let decoded = MenuBarRule.decodeList(MenuBarRule.encodeList(rules))
        XCTAssertEqual(decoded, rules)
    }

    /// `atLeast` and `under` are the two raw values that predate the other three cases and are
    /// already sitting in users' UserDefaults; a rename here would make `decodeList` silently
    /// drop every stored rule, so both must keep decoding forever.
    func testLegacyRawValuesStillDecode() throws {
        let json = """
        [{"condition": {"window": "session", "comparison": "atLeast", "threshold": {"percent": {"_0": 80}}}, "format": "hot"},
         {"condition": {"window": "session", "comparison": "under", "threshold": {"percent": {"_0": 20}}}, "format": "cold"}]
        """
        let decoded = MenuBarRule.decodeList(Data(json.utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].condition.comparison, .atLeast)
        XCTAssertEqual(decoded[0].format, "hot")
        XCTAssertEqual(decoded[1].condition.comparison, .under)
        XCTAssertEqual(decoded[1].format, "cold")
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

    func testAtMostIsInclusiveForPercent() {
        let condition = MenuBarCondition(window: .session, comparison: .atMost, threshold: .percent(80))
        XCTAssertTrue(condition.matches(values(session: 80), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 80.1), scale: .default))
    }

    func testOverIsStrictForPercent() {
        let condition = MenuBarCondition(window: .session, comparison: .over, threshold: .percent(80))
        XCTAssertFalse(condition.matches(values(session: 80), scale: .default))
        XCTAssertTrue(condition.matches(values(session: 80.1), scale: .default))
    }

    /// "Equal to" rounds the live percent the same way the menu bar's own text does
    /// (`PercentText`), so a rule that reads "equal to 3" fires on whatever the user would see
    /// displayed as "3%" rather than only the exact value 3.0.
    func testEqualForPercentUsesTheSameRoundingAsTheDisplayedText() {
        let condition = MenuBarCondition(window: .session, comparison: .equal, threshold: .percent(3))
        XCTAssertTrue(condition.matches(values(session: 2.6), scale: .default))
        XCTAssertTrue(condition.matches(values(session: 3.4), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 3.5), scale: .default))
        XCTAssertFalse(condition.matches(values(session: 4), scale: .default))
    }

    func testAtMostForBand() {
        let condition = MenuBarCondition(window: .session, comparison: .atMost, threshold: .band(.medium))
        XCTAssertTrue(condition.matches(values(session: 50), scale: .default), "50% is Low")
        XCTAssertTrue(condition.matches(values(session: 80), scale: .default), "80% is Medium")
        XCTAssertFalse(condition.matches(values(session: 90), scale: .default), "90% is High")
    }

    func testEqualForBand() {
        let condition = MenuBarCondition(window: .session, comparison: .equal, threshold: .band(.medium))
        XCTAssertTrue(condition.matches(values(session: 80), scale: .default), "80% is Medium")
        XCTAssertFalse(condition.matches(values(session: 90), scale: .default), "90% is High")
        XCTAssertFalse(condition.matches(values(session: 50), scale: .default), "50% is Low")
    }

    func testOverForBand() {
        let condition = MenuBarCondition(window: .session, comparison: .over, threshold: .band(.medium))
        XCTAssertFalse(condition.matches(values(session: 80), scale: .default), "80% is Medium")
        XCTAssertFalse(condition.matches(values(session: 50), scale: .default), "50% is Low")
        XCTAssertTrue(condition.matches(values(session: 90), scale: .default), "90% is High")
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

    // MARK: - Limit rules

    func testLimitRuleMatchesWhenIdPresentAndComparisonHolds() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(80),
                                         limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        let v = values(readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 85)])
        XCTAssertTrue(condition.matches(v, scale: .default))
    }

    func testLimitRuleDoesNotMatchWhenComparisonFails() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(80),
                                         limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        let v = values(readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 40)])
        XCTAssertFalse(condition.matches(v, scale: .default))
    }

    func testLimitRuleNeverMatchesWhenIdIsAbsent() {
        let condition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(0),
                                         limit: MenuBarLimitRef(scope: "antigravity|Gemini Models", product: "Antigravity", name: "Gemini"))
        let v = values(session: 90, weekly: 90, readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 100)])
        XCTAssertFalse(condition.matches(v, scale: .default))
    }

    /// A limit rule fires whichever tab the popover happens to be showing: neither direction of
    /// mismatch between the targeted limit and the tab's own session/weekly percent should sway
    /// it.
    func testLimitRuleFiresRegardlessOfTheCurrentTabsWindowPercent() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(80),
                                         limit: MenuBarLimitRef(scope: "antigravity|Gemini Models", product: "Antigravity", name: "Gemini"))
        // The "current tab" numbers would fail the threshold; the targeted limit alone decides.
        let matches = values(session: 5, weekly: 5,
                             readings: [reading(id: "antigravity|Gemini Models|gemini-weekly", product: "Antigravity", name: "Gemini weekly",
                                                window: .weekly, percent: 90, scope: "antigravity|Gemini Models", scopeName: "Gemini")])
        XCTAssertTrue(condition.matches(matches, scale: .default))

        // And vice versa: the tab's own numbers would pass, but the targeted limit does not.
        let doesNotMatch = values(session: 95, weekly: 95,
                                  readings: [reading(id: "antigravity|Gemini Models|gemini-weekly", product: "Antigravity", name: "Gemini weekly",
                                                     window: .weekly, percent: 10, scope: "antigravity|Gemini Models", scopeName: "Gemini")])
        XCTAssertFalse(condition.matches(doesNotMatch, scale: .default))
    }

    func testWindowRuleIgnoresReadings() {
        let condition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(80))
        // A reading that would match if this were a limit rule must not sway a window rule.
        let v = values(session: 10, readings: [reading(id: "claude|session||", window: .fiveHour, percent: 95,
                                                        scope: "claude||", scopeName: "All models")])
        XCTAssertFalse(condition.matches(v, scale: .default))
    }

    /// The scope alone does not pick a window: the same Gemini scope carries both a 5-hour and a
    /// weekly reading, and the rule's own `window` decides which one a limit rule reads, exactly
    /// as it would for a tab-relative rule.
    func testLimitRuleWindowPicksWhichOfTheScopesReadingsIsRead() {
        let scope = "antigravity|Gemini Models"
        let fiveHour = reading(id: "antigravity|Gemini Models|gemini-5h", product: "Antigravity", name: "Gemini 5h",
                               window: .fiveHour, percent: 30, scope: scope, scopeName: "Gemini")
        let weekly = reading(id: "antigravity|Gemini Models|gemini-weekly", product: "Antigravity", name: "Gemini weekly",
                             window: .weekly, percent: 70, scope: scope, scopeName: "Gemini")
        let v = values(readings: [fiveHour, weekly])

        let sessionCondition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(0),
                                                limit: MenuBarLimitRef(scope: scope, product: "Antigravity", name: "Gemini"))
        XCTAssertEqual(sessionCondition.reading(in: v).percent, 30)

        let weeklyCondition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0),
                                               limit: MenuBarLimitRef(scope: scope, product: "Antigravity", name: "Gemini"))
        XCTAssertEqual(weeklyCondition.reading(in: v).percent, 70)
    }

    /// Fable has no 5-hour reading at all: a rule that targets its scope with `.session` finds
    /// nothing to read and never matches, while `.weekly` reaches its one reading.
    func testLimitRuleOnAScopeWithNoFiveHourReadingNeverMatchesSession() {
        let v = values(readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 85)])
        let sessionCondition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(0),
                                                limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        XCTAssertFalse(sessionCondition.matches(v, scale: .default))

        let weeklyCondition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0),
                                               limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        XCTAssertTrue(weeklyCondition.matches(v, scale: .default))
    }

    /// Extra usage has only a `.monthly` reading, with no 5-hour/weekly choice to make: either
    /// window setting reaches it.
    func testLimitRuleOnAMonthlyOnlyScopeMatchesEitherWindow() {
        let v = values(readings: [reading(id: "claude|extra_usage", product: "Claude Code", name: "Extra usage",
                                          window: .monthly, percent: 90, scope: "claude|extra_usage", scopeName: "Extra usage")])
        let sessionCondition = MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(0),
                                                limit: MenuBarLimitRef(scope: "claude|extra_usage", product: "Claude Code", name: "Extra usage"))
        XCTAssertTrue(sessionCondition.matches(v, scale: .default))

        let weeklyCondition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0),
                                               limit: MenuBarLimitRef(scope: "claude|extra_usage", product: "Claude Code", name: "Extra usage"))
        XCTAssertTrue(weeklyCondition.matches(v, scale: .default))
    }

    // MARK: - reading(in:)

    func testReadingInReturnsTheTargetedLimitsPercentAndReset() {
        let resetsAt = now.addingTimeInterval(3600)
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0),
                                         limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        let v = values(readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 62, resetsAt: resetsAt)])
        let result = condition.reading(in: v)
        XCTAssertEqual(result.percent, 62)
        XCTAssertEqual(result.resetsAt, resetsAt)
    }

    func testReadingInReturnsNilForAnAbsentLimit() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0),
                                         limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        let result = condition.reading(in: values())
        XCTAssertNil(result.percent)
        XCTAssertNil(result.resetsAt)
    }

    func testReadingInReturnsTheWindowsPercentAndResetForAWindowRule() {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(0))
        var v = values(weekly: 44)
        v.weeklyResetsAt = now.addingTimeInterval(7200)
        let result = condition.reading(in: v)
        XCTAssertEqual(result.percent, 44)
        XCTAssertEqual(result.resetsAt, v.weeklyResetsAt)
    }

    // MARK: - Codable (limit)

    /// Every rule saved before this feature existed has no `limit` key at all; the synthesized
    /// Codable conformance must still decode it, with `limit` reading as nil.
    func testConditionDecodesWithoutLimitKey() throws {
        let json = """
        {"window": "session", "comparison": "atLeast", "threshold": {"percent": {"_0": 80}}}
        """
        let condition = try JSONDecoder().decode(MenuBarCondition.self, from: Data(json.utf8))
        XCTAssertNil(condition.limit)
        XCTAssertEqual(condition.window, .session)
    }

    func testConditionRoundTripsWithALimit() throws {
        let condition = MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(80),
                                         limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable"))
        let data = try JSONEncoder().encode(condition)
        let decoded = try JSONDecoder().decode(MenuBarCondition.self, from: data)
        XCTAssertEqual(decoded, condition)
    }

    /// The same absent-key tolerance one level up, through a whole rule and `decodeList`, the
    /// path old rules on disk actually take.
    func testOldRuleJSONWithoutLimitKeyStillDecodesThroughDecodeList() throws {
        let json = """
        [{"condition": {"window": "session", "comparison": "atLeast", "threshold": {"percent": {"_0": 80}}}, "format": "hot"}]
        """
        let decoded = MenuBarRule.decodeList(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded.first?.condition.limit)
        XCTAssertEqual(decoded.first?.format, "hot")
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

    func testResolveFillsMatchedFieldsForALimitWinner() {
        let resetsAt = now.addingTimeInterval(3600)
        let rule = MenuBarRule(condition: MenuBarCondition(window: .weekly, comparison: .atLeast, threshold: .percent(50),
                                                           limit: MenuBarLimitRef(scope: "claude|Fable|", product: "Claude Code", name: "Fable")),
                               format: "{value}")
        let v = values(readings: [reading(id: "claude|weekly_scoped|Fable|", percent: 62, resetsAt: resetsAt)])
        let resolved = MenuBarRules.resolve(for: v, rules: [rule], fallback: "fallback", scale: .default)
        XCTAssertEqual(resolved.format, "{value}")
        XCTAssertEqual(resolved.values.matchedPercent, 62)
        XCTAssertEqual(resolved.values.matchedResetsAt, resetsAt)
    }

    func testResolveFillsMatchedFieldsForAWindowWinner() {
        let rule = MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: .percent(50)), format: "{value}")
        var v = values(session: 70)
        v.sessionResetsAt = now.addingTimeInterval(1800)
        let resolved = MenuBarRules.resolve(for: v, rules: [rule], fallback: "fallback", scale: .default)
        XCTAssertEqual(resolved.format, "{value}")
        XCTAssertEqual(resolved.values.matchedPercent, 70)
        XCTAssertEqual(resolved.values.matchedResetsAt, v.sessionResetsAt)
    }

    func testResolveLeavesMatchedFieldsNilOnFallback() {
        let resolved = MenuBarRules.resolve(for: values(session: 10), rules: [], fallback: "fallback", scale: .default)
        XCTAssertEqual(resolved.format, "fallback")
        XCTAssertNil(resolved.values.matchedPercent)
        XCTAssertNil(resolved.values.matchedResetsAt)
    }
}

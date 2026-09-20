import XCTest
@testable import AIUsageBar

final class FakeNotifier: Notifier {
    var posted: [QuotaNotification] = []
    var authorizationRequests = 0
    func requestAuthorization() { authorizationRequests += 1 }
    func post(_ notification: QuotaNotification) { posted.append(notification) }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

private func reading(_ percent: Double, id: String = "claude|session||", window: QuotaReading.Window = .fiveHour,
                     resetsAt: Date? = hours(2)) -> QuotaReading
{
    QuotaReading(id: id, product: "Claude Code", name: window == .fiveHour ? "All models 5h" : "All models weekly",
                 window: window, percent: percent, resetsAt: resetsAt)
}

/// A weekly reading: minutes between polls never reach the weekly pace span, so only the thresholds speak.
private func weekly(_ percent: Double, resetsAt: Date = hours(100)) -> QuotaReading {
    reading(percent, id: "claude|weekly_all||", window: .weekly, resetsAt: resetsAt)
}

// MARK: - Readings

final class QuotaReadingTests: XCTestCase {
    func testClaudeReadingsFollowTheDisplayedLimits() throws {
        let usage = try UsageClient.decoder.decode(UsageResponse.self, from: sampleUsage)
        let readings = usage.readings
        XCTAssertEqual(readings.map(\.id), ["claude|session||", "claude|weekly_all||", "claude|weekly_scoped|Fable|"])
        XCTAssertEqual(readings.map(\.name), ["All models 5h", "All models weekly", "Fable weekly"])
        XCTAssertEqual(readings.map(\.window), [.fiveHour, .weekly, .weekly])
        XCTAssertEqual(readings.map(\.percent), [6, 32, 44])
        XCTAssertEqual(readings[0].product, "Claude Code")
        XCTAssertEqual(readings[0].resetsAt, usage.fiveHour?.resetsAt)
    }

    func testLimitWithoutPercentIsSkipped() {
        XCTAssertNil(QuotaReading.claude(UsageResponse.Limit(kind: "session")))
    }

    func testExtraUsageJoinsTheReadingsOnlyWhenAskedAndEnabled() throws {
        let disabled = try UsageClient.decoder.decode(UsageResponse.self, from: sampleUsage)
        XCTAssertEqual(disabled.readings(extraUsage: true).count, 3, "the account has no credits")

        var enabled = disabled
        enabled.extraUsage = UsageResponse.ExtraUsage(isEnabled: true, utilization: 24.8, usedCredits: 1240,
                                                       monthlyLimit: 5000, currency: "USD", decimalPlaces: 2)
        XCTAssertEqual(enabled.readings(extraUsage: false).count, 3, "the switch is off")
        let readings = enabled.readings(extraUsage: true)
        XCTAssertEqual(readings.count, 4)
        XCTAssertEqual(readings[3].id, "claude|extra_usage")
        XCTAssertEqual(readings[3].name, "Extra usage")
        XCTAssertEqual(readings[3].window, .monthly)
        XCTAssertEqual(readings[3].percent, 24.8)
        XCTAssertNil(readings[3].resetsAt)
    }

    func testExtraUsageTextAndPercent() {
        let extra = UsageResponse.ExtraUsage(isEnabled: true, utilization: nil, usedCredits: 1240,
                                             monthlyLimit: 5000, currency: "USD", decimalPlaces: 2)
        XCTAssertEqual(extra.detailText, "$12.40 of $50.00 this month")
        XCTAssertEqual(extra.percent, 24.8, "used over limit when the endpoint gives no utilization")
        XCTAssertEqual(UsageResponse.ExtraUsage.money(1234.5, "EUR"), "€1,234.50")
        XCTAssertEqual(UsageResponse.ExtraUsage.money(3, nil), "$3.00", "dollars when the currency is missing")

        let empty = UsageResponse.ExtraUsage(isEnabled: false)
        XCTAssertFalse(empty.isActive)
        XCTAssertNil(empty.percent)
        XCTAssertNil(empty.detailText)
        XCTAssertNil(QuotaReading.extraUsage(empty))
    }

    @MainActor func testExtraUsageThresholdNotifiesWithoutAReset() {
        let notifier = FakeNotifier()
        let monitor = QuotaMonitor(notifier: notifier, cacheURL: nil)
        monitor.isEnabled = { true }
        let extra = QuotaReading(id: "claude|extra_usage", product: "Claude Code", name: "Extra usage",
                                 window: .monthly, percent: 81, resetsAt: nil)
        monitor.observe([extra], now: t0)
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: Extra usage at 81%"])
        XCTAssertNil(monitor.paceLine(for: extra.id, window: .monthly, now: minutes(30)), "no reset time, no pace")
    }

    func testAntigravityReadingsCoverEveryBucket() throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        let readings = AntigravityUsage(summary: summary).readings
        XCTAssertEqual(readings.map(\.id), ["antigravity|Gemini Models|gemini-5h", "antigravity|Gemini Models|gemini-weekly",
                                            "antigravity|Claude and GPT models|3p-5h", "antigravity|Claude and GPT models|3p-weekly"])
        XCTAssertEqual(readings.map(\.name), ["Gemini 5h", "Gemini weekly", "Claude and GPT 5h", "Claude and GPT weekly"])
        XCTAssertEqual(readings.map(\.window), [.fiveHour, .weekly, .fiveHour, .weekly])
        XCTAssertEqual(readings[1].percent, 51.5)
        XCTAssertEqual(readings[1].product, "Antigravity")
    }
}

// MARK: - Pace

final class PaceTrackerTests: XCTestCase {
    func testOneSampleHasNoForecast() {
        var pace = PaceTracker()
        pace.record(reading(10), at: t0)
        XCTAssertNil(pace.forecast(for: "claude|session||", now: minutes(1)))
    }

    func testRunsOutBeforeTheReset() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(30), at: minutes(15))   // 2 points a minute, 105 minutes to the reset
        XCTAssertEqual(pace.forecast(for: "claude|session||", now: minutes(16)), .runsOut(at: minutes(50)))
    }

    func testLandsUnderTheCapAtTheReset() throws {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(3), at: minutes(15))    // 0.2 points a minute, 105 minutes to go: 24
        guard case .atReset(let percent)? = pace.forecast(for: "claude|session||", now: minutes(16)) else {
            return XCTFail("expected an at-reset forecast")
        }
        XCTAssertEqual(percent, 24, accuracy: 0.001)
    }

    func testNeedsTheMinimumSpan() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(30), at: minutes(9))
        XCTAssertNil(pace.forecast(for: "claude|session||", now: minutes(9)))
        pace.record(reading(33), at: minutes(10))
        XCTAssertNotNil(pace.forecast(for: "claude|session||", now: minutes(10)))

        var weekly = PaceTracker()
        let id = "claude|weekly_all||"
        weekly.record(reading(0, id: id, window: .weekly, resetsAt: hours(100)), at: t0)
        weekly.record(reading(10, id: id, window: .weekly, resetsAt: hours(100)), at: hours(1.9))
        XCTAssertNil(weekly.forecast(for: id, now: hours(1.9)))
        weekly.record(reading(11, id: id, window: .weekly, resetsAt: hours(100)), at: hours(2))
        XCTAssertNotNil(weekly.forecast(for: id, now: hours(2)))
    }

    func testOnlyRecentSamplesSetTheRate() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(50), at: minutes(30))   // an early burst, outside the hour by `now`
        pace.record(reading(52), at: minutes(90))
        pace.record(reading(56), at: minutes(110))  // 0.2 a minute over the last 20 minutes; 10 minutes left
        guard case .atReset(let percent)? = pace.forecast(for: "claude|session||", now: minutes(110)) else {
            return XCTFail("expected an at-reset forecast")
        }
        XCTAssertEqual(percent, 58, accuracy: 0.001)
    }

    func testFlatUsedUpOrPastResetHasNoForecast() {
        var pace = PaceTracker()
        pace.record(reading(20), at: t0)
        pace.record(reading(20), at: minutes(15))
        XCTAssertNil(pace.forecast(for: "claude|session||", now: minutes(15)), "flat")

        var full = PaceTracker()
        full.record(reading(90), at: t0)
        full.record(reading(100), at: minutes(15))
        XCTAssertNil(full.forecast(for: "claude|session||", now: minutes(15)), "used up")

        var late = PaceTracker()
        late.record(reading(0), at: t0)
        late.record(reading(30), at: minutes(15))
        XCTAssertNil(late.forecast(for: "claude|session||", now: hours(2)), "reset passed")
    }

    func testPaceThatAlreadyRanOutWaitsForTheNextPoll() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(90), at: minutes(15))   // out at minute 16.7 by the line
        XCTAssertNil(pace.forecast(for: "claude|session||", now: minutes(20)))
    }

    func testDropStartsANewCycle() {
        var pace = PaceTracker()
        XCTAssertFalse(pace.record(reading(80), at: t0))
        XCTAssertFalse(pace.record(reading(76), at: minutes(5)), "a wobble is not a reset")
        XCTAssertTrue(pace.record(reading(3, resetsAt: hours(7)), at: minutes(10)))
        XCTAssertEqual(pace.series["claude|session||"]?.samples.count, 1)
        XCTAssertEqual(pace.series["claude|session||"]?.resetsAt, hours(7))
    }

    func testMovedResetStartsANewCycle() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(0, resetsAt: hours(2).addingTimeInterval(30)), at: minutes(5))
        XCTAssertEqual(pace.series["claude|session||"]?.samples.count, 2, "half a minute of drift is not a reset")
        XCTAssertTrue(pace.record(reading(0, resetsAt: hours(7)), at: minutes(10)))
        XCTAssertEqual(pace.series["claude|session||"]?.samples.count, 1)
    }

    func testKeepsTheLastResetWhenAPollHasNone() {
        var pace = PaceTracker()
        pace.record(reading(0), at: t0)
        pace.record(reading(30, resetsAt: nil), at: minutes(15))
        XCTAssertEqual(pace.series["claude|session||"]?.resetsAt, hours(2))
        XCTAssertNotNil(pace.forecast(for: "claude|session||", now: minutes(15)))
    }

    func testCapsTheSamplesKept() {
        var pace = PaceTracker()
        for i in 0..<(PaceTracker.maxSamples + 10) {
            pace.record(reading(Double(i) / 100, resetsAt: hours(100)), at: minutes(Double(i)))
        }
        XCTAssertEqual(pace.series["claude|session||"]?.samples.count, PaceTracker.maxSamples)
        XCTAssertEqual(pace.series["claude|session||"]?.samples.first?.at, minutes(10))
    }

    func testPaceLineWording() {
        let out = PaceLine(.runsOut(at: t0), window: .fiveHour)
        XCTAssertTrue(out.urgent)
        XCTAssertEqual(out.text, "At this pace: out at \(ResetText.clock(t0, window: .fiveHour))")
        let weekly = PaceLine(.runsOut(at: t0), window: .weekly)
        XCTAssertEqual(weekly.text, "At this pace: out at \(ResetText.clock(t0, window: .other))")
        XCTAssertTrue(ResetText.clock(t0, window: .other).hasPrefix(DateFormatter().weekdaySymbols[Calendar.current.component(.weekday, from: t0) - 1]))
        let under = PaceLine(.atReset(percent: 61.6), window: .fiveHour)
        XCTAssertFalse(under.urgent)
        XCTAssertEqual(under.text, "At this pace: ~62% at reset")
    }
}

// MARK: - Monitor

@MainActor
final class QuotaMonitorTests: XCTestCase {
    private var notifier = FakeNotifier()

    private func monitor(thresholds: [Double] = QuotaMonitor.defaultThresholds, enabled: Bool = true,
                         cacheURL: URL? = nil) -> QuotaMonitor
    {
        let m = QuotaMonitor(notifier: notifier, thresholds: thresholds, cacheURL: cacheURL)
        m.isEnabled = { enabled }
        return m
    }

    override func setUp() {
        notifier = FakeNotifier()
    }

    func testEachThresholdPostsOnceThenUsedUpOnce() {
        let m = monitor()
        m.observe([weekly(70)], now: t0)
        XCTAssertEqual(notifier.posted, [])
        m.observe([weekly(82)], now: minutes(5))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 82%"])
        XCTAssertEqual(notifier.posted[0].id, "claude|weekly_all|||at80")
        XCTAssertEqual(notifier.posted[0].body, ResetText.describe(hours(100), window: .other, now: minutes(5)))
        m.observe([weekly(84)], now: minutes(10))
        XCTAssertEqual(notifier.posted.count, 1, "still past the same threshold")
        m.observe([weekly(96)], now: minutes(15))
        XCTAssertEqual(notifier.posted.last?.title, "Claude Code: All models weekly at 96%")
        m.observe([weekly(100)], now: minutes(20))
        XCTAssertEqual(notifier.posted.last?.title, "Claude Code: All models weekly used up")
        m.observe([weekly(100)], now: minutes(25))
        XCTAssertEqual(notifier.posted.count, 3)
    }

    func testJumpingPastBothThresholdsPostsOnce() {
        let m = monitor()
        m.observe([weekly(10)], now: t0)
        m.observe([weekly(97)], now: minutes(5))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 97%"])
        m.observe([weekly(98)], now: minutes(10))
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testFirstSightingPastAThresholdWarns() {
        monitor().observe([reading(90)], now: t0)
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models 5h at 90%"])
        XCTAssertEqual(notifier.posted[0].body, ResetText.describe(hours(2), window: .fiveHour, now: t0))
    }

    func testResetAfterAWarningIsAnnouncedOnce() {
        let m = monitor()
        m.observe([weekly(90)], now: t0)
        m.observe([weekly(2, resetsAt: hours(200))], now: minutes(5))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 90%", "Claude Code: All models weekly reset"])
        XCTAssertEqual(notifier.posted[1].body, "Now at 2%. " + ResetText.describe(hours(200), window: .other, now: minutes(5))!)
        m.observe([weekly(3, resetsAt: hours(200))], now: minutes(10))
        XCTAssertEqual(notifier.posted.count, 2)
        // The new cycle warns again on its own.
        m.observe([weekly(81, resetsAt: hours(200))], now: minutes(15))
        XCTAssertEqual(notifier.posted.last?.title, "Claude Code: All models weekly at 81%")
    }

    func testResetWithoutAWarningIsSilent() {
        let m = monitor()
        m.observe([weekly(30)], now: t0)
        m.observe([weekly(2, resetsAt: hours(200))], now: minutes(5))
        XCTAssertEqual(notifier.posted, [])
    }

    func testCustomThresholdsAndNone() {
        let m = monitor(thresholds: [50])
        m.observe([weekly(49)], now: t0)
        m.observe([weekly(51)], now: minutes(5))
        m.observe([weekly(96)], now: minutes(10))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 51%"])

        let none = monitor(thresholds: [])
        none.observe([weekly(99)], now: t0)
        none.observe([weekly(100)], now: minutes(5))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 51%", "Claude Code: All models weekly used up"])
    }

    func testSwitchedOffAdvancesWithoutPostingOrReplaying() {
        let m = monitor(enabled: false)
        m.observe([weekly(90)], now: t0)
        XCTAssertEqual(notifier.posted, [])
        m.isEnabled = { true }
        m.observe([weekly(91)], now: minutes(5))
        XCTAssertEqual(notifier.posted, [], "80 was crossed while off; it is not replayed")
        m.observe([weekly(96)], now: minutes(10))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 96%"])
    }

    func testPaceWarningOncePerCycle() {
        let m = monitor()
        m.observe([reading(0)], now: t0)
        m.observe([reading(30)], now: minutes(15))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models 5h running out"])
        XCTAssertEqual(notifier.posted[0].id, "claude|session|||pace")
        XCTAssertEqual(notifier.posted[0].body,
                       "At this pace it is used up at \(ResetText.clock(minutes(50), window: .fiveHour)), "
                       + "before the reset at \(ResetText.clock(hours(2), window: .fiveHour)).")
        m.observe([reading(40)], now: minutes(20))
        XCTAssertEqual(notifier.posted.count, 1)
        // Slowing down changes the line in the popover but posts nothing more.
        XCTAssertEqual(m.paceLine(for: "claude|session||", window: .fiveHour, now: minutes(20))?.urgent, true)
        m.observe([reading(0, resetsAt: hours(7))], now: minutes(25))
        XCTAssertEqual(notifier.posted.last?.title, "Claude Code: All models 5h reset", "a pace warning counts as a warning")
        m.observe([reading(30, resetsAt: hours(7))], now: minutes(40))
        XCTAssertEqual(notifier.posted.map(\.title).last, "Claude Code: All models 5h running out", "a new cycle may warn again")
        XCTAssertEqual(notifier.posted.count, 3)
    }

    func testThresholdOutranksPaceInTheSamePoll() {
        let m = monitor()
        m.observe([reading(0)], now: t0)
        m.observe([reading(85)], now: minutes(15))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models 5h at 85%"])
        m.observe([reading(86)], now: minutes(20))
        XCTAssertEqual(notifier.posted.count, 1, "the pace was marked as warned alongside the threshold")
    }

    func testWindowsAreFollowedIndependently() {
        let m = monitor()
        let weekly = "claude|weekly_all||"
        m.observe([reading(10), reading(82, id: weekly, window: .weekly, resetsAt: hours(100))], now: t0)
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 82%"])
        m.observe([reading(85), reading(83, id: weekly, window: .weekly, resetsAt: hours(100))], now: minutes(5))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models weekly at 82%", "Claude Code: All models 5h at 85%"])
    }

    func testStateSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = monitor(cacheURL: url)
        first.observe([reading(0)], now: t0)
        first.observe([reading(90)], now: minutes(15))
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code: All models 5h at 90%"])

        let second = monitor(cacheURL: url)
        XCTAssertEqual(second.pace.series["claude|session||"]?.samples.count, 2)
        XCTAssertNotNil(second.forecast(for: "claude|session||", now: minutes(16)))
        second.observe([reading(91)], now: minutes(20))
        XCTAssertEqual(notifier.posted.count, 1, "the threshold and the pace were already announced")
        second.observe([reading(96)], now: minutes(25))
        XCTAssertEqual(notifier.posted.last?.title, "Claude Code: All models 5h at 96%")
    }

    func testNoCacheFileMeansAFreshStart() {
        let m = monitor(cacheURL: nil)
        XCTAssertTrue(m.pace.series.isEmpty)
    }
}

// MARK: - Settings

final class PreferenceModelTests: XCTestCase {
    func testIconMetricSessionIgnoresTheWeek() {
        XCTAssertEqual(UsageColor.icon(session: 10, weekly: 99, metric: .session), .green)
        XCTAssertEqual(UsageColor.icon(session: 75, weekly: 100, metric: .session), .yellow)
        XCTAssertEqual(UsageColor.icon(session: 85, weekly: 0, metric: .session), .red)
        XCTAssertEqual(UsageColor.icon(session: 95, weekly: 0, metric: .session), .darkRed)
        XCTAssertNil(UsageColor.icon(session: nil, weekly: 99, metric: .session))
    }

    func testIconMetricWeeklyIgnoresTheSession() {
        XCTAssertEqual(UsageColor.icon(session: 99, weekly: 10, metric: .weekly), .green)
        XCTAssertEqual(UsageColor.icon(session: 99, weekly: 75, metric: .weekly), .yellow)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 85, metric: .weekly), .red)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 94.9, metric: .weekly), .red)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 95, metric: .weekly), .darkRed)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 100, metric: .weekly), .darkRed)
        XCTAssertNil(UsageColor.icon(session: 50, weekly: nil, metric: .weekly))
    }

    func testIconMetricAutoIsTheOriginalRule() {
        XCTAssertEqual(UsageColor.icon(session: 10, weekly: 84.9, metric: .auto), .green)
        XCTAssertEqual(UsageColor.icon(session: 10, weekly: 85, metric: .auto), .red)
        XCTAssertEqual(UsageColor.icon(session: 10, weekly: 95, metric: .auto), .darkRed)
    }

    func testMetricRoundTripsThroughItsRawValue() {
        for metric in MenuBarMetric.allCases {
            XCTAssertEqual(MenuBarMetric(rawValue: metric.rawValue), metric)
        }
        XCTAssertNil(MenuBarMetric(rawValue: "bogus"))
    }

    func testThresholdsFromConfig() throws {
        func settings(_ json: String) throws -> AppConfig.Settings {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString).json")
            try json.data(using: .utf8)!.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return AppConfig.loadSettings(from: url)
        }
        XCTAssertEqual(try settings(#"{"claude": {"refresh": true}}"#).notificationThresholds, [80, 95])
        XCTAssertEqual(try settings(#"{"notifications": {"thresholds": [95, 50, 150, 0, 50]}}"#).notificationThresholds, [50, 95])
        XCTAssertEqual(try settings(#"{"notifications": {"thresholds": []}}"#).notificationThresholds, [])
        XCTAssertEqual(try settings(#"{"notifications": {}}"#).notificationThresholds, [80, 95])
    }

    @MainActor func testThresholdTextForTheMenu() {
        XCTAssertEqual(StatusItemController.thresholdText([80, 95]), "80% or 95%")
        XCTAssertEqual(StatusItemController.thresholdText([50, 80, 95]), "50%, 80% or 95%")
        XCTAssertEqual(StatusItemController.thresholdText([90]), "90%")
        XCTAssertEqual(StatusItemController.thresholdText([]), "no threshold")
    }
}

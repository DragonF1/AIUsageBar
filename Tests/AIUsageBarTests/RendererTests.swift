import XCTest
@testable import AIUsageBar

/// The `--render` flag's argument parsing and the fixture the screenshots are drawn from. The
/// drawing itself needs a window server, so it is exercised by `scripts/render-screenshots.sh`.
final class RendererTests: XCTestCase {
    @MainActor func testOptionsAbsentWithoutRenderFlag() throws {
        XCTAssertNil(try ScreenshotRenderer.options(from: ["AIUsageBar"]))
        XCTAssertNil(try ScreenshotRenderer.options(from: ["AIUsageBar", "--unregister-login"]))
    }

    @MainActor func testOptionsDefaultToLight() throws {
        let options = try XCTUnwrap(ScreenshotRenderer.options(from: ["AIUsageBar", "--render", "/tmp/shots"]))
        XCTAssertEqual(options.directory.path, "/tmp/shots")
        XCTAssertEqual(options.appearance, .aqua)
        XCTAssertEqual(options.suffix, "light")
    }

    @MainActor func testOptionsReadAppearance() throws {
        let dark = try XCTUnwrap(ScreenshotRenderer.options(from: ["x", "--appearance", "dark", "--render", "out"]))
        XCTAssertEqual(dark.appearance, .darkAqua)
        XCTAssertEqual(dark.suffix, "dark")
        let light = try XCTUnwrap(ScreenshotRenderer.options(from: ["x", "--render", "out", "--appearance", "light"]))
        XCTAssertEqual(light.suffix, "light")
    }

    @MainActor func testOptionsRejectMalformedArguments() {
        XCTAssertThrowsError(try ScreenshotRenderer.options(from: ["x", "--render"]))
        XCTAssertThrowsError(try ScreenshotRenderer.options(from: ["x", "--render", "out", "--appearance"]))
        XCTAssertThrowsError(try ScreenshotRenderer.options(from: ["x", "--render", "out", "--appearance", "blue"])) { error in
            XCTAssertEqual(error.localizedDescription, "unknown appearance blue; use light or dark")
        }
    }

    // MARK: - fixture

    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var fixture: ScreenshotFixture { ScreenshotFixture(now: now, home: "/Users/someone") }

    func testFixtureIsDeterministic() {
        let a = fixture, b = ScreenshotFixture(now: now, home: "/Users/someone")
        XCTAssertEqual(a.claudeRecords, b.claudeRecords)
        XCTAssertEqual(a.claudeSessions, b.claudeSessions)
        XCTAssertEqual(a.antigravityRecords, b.antigravityRecords)
        XCTAssertFalse(a.claudeRecords.isEmpty)
        XCTAssertFalse(a.antigravityRecords.isEmpty)
    }

    func testEveryClaudeRecordHasASessionWithAFolder() {
        let f = fixture
        let folders = Dictionary(uniqueKeysWithValues: f.claudeSessions.map { ($0.sessionId, $0.cwd) })
        for record in f.claudeRecords {
            let folder = record.sessionId.flatMap { folders[$0] } ?? nil
            XCTAssertNotNil(folder, "record \(record.timestamp) has no session folder")
            XCTAssertTrue(folder?.hasPrefix("/Users/someone/Code/") ?? false)
        }
        // So the cost window's BY PROJECT list has no "Unknown folder" row.
        let report = CostReport.build(f.claudeRecords, now: now, folders: folders.compactMapValues { $0 })
        XCTAssertEqual(report.projects.count, ScreenshotFixture.projects.count)
        XCTAssertFalse(report.projects.contains { $0.folder == nil })
    }

    @MainActor func testRecordsStayInsideTheChartWindow() {
        let f = fixture
        let start = TokenStore.costWindowStart(now: now)
        for record in f.claudeRecords + f.antigravityRecords {
            XCTAssertLessThanOrEqual(record.timestamp, now)
            XCTAssertGreaterThanOrEqual(record.timestamp, start)
        }
        XCTAssertEqual(f.claudeLive.map(\.sessionId), Array(f.claudeSessions.prefix(2).map(\.sessionId)))
    }

    func testSamplesRiseSoBothWindowsForecast() {
        let f = fixture
        let sessions = f.claudeSamples.map { $0.response.sessionPercent! }
        let weeklies = f.claudeSamples.map { $0.response.weeklyPercent! }
        XCTAssertEqual(sessions, sessions.sorted())
        XCTAssertEqual(weeklies, weeklies.sorted())
        XCTAssertLessThan(sessions[0], sessions[2])
        XCTAssertLessThan(weeklies[0], weeklies[2])
        let gemini = f.antigravitySamples.map { $0.usage.groups[0].highestUsed! }
        XCTAssertEqual(gemini, gemini.sorted())
        XCTAssertLessThan(gemini[0], gemini[2])
        XCTAssertEqual(f.antigravityUsage.tier, "Google AI Pro")
        XCTAssertTrue(f.claudeUsage.extraUsage?.isEnabled ?? false)
    }

    func testStatusFixturesAreAllOperational() async throws {
        let f = fixture
        XCTAssertEqual(f.claudeStatus.status?.indicator, "none")
        XCTAssertEqual(f.claudeStatus.components?.count, 6)
        XCTAssertEqual(f.claudeStatus.incidents?.isEmpty, true)
        let feed = FixtureStatusFeed(pageURL: StatusClient.pageURL, summary: f.claudeStatus)
        let fetched = try await feed.fetch()
        XCTAssertEqual(fetched, f.claudeStatus)
    }

    func testClockFollowsNow() {
        let f = fixture
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "h:mm a"
        XCTAssertTrue(f.clock.hasSuffix(formatter.string(from: now)), f.clock)
    }

    // MARK: - menu bar title

    @MainActor func testMenuBarTitleText() {
        let title = MenuBarTitle(tab: .claude, session: 34.4, weekly: 57.6, isStale: false, metric: .auto)
        XCTAssertEqual(title.text, " 34% / 58%")
        XCTAssertFalse(title.stale)
        XCTAssertEqual(title.tint, .green)
        XCTAssertEqual(title.attributedText.string, " 34% / 58%")
    }

    @MainActor func testMenuBarTitleGoesStaleWithoutNumbers() {
        let missing = MenuBarTitle(tab: .antigravity, session: nil, weekly: nil, isStale: false, metric: .auto)
        XCTAssertEqual(missing.text, " – / –")
        XCTAssertTrue(missing.stale)
        let stale = MenuBarTitle(tab: .claude, session: 10, weekly: 20, isStale: true, metric: .auto)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.iconColor, .secondaryLabelColor)
    }
}

import XCTest
@testable import AIUsageBar

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var responses: [HTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses.isEmpty ? HTTPResponse(status: 500, headers: [:], body: Data()) : responses.removeFirst()
    }
}

let sampleUsage = """
{"five_hour":{"utilization":6.0,"resets_at":"2026-09-11T21:40:00.378846+00:00"},
 "seven_day":{"utilization":32.0,"resets_at":"2026-09-18T06:00:00.378866+00:00"},
 "seven_day_opus":null,"tangelo":null,
 "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
 "limits":[
  {"kind":"session","group":"session","percent":6,"severity":"normal","resets_at":"2026-09-11T21:40:00.378846+00:00","scope":null,"is_active":false},
  {"kind":"weekly_all","group":"weekly","percent":32,"severity":"normal","resets_at":"2026-09-18T06:00:00.378866+00:00","scope":null,"is_active":false},
  {"kind":"weekly_scoped","group":"weekly","percent":44,"severity":"normal","resets_at":"2026-09-18T05:59:59.615127+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}
 ]}
""".data(using: .utf8)!

func tempCredentialFile(expiresAt: Double, refresh: String = "rt-1") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
    let json: [String: Any] = ["claudeAiOauth": [
        "accessToken": "at-old", "refreshToken": refresh, "expiresAt": expiresAt,
        "subscriptionType": "max", "scopes": ["user:profile"], "rateLimitTier": "default_claude_max_5x",
    ]]
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    return url
}

func fileStore(_ url: URL) -> CredentialStore {
    CredentialStore(service: "AIUsageBar-test-nonexistent-\(UUID())", fallbackFile: url)
}

final class ModelTests: XCTestCase {
    func testDecodesLiveShape() throws {
        let u = try UsageClient.decoder.decode(UsageResponse.self, from: sampleUsage)
        XCTAssertEqual(u.displayLimits.count, 3)
        XCTAssertEqual(u.sessionPercent, 6)
        XCTAssertEqual(u.highestPercent, 44)
        XCTAssertEqual(u.displayLimits[2].title, "Fable weekly")
        XCTAssertNotNil(u.displayLimits[0].resetsAt)
    }

    func testFallsBackToWindowsWhenNoLimits() throws {
        let data = #"{"five_hour":{"utilization":10,"resets_at":"2026-09-11T21:40:00Z"},"seven_day":{"utilization":20,"resets_at":null}}"#.data(using: .utf8)!
        let u = try UsageClient.decoder.decode(UsageResponse.self, from: data)
        XCTAssertEqual(u.displayLimits.map(\.percent), [10, 20])
    }

    func testExpiry() {
        let now = Date()
        let soon = OAuthCredential(json: ["accessToken": "x", "expiresAt": (now.timeIntervalSince1970 + 30) * 1000])!
        XCTAssertTrue(soon.isExpired(now: now))              // inside 60 s margin
        let later = OAuthCredential(json: ["accessToken": "x", "expiresAt": (now.timeIntervalSince1970 + 3600) * 1000])!
        XCTAssertFalse(later.isExpired(now: now))
    }

    func testResetText() {
        let now = Date(timeIntervalSince1970: 1_789_120_800)
        XCTAssertNil(ResetText.describe(nil, window: .other, now: now))
        XCTAssertEqual(ResetText.describe(now.addingTimeInterval(-5), window: .fiveHour, now: now), "Resetting")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let jan = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let weekly = ResetText.describe(jan, window: .other, now: now.addingTimeInterval(-365 * 86400), calendar: cal)!
        XCTAssertTrue(weekly.hasPrefix("Resets on Saturday Jan 31st at "), weekly)
        let session = ResetText.describe(now.addingTimeInterval(130 * 60), window: .fiveHour, now: now)!
        XCTAssertTrue(session.hasPrefix("Resets at "), session)
        XCTAssertTrue(session.hasSuffix(" (2h 10m left)"), session)
        XCTAssertEqual(ResetText.remaining(130 * 60), "2h 10m")
        XCTAssertEqual(ResetText.remaining(45 * 60), "45m")
        XCTAssertEqual(ResetText.remaining(60 * 60), "1h")
        XCTAssertEqual(ResetText.remaining(30), "1m")
        XCTAssertEqual(ResetText.ordinal(2), "2nd")
        XCTAssertEqual(ResetText.ordinal(3), "3rd")
        XCTAssertEqual(ResetText.ordinal(11), "11th")
        XCTAssertEqual(ResetText.ordinal(22), "22nd")
    }

    func testColorThresholds() {
        XCTAssertEqual(UsageColor.level(for: 0), .low)
        XCTAssertEqual(UsageColor.level(for: 74.9), .low)
        XCTAssertEqual(UsageColor.level(for: 75), .medium)
        XCTAssertEqual(UsageColor.level(for: 84.9), .medium)
        XCTAssertEqual(UsageColor.level(for: 85), .high)
        XCTAssertEqual(UsageColor.level(for: 94.9), .high)
        XCTAssertEqual(UsageColor.level(for: 95), .critical)
        XCTAssertEqual(UsageColor.level(for: 100), .critical)
    }

    func testRowIconMatchesTheLevels() {
        XCTAssertEqual(UsageColor.rowIcon(50), .green)
        XCTAssertEqual(UsageColor.rowIcon(75), .yellow)
        XCTAssertEqual(UsageColor.rowIcon(85), .lightRed)
        XCTAssertEqual(UsageColor.rowIcon(95), .darkRed)
    }

    func testIconFollowsSessionBelowWeeklyCutoff() {
        XCTAssertEqual(UsageColor.icon(session: 10, weekly: 84.9), .green)
        XCTAssertEqual(UsageColor.icon(session: 75, weekly: 0), .yellow)
        XCTAssertEqual(UsageColor.icon(session: 85, weekly: 0), .lightRed)
        XCTAssertEqual(UsageColor.icon(session: 95, weekly: 0), .darkRed)
        XCTAssertNil(UsageColor.icon(session: nil, weekly: 50))
        XCTAssertNil(UsageColor.icon(session: nil, weekly: nil))
    }

    func testIconFollowsWeeklyFrom85() {
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 85), .lightRed)
        XCTAssertEqual(UsageColor.icon(session: 99, weekly: 85), .lightRed)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 94.9), .lightRed)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 95), .darkRed)
        XCTAssertEqual(UsageColor.icon(session: 0, weekly: 100), .darkRed)
        XCTAssertEqual(UsageColor.icon(session: nil, weekly: 90), .lightRed)
    }
}

final class ClientTests: XCTestCase {
    func testSendsHeaders() async throws {
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: sampleUsage)])
        _ = try await UsageClient(http: http).fetch(accessToken: "tok")
        let r = http.requests[0]
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func test429HonoursRetryAfter() async {
        let http = FakeHTTP([HTTPResponse(status: 429, headers: ["retry-after": "900"], body: Data())])
        do { _ = try await UsageClient(http: http).fetch(accessToken: "t"); XCTFail() }
        catch let e as UsageError { XCTAssertEqual(e, .rateLimited(retryAfter: 900)) }
        catch { XCTFail("\(error)") }
    }

    func test401IsUnauthorized() async {
        let http = FakeHTTP([HTTPResponse(status: 401, headers: [:], body: Data())])
        do { _ = try await UsageClient(http: http).fetch(accessToken: "t"); XCTFail() }
        catch let e as UsageError { XCTAssertEqual(e, .unauthorized) }
        catch { XCTFail("\(error)") }
    }
}

/// Stands in for `claude`: does to the credential file whatever the closure says, then reports
/// whether the refresher's own check sees a change.
final class FakeCLI: ClaudeCLITouch, @unchecked Sendable {
    var runs = 0
    let effect: @Sendable () throws -> Void
    init(_ effect: @escaping @Sendable () throws -> Void = {}) { self.effect = effect }
    func run(until done: @escaping @Sendable () -> Bool) async throws -> Bool {
        runs += 1
        try effect()
        return done()
    }
}

/// What a `claude` run does on success: rewrites the credential with a new access token.
func rewriteCredential(_ file: URL, accessToken: String, refresh: String = "rt-2") -> @Sendable () throws -> Void {
    { @Sendable in
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var sub = json["claudeAiOauth"] as! [String: Any]
        sub["accessToken"] = accessToken
        sub["refreshToken"] = refresh
        sub["expiresAt"] = (Date().timeIntervalSince1970 + 28800) * 1000
        json["claudeAiOauth"] = sub
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }
}

final class RefreshTests: XCTestCase {
    func makeRefresher(file: URL, cli: FakeCLI, running: Bool = false, last: Date? = nil, enabled: Bool = true) -> OAuthRefresher {
        var r = OAuthRefresher(store: fileStore(file), cli: cli, enabled: enabled)
        r.isCLIRunning = { running }
        r.lastAttempt = { last }
        r.recordAttempt = { _ in }
        return r
    }

    /// Default configuration: an expired token is reported, `claude` is never started, and the file is left alone.
    func testDisabledByDefaultReportsExpiryWithoutStartingClaude() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 - 3600) * 1000)
        let before = try Data(contentsOf: file)
        let cli = FakeCLI(rewriteCredential(file, accessToken: "at-new"))
        do {
            _ = try await makeRefresher(file: file, cli: cli, enabled: false).refreshIfNeeded(force: false)
            XCTFail("expected disabled")
        } catch let e as RefreshError {
            XCTAssertEqual(e, .disabled)
        }
        XCTAssertEqual(cli.runs, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(AppConfig.Settings().refreshesClaudeToken)
        XCTAssertTrue(AppConfig.Settings(claude: .init(refresh: true)).refreshesClaudeToken)
    }

    /// Even when disabled, a token Claude Code already refreshed is used as is.
    func testDisabledStillReturnsFreshTokenSomebodyElseWrote() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 + 3600) * 1000)
        let creds = try await makeRefresher(file: file, cli: FakeCLI(), enabled: false).refreshIfNeeded(force: false)
        XCTAssertEqual(creds.oauth.accessToken, "at-old")
    }

    func testSkipsWhenNotExpired() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 + 3600) * 1000)
        let cli = FakeCLI(rewriteCredential(file, accessToken: "at-new"))
        let creds = try await makeRefresher(file: file, cli: cli).refreshIfNeeded(force: false)
        XCTAssertEqual(creds.oauth.accessToken, "at-old")
        XCTAssertEqual(cli.runs, 0)
    }

    /// The whole point: the app starts `claude`, Claude Code rewrites its own credential, the app reads it back.
    func testStartsClaudeAndReadsBackWhatItWrote() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 - 7200) * 1000)
        let cli = FakeCLI(rewriteCredential(file, accessToken: "at-new"))
        let creds = try await makeRefresher(file: file, cli: cli).refreshIfNeeded(force: false)
        XCTAssertEqual(cli.runs, 1)
        XCTAssertEqual(creds.oauth.accessToken, "at-new")
        XCTAssertEqual(creds.oauth.refreshToken, "rt-2")
        XCTAssertFalse(creds.oauth.isExpired())
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let sub = onDisk["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(sub["rateLimitTier"] as? String, "default_claude_max_5x")
    }

    /// A 401 with an unexpired `expiresAt` forces a run too.
    func testForcedRunIgnoresExpiry() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 + 3600) * 1000)
        let cli = FakeCLI(rewriteCredential(file, accessToken: "at-new"))
        let creds = try await makeRefresher(file: file, cli: cli).refreshIfNeeded(force: true)
        XCTAssertEqual(cli.runs, 1)
        XCTAssertEqual(creds.oauth.accessToken, "at-new")
    }

    /// `claude` ran but left the credential alone (signed out, offline): say so, keep the old one.
    func testReportsWhenClaudeDidNotRefresh() async throws {
        let file = try tempCredentialFile(expiresAt: 0)
        let cli = FakeCLI()
        do { _ = try await makeRefresher(file: file, cli: cli).refreshIfNeeded(force: false); XCTFail() }
        catch let e as RefreshError { XCTAssertEqual(e, .cliDidNotRefresh) }
        XCTAssertEqual(cli.runs, 1)
    }

    func testNoRefreshTokenNeverStartsClaude() async throws {
        let file = try tempCredentialFile(expiresAt: 0, refresh: "")
        let cli = FakeCLI()
        do { _ = try await makeRefresher(file: file, cli: cli).refreshIfNeeded(force: false); XCTFail() }
        catch let e as RefreshError { XCTAssertEqual(e, .noRefreshToken) }
        XCTAssertEqual(cli.runs, 0)
    }

    func testThrottled() async throws {
        let file = try tempCredentialFile(expiresAt: 0)
        let cli = FakeCLI()
        do { _ = try await makeRefresher(file: file, cli: cli, last: Date().addingTimeInterval(-10)).refreshIfNeeded(force: false); XCTFail() }
        catch let e as RefreshError { XCTAssertEqual(e, .throttled) }
        XCTAssertEqual(cli.runs, 0)
    }

    func testCLIOwnsFreshExpiry() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 - 30) * 1000)
        let cli = FakeCLI()
        do { _ = try await makeRefresher(file: file, cli: cli, running: true).refreshIfNeeded(force: false); XCTFail() }
        catch let e as RefreshError { XCTAssertEqual(e, .cliOwnsRefresh) }
        XCTAssertEqual(cli.runs, 0)
    }

    func testCLIRunningButLongExpiredStartsAnother() async throws {
        let file = try tempCredentialFile(expiresAt: (Date().timeIntervalSince1970 - 3600) * 1000)
        let cli = FakeCLI(rewriteCredential(file, accessToken: "at-new"))
        let creds = try await makeRefresher(file: file, cli: cli, running: true).refreshIfNeeded(force: false)
        XCTAssertEqual(creds.oauth.accessToken, "at-new")
    }

    /// The real probe with no binary to run refuses before touching anything.
    func testProbeWithoutBinaryIsMissing() async throws {
        let probe = ClaudeCLIProbe(binary: nil)
        do { _ = try await probe.run(until: { true }); XCTFail() }
        catch let e as RefreshError { XCTAssertEqual(e, .cliMissing) }
    }

    func testLocateTakesTheFirstExecutableCandidate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("plain"), exec = dir.appendingPathComponent("exec")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: exec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        XCTAssertEqual(ClaudeCLIProbe.locate(candidates: [dir.appendingPathComponent("none").path, plain.path, exec.path]), exec.path)
    }

    func testTranscriptDirectoryManglesLikeClaudeCode() {
        let root = URL(fileURLWithPath: "/r")
        XCTAssertEqual(ClaudeCLIProbe.transcriptDirectory(for: "/Users/x/Library/Application Support/AIUsageBar/claude-probe", under: root).path,
                       "/r/-Users-x-Library-Application-Support-AIUsageBar-claude-probe")
        XCTAssertEqual(ClaudeCLIProbe.transcriptDirectory(for: "/tmp/a.b_c", under: root).lastPathComponent, "-tmp-a-b-c")
    }

    func testProbeEnvironmentDropsOtherAccountsAndNesting() {
        let env = ClaudeCLIProbe.environment(base: [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_BASE_URL": "u",
            "CLAUDE_CODE_OAUTH_TOKEN": "t", "CLAUDECODE": "1", "LANG": "en_US.UTF-8",
        ])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertTrue(env["PATH"]!.hasSuffix("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"))
        XCTAssertTrue(env["PATH"]!.hasPrefix("/Users/"))
        XCTAssertEqual(env["PWD"], ClaudeCLIProbe.directory.path)
    }

    /// What the pty delivers: cursor moves between words, colours, and the selection marker.
    func testScreenStripsEscapesAndWhitespace() {
        var screen = ProbeScreen()
        screen.append(Data("\u{1b}[2J\u{1b}[1;1H\u{1b}[1mQuick\u{1b}[0m \u{1b}[3;5Hsafety check:\r\n".utf8))
        screen.append(Data(" Is this a project you created or one you trust?\u{1b}]0;title\u{7}\n".utf8))
        screen.append(Data("\u{1b}[36m❯ No, exit\u{1b}[39m\n  Yes, I trust this folder\n\u{1b}(B".utf8))
        XCTAssertEqual(screen.text, "Quicksafetycheck:Isthisaprojectyoucreatedoroneyoutrust?❯No,exitYes,Itrustthisfolder")
        XCTAssertTrue(screen.showsTrustQuestion)
        XCTAssertEqual(screen.trustDefault, .decline)

        var accept = ProbeScreen()
        accept.append(Data("Do you trust the files in this folder?\n❯ Yes, proceed\n  No, exit".utf8))
        XCTAssertTrue(accept.showsTrustQuestion)
        XCTAssertEqual(accept.trustDefault, .accept)

        var prompt = ProbeScreen()
        prompt.append(Data("\u{1b}[2K> Try \"fix lint errors\"".utf8))
        XCTAssertFalse(prompt.showsTrustQuestion)
        XCTAssertNil(prompt.trustDefault)
    }

    func testScreenKeepsOnlyTheTail() {
        var screen = ProbeScreen()
        screen.append(Data(String(repeating: "a", count: ProbeScreen.keep + 100).utf8))
        screen.append(Data("❯ Yes".utf8))
        XCTAssertEqual(screen.text.count, ProbeScreen.keep)
        XCTAssertEqual(screen.trustDefault, .accept)
    }
}

final class StatusTests: XCTestCase {
    let sample = """
    {"status":{"indicator":"minor","description":"Minor Service Outage"},
     "components":[{"id":"a","name":"claude.ai","status":"operational"},{"id":"b","name":"Claude Cowork","status":"partial_outage"}],
     "incidents":[{"id":"i1","name":"Degraded functionality for Claude Cowork on Windows","impact":"major","status":"identified",
       "shortlink":"https://stspg.io/x","updated_at":"2026-09-11T14:19:51.617Z",
       "components":[{"id":"b","name":"Claude Cowork","status":"partial_outage"}],
       "incident_updates":[{"status":"identified","body":"A Windows update...","updated_at":"2026-09-11T14:19:51.617Z"}]}]}
    """.data(using: .utf8)!

    func testDecodesSummary() throws {
        let s = try UsageClient.decoder.decode(StatusSummary.self, from: sample)
        XCTAssertFalse(s.isAllClear)
        XCTAssertEqual(s.affectedNames, "Claude Cowork")
        XCTAssertEqual(s.incidents?.first?.latestBody, "A Windows update...")
        XCTAssertEqual(s.incidents?.first?.status, "identified")
    }

    func testAllClear() throws {
        let data = #"{"status":{"indicator":"none","description":"All Systems Operational"},"components":[],"incidents":[]}"#.data(using: .utf8)!
        let s = try UsageClient.decoder.decode(StatusSummary.self, from: data)
        XCTAssertTrue(s.isAllClear)
        XCTAssertNil(s.incidentCount)
    }

    func testIncidentCountWording() throws {
        var s = try UsageClient.decoder.decode(StatusSummary.self, from: sample)
        XCTAssertEqual(s.incidentCount, "1 active incident")
        let one = s.incidents![0]
        s.incidents?.append(one)
        s.scheduledMaintenances = [one]
        XCTAssertEqual(s.incidentCount, "2 active incidents, 1 scheduled maintenance")
        s.incidents = []
        XCTAssertEqual(s.incidentCount, "1 scheduled maintenance")
    }

    func testRelativeText() {
        let now = Date()
        XCTAssertEqual(RelativeText.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(RelativeText.ago(now.addingTimeInterval(-3 * 60), now: now), "3 mins ago")
        XCTAssertEqual(RelativeText.ago(now.addingTimeInterval(-26 * 3600), now: now), "1 day ago")
    }

    func testSecondFetchIsConditionalAndA304KeepsTheSummary() async throws {
        let http = FakeHTTP([
            HTTPResponse(status: 200, headers: ["etag": "W/\"abc\""], body: sample),
            HTTPResponse(status: 304, headers: [:], body: Data()),
        ])
        let client = StatusClient(http: http)
        let first = try await client.fetch()
        let second = try await client.fetch()
        XCTAssertNil(http.requests[0].value(forHTTPHeaderField: "If-None-Match"), "nothing to validate against yet")
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
        XCTAssertNil(http.requests[1].value(forHTTPHeaderField: "If-Modified-Since"), "no Last-Modified came back")
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.affectedNames, "Claude Cowork")
    }

    func testNoValidatorMeansNoConditionalHeader() async throws {
        let http = FakeHTTP([
            HTTPResponse(status: 200, headers: [:], body: sample),
            HTTPResponse(status: 200, headers: [:], body: sample),
        ])
        let client = StatusClient(http: http)
        _ = try await client.fetch()
        _ = try await client.fetch()
        XCTAssertNil(http.requests[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(http.requests[1].value(forHTTPHeaderField: "If-Modified-Since"))
    }

    func testA304WithNothingRememberedIsAnError() async {
        let http = FakeHTTP([HTTPResponse(status: 304, headers: [:], body: Data())])
        do {
            _ = try await StatusClient(http: http).fetch()
            XCTFail("expected a throw")
        } catch let UsageError.http(status) {
            XCTAssertEqual(status, 304)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

final class GoogleStatusTests: XCTestCase {
    /// Shaped like status.cloud.google.com/incidents.json: an open Code Assist disruption, a
    /// closed Gemini API incident, and an open one on a product the card ignores.
    let feed = """
    [{"id":"open1","begin":"2026-09-18T10:00:00+00:00","end":null,"modified":"2026-09-18T11:00:00+00:00",
      "external_desc":"Gemini Code Assist users are seeing elevated error rates.","status_impact":"SERVICE_DISRUPTION","severity":"medium",
      "affected_products":[{"title":"Gemini Code Assist","id":"deUeOEPYanfJ9w8cpyBJ"},{"title":"Cloud Run","id":"x1"}],
      "most_recent_update":{"when":"2026-09-18T11:00:00+00:00","status":"SERVICE_DISRUPTION","text":"## Summary\\nMitigation is underway.\\n\\nNext update in 1 hour."},
      "updates":[{"when":"2026-09-18T11:00:00+00:00","status":"SERVICE_DISRUPTION","text":"## Summary\\nMitigation is underway.\\n\\nNext update in 1 hour."},
                 {"when":"2026-09-18T10:05:00+00:00","status":"SERVICE_DISRUPTION","text":"We are investigating."}],
      "uri":"incidents/open1"},
     {"id":"closed1","begin":"2026-09-01T10:00:00+00:00","end":"2026-09-01T12:00:00+00:00","external_desc":"Old Gemini API outage","status_impact":"SERVICE_OUTAGE",
      "affected_products":[{"title":"Vertex Gemini API","id":"Z0FZJAMvEB4j3NbCJs6B"}],
      "most_recent_update":{"when":"2026-09-01T12:00:00+00:00","status":"AVAILABLE","text":"Resolved."},"uri":"incidents/closed1"},
     {"id":"other1","begin":"2026-09-18T09:00:00+00:00","end":null,"external_desc":"Compute Engine trouble","status_impact":"SERVICE_OUTAGE",
      "affected_products":[{"title":"Google Compute Engine","id":"x2"}],"uri":"incidents/other1"}]
    """.data(using: .utf8)!

    func testKeepsOpenIncidentsOnTheWatchedProducts() throws {
        let incidents = try UsageClient.decoder.decode([GoogleIncident].self, from: feed)
        let summary = GoogleStatusClient.summary(incidents)
        XCTAssertFalse(summary.isAllClear)
        XCTAssertEqual(summary.status?.indicator, "major")
        XCTAssertEqual(summary.status?.description, "Service Disruption")
        XCTAssertEqual(summary.productComponents.map(\.name), ["Gemini Code Assist", "Gemini API"])
        XCTAssertEqual(summary.productComponents.map(\.status), ["partial_outage", "operational"])
        XCTAssertEqual(summary.affectedNames, "Gemini Code Assist")
        XCTAssertEqual(summary.activeIncidents.map(\.id), ["open1"])
        let incident = try XCTUnwrap(summary.incidents?.first)
        XCTAssertEqual(incident.name, "Gemini Code Assist users are seeing elevated error rates.")
        XCTAssertEqual(incident.impact, "major")
        XCTAssertEqual(incident.status, "service disruption")
        XCTAssertEqual(incident.shortlink, "https://status.cloud.google.com/incidents/open1")
        XCTAssertEqual(incident.latestBody, "Summary\nMitigation is underway.\nNext update in 1 hour.")
        XCTAssertEqual(incident.affected, "Gemini Code Assist")
        XCTAssertEqual(incident.updatedAt, ISO8601DateFormatter().date(from: "2026-09-18T11:00:00+00:00"))
    }

    func testAllClearWithoutOpenWatchedIncidents() throws {
        let incidents = try UsageClient.decoder.decode([GoogleIncident].self, from: feed).filter { $0.id != "open1" }
        let summary = GoogleStatusClient.summary(incidents)
        XCTAssertTrue(summary.isAllClear)
        XCTAssertEqual(summary.status?.description, "All Systems Operational")
        XCTAssertEqual(summary.productComponents.map(\.status), ["operational", "operational"])
        XCTAssertEqual(summary.activeIncidents, [])
    }

    func testWorstImpactWinsPerProductAndOverall() throws {
        var open = try UsageClient.decoder.decode([GoogleIncident].self, from: feed)[0]
        open.id = "open2"
        open.statusImpact = "SERVICE_OUTAGE"
        open.affectedProducts = [.init(id: "Z0FZJAMvEB4j3NbCJs6B", title: "Vertex Gemini API")]
        let incidents = try UsageClient.decoder.decode([GoogleIncident].self, from: feed) + [open]
        let summary = GoogleStatusClient.summary(incidents)
        XCTAssertEqual(summary.status?.indicator, "critical")
        XCTAssertEqual(summary.productComponents.map(\.status), ["partial_outage", "major_outage"])
        XCTAssertEqual(summary.activeIncidents.map(\.id), ["open2", "open1"], "outage sorts before disruption")
    }

    func testFetchDecodesTheFeed() async throws {
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: feed)])
        let summary = try await GoogleStatusClient(http: http).fetch()
        XCTAssertEqual(summary.activeIncidents.map(\.id), ["open1"])
        XCTAssertEqual(GoogleStatusClient(http: http).pageURL.absoluteString, "https://status.cloud.google.com")
    }

    func testSecondFetchSendsIfModifiedSinceAndA304KeepsTheSummary() async throws {
        let stamp = "Thu, 18 Sep 2026 10:00:00 GMT"
        let http = FakeHTTP([
            HTTPResponse(status: 200, headers: ["last-modified": stamp], body: feed),
            HTTPResponse(status: 304, headers: [:], body: Data()),
        ])
        let client = GoogleStatusClient(http: http)
        let first = try await client.fetch()
        let second = try await client.fetch()
        XCTAssertNil(http.requests[0].value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "If-Modified-Since"), stamp)
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.activeIncidents.map(\.id), ["open1"])
    }

    func testPlainTextDropsHeadingsAndBlankLines() {
        XCTAssertEqual(GoogleIncident.plainText("## Incident Report\n### Summary\n\nAll clear.\n"), "Incident Report\nSummary\nAll clear.")
        XCTAssertNil(GoogleIncident.plainText("\n\n"))
        XCTAssertNil(GoogleIncident.plainText(nil))
    }
}

final class UsagePageTests: XCTestCase {
    func testEachTabOpensItsOwnPage() {
        XCTAssertEqual(UsagePage.title(for: .claude), "Usage on claude.ai")
        XCTAssertEqual(UsagePage.url(for: .claude).absoluteString, "https://claude.ai/settings/usage")
        XCTAssertEqual(UsagePage.title(for: .antigravity), "Plan on Google One")
        XCTAssertEqual(UsagePage.url(for: .antigravity).absoluteString, "https://one.google.com/ai")
    }
}

final class UsageTabTests: XCTestCase {
    /// The provider switch tints the marks itself, so each tab offers a template image at the
    /// control's size and the two marks are distinct.
    func testEachTabHasATemplateMark() {
        for tab in UsageTab.allCases {
            XCTAssertTrue(tab.icon.isTemplate, tab.title)
            XCTAssertEqual(tab.icon.size, TintedMark.templateSize, tab.title)
        }
        XCTAssertFalse(UsageTab.claude.icon === UsageTab.antigravity.icon)
        XCTAssertNotEqual(UsageTab.claude.icon.tiffRepresentation, UsageTab.antigravity.icon.tiffRepresentation)
    }
}

// MARK: - Antigravity

/// Live capture of `v1internal:retrieveUserQuotaSummary` (2026-09-14 20:42 local).
let antigravityFixture = #"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-09-17T18:38:34Z","description":"You have used some of your weekly limit, it will fully refresh in 2 days, 17 hours.","remainingFraction":0.48508173},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","resetTime":"2026-09-15T05:42:25Z","remainingFraction":1}],"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro"},{"buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-09-21T05:58:19Z","description":"You have used some of your weekly limit, it will fully refresh in 6 days, 5 hours.","remainingFraction":0.66513824},{"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","resetTime":"2026-09-15T05:42:25Z","remainingFraction":1}],"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS"}],"description":"Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier."}"#.data(using: .utf8)!

func tempAntigravityFile(expiry: String, refresh: String? = "rt-ag") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ag-\(UUID().uuidString).json")
    var token: [String: Any] = ["access_token": "at-file", "expiry": expiry, "token_type": "Bearer"]
    if let refresh { token["refresh_token"] = refresh }
    try JSONSerialization.data(withJSONObject: ["token": token, "auth_method": "consumer"]).write(to: url)
    return url
}

final class AntigravityModelTests: XCTestCase {
    func testDerivesGroupsAndBucketsFromFixture() throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        let usage = AntigravityUsage(summary: summary, tier: "Google AI Pro")
        XCTAssertEqual(usage.groups.map(\.title), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(usage.tier, "Google AI Pro")

        let gemini = try XCTUnwrap(usage.gemini)
        XCTAssertEqual(gemini.description, "Models within this group: Gemini Flash, Gemini Pro")
        // 5-hour row first, weekly second, like the Claude tab.
        XCTAssertEqual(gemini.buckets.map(\.id), ["gemini-5h", "gemini-weekly"])
        XCTAssertEqual(gemini.buckets.map(\.title), ["Five Hour Limit Remaining", "Weekly Limit Remaining"])
        XCTAssertEqual(gemini.buckets.map(\.window), ["5h", "weekly"])
        XCTAssertEqual(gemini.buckets[0].percentRemaining, 100)
        XCTAssertNil(gemini.buckets[0].description)
        XCTAssertEqual(gemini.buckets[1].percentRemaining, 48.5)
        XCTAssertEqual(gemini.buckets[1].percentUsed, 51.5)
        XCTAssertEqual(gemini.buckets[1].resetsAt, ISO8601DateFormatter().date(from: "2026-09-17T18:38:34Z"))
        XCTAssertEqual(gemini.buckets[1].description, "You have used some of your weekly limit, it will fully refresh in 2 days, 17 hours.")
        XCTAssertEqual(gemini.highestUsed, 51.5)

        let other = try XCTUnwrap(usage.other)
        XCTAssertEqual(other.buckets.map(\.id), ["3p-5h", "3p-weekly"])
        XCTAssertEqual(other.buckets[1].percentRemaining, 66.5)
        XCTAssertEqual(other.highestUsed, 33.5)
    }

    func testMissingFractionMeansExhaustedAndTitlesFallBackToWindow() throws {
        // proto3 JSON omits zero-valued fields, so an exhausted bucket arrives without remainingFraction.
        let data = #"{"groups":[{"displayName":"G","buckets":[{"window":"5h","remainingFraction":0.25},{"window":"weekly","resetTime":"2026-09-24T18:38:34Z","description":"You have used all of your weekly limit, it will fully refresh in 2 days, 18 hours."}]},{"displayName":"Empty","buckets":[]}]}"#.data(using: .utf8)!
        let usage = AntigravityUsage(summary: try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: data))
        XCTAssertEqual(usage.groups.count, 1)
        let buckets = usage.groups[0].buckets
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.window), ["5h", "weekly"])
        XCTAssertEqual(buckets[0].title, "Five Hour Limit Remaining")
        XCTAssertEqual(buckets[0].percentRemaining, 25)
        XCTAssertEqual(buckets[1].percentRemaining, 0)
        XCTAssertEqual(buckets[1].percentUsed, 100)
        XCTAssertEqual(buckets[1].description, "You have used all of your weekly limit, it will fully refresh in 2 days, 18 hours.")
        XCTAssertNotNil(buckets[1].resetsAt)
        XCTAssertEqual(usage.groups[0].highestUsed, 100)
        XCTAssertNil(usage.gemini)
        XCTAssertEqual(usage.other?.title, "G")
    }

    func testIdleFiveHourBucket() throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        let gemini = try XCTUnwrap(AntigravityUsage(summary: summary).gemini)
        XCTAssertTrue(gemini.buckets[0].isIdle)      // 5h at remainingFraction 1
        XCTAssertFalse(gemini.buckets[1].isIdle)     // weekly, partly used
        // A full weekly bucket keeps a real reset anchor, so it is never idle.
        let fullWeek = AntigravityUsage.Bucket(id: "w", title: "Weekly Limit Remaining", window: "weekly",
                                               percentRemaining: 100, resetsAt: Date(), description: nil)
        XCTAssertFalse(fullWeek.isIdle)
    }

    func testBucketDetailIsTheResetTimeNotGoogleSentence() {
        let now = Date(timeIntervalSince1970: 1_789_120_800)
        let sentence = "You have used some of your weekly limit, it will fully refresh in 2 days, 18 hours."
        let described = AntigravityUsage.Bucket(id: "a", title: "Weekly Limit Remaining", window: "weekly",
                                                percentRemaining: 48.5, resetsAt: now.addingTimeInterval(86400), description: sentence)
        let describedText = described.detail(now: now) ?? ""
        XCTAssertTrue(describedText.hasPrefix("Resets on "), describedText)
        XCTAssertFalse(describedText.contains("refresh"), describedText)

        let noReset = AntigravityUsage.Bucket(id: "e", title: "Weekly Limit Remaining", window: "weekly",
                                              percentRemaining: 48.5, resetsAt: nil, description: sentence)
        XCTAssertNil(noReset.detail(now: now))

        let idle = AntigravityUsage.Bucket(id: "b", title: "Five Hour Limit Remaining", window: "5h",
                                           percentRemaining: 100, resetsAt: now.addingTimeInterval(5 * 3600), description: "")
        XCTAssertEqual(idle.detail(now: now), "No usage this window yet")

        let session = AntigravityUsage.Bucket(id: "c", title: "Five Hour Limit Remaining", window: "5h",
                                              percentRemaining: 50, resetsAt: now.addingTimeInterval(2 * 3600), description: nil)
        let sessionText = session.detail(now: now) ?? ""
        XCTAssertTrue(sessionText.hasPrefix("Resets at "), sessionText)

        let weekly = AntigravityUsage.Bucket(id: "d", title: "Weekly Limit Remaining", window: "weekly",
                                             percentRemaining: 100, resetsAt: now.addingTimeInterval(3 * 86400), description: nil)
        let weeklyText = weekly.detail(now: now) ?? ""
        XCTAssertTrue(weeklyText.hasPrefix("Resets on "), weeklyText)
    }

    func testLogLineListsRawFractionsInWireOrder() throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        XCTAssertEqual(summary.logLine, "gemini-weekly=0.4851 gemini-5h=1.0000 3p-weekly=0.6651 3p-5h=1.0000")

        let data = #"{"groups":[{"buckets":[{"bucketId":"3p-weekly","window":"weekly"}]}]}"#.data(using: .utf8)!
        let exhausted = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: data)
        XCTAssertEqual(exhausted.logLine, "3p-weekly=absent")
    }

    func testExpiryParsing() throws {
        let date = try XCTUnwrap(AntigravityToken.parseExpiry("2026-09-14T15:09:43.23612-04:00"))
        let expected = ISO8601DateFormatter().date(from: "2026-09-14T19:09:43Z")!.addingTimeInterval(0.236)
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNotNil(AntigravityToken.parseExpiry("2026-09-14T19:09:43Z"))
        XCTAssertNotNil(AntigravityToken.parseExpiry("2026-09-14T19:09:43.5Z"))
        XCTAssertNil(AntigravityToken.parseExpiry("garbage"))
        let broken = AntigravityToken(json: ["token": ["access_token": "x", "expiry": "garbage"]])!
        XCTAssertTrue(broken.isExpired())
    }

    func testMissingFileError() {
        XCTAssertThrowsError(try AntigravityToken.read(from: URL(fileURLWithPath: "/nonexistent/jetski"))) { e in
            XCTAssertEqual(e as? AntigravityCredentialError, .notFound)
            XCTAssertEqual(e.localizedDescription, "No Antigravity login found. Open Antigravity and sign in.")
        }
    }
}

final class AntigravityAuthTests: XCTestCase {
    private func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func makeAuth(http: FakeHTTP, file: URL, last: Date? = nil) -> (AntigravityAuth, URL) {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ag-cache-\(UUID().uuidString).json")
        var auth = AntigravityAuth(client: AppConfig.OAuthClient(clientId: "cid-test", clientSecret: "cs-test"))
        auth.http = http
        auth.credentialFile = file
        auth.cacheFile = cache
        auth.lastAttempt = { last }
        auth.recordAttempt = { _ in }
        return (auth, cache)
    }

    func testUsesFileTokenWithoutNetworkWhenValid() async throws {
        let file = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(3600)))
        let http = FakeHTTP([])
        let (auth, _) = makeAuth(http: http, file: file)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "at-file")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRefreshesExpiredTokenWithFormPostAndLeavesFileAlone() async throws {
        let file = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(-10)))
        let before = try Data(contentsOf: file)
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: #"{"access_token":"at-new","expires_in":3599,"token_type":"Bearer"}"#.data(using: .utf8)!)])
        let (auth, cache) = makeAuth(http: http, file: file)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "at-new")
        XCTAssertEqual(http.requests.count, 1)
        let req = http.requests[0]
        XCTAssertEqual(req.url, URL(string: "https://oauth2.googleapis.com/token"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-ag"))
        XCTAssertTrue(body.contains("client_id=cid-test"))
        XCTAssertTrue(body.contains("client_secret=cs-test"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        // Cached for next time: a second call makes no request.
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        let again = try await auth.accessToken()
        XCTAssertEqual(again, "at-new")
        XCTAssertEqual(http.requests.count, 1)
    }

    /// No client file means no refresh: the app reports the expiry and touches the network not at all.
    func testExpiredTokenWithoutClientFileIsReportedNotRefreshed() async throws {
        let file = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(-10)))
        let http = FakeHTTP([])
        var (auth, _) = makeAuth(http: http, file: file)
        auth.client = nil
        do {
            _ = try await auth.accessToken()
            XCTFail("expected noRefreshClient")
        } catch let e as AntigravityAuthError {
            XCTAssertEqual(e, .noRefreshClient)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testInvalidGrantMeansSignInAgain() async throws {
        let file = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(-10)))
        let http = FakeHTTP([HTTPResponse(status: 400, headers: [:], body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.data(using: .utf8)!)])
        let (auth, _) = makeAuth(http: http, file: file)
        do {
            _ = try await auth.accessToken()
            XCTFail("expected throw")
        } catch let e as AntigravityAuthError {
            XCTAssertEqual(e, .loginExpired)
            XCTAssertEqual(e.localizedDescription, "Antigravity login expired. Sign in again in Antigravity.")
        }
    }

    func testThrottledWhenRefreshedRecently() async throws {
        let file = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(-10)))
        let http = FakeHTTP([])
        let (auth, _) = makeAuth(http: http, file: file, last: Date().addingTimeInterval(-5))
        do {
            _ = try await auth.accessToken()
            XCTFail("expected throw")
        } catch let e as AntigravityAuthError {
            XCTAssertEqual(e, .throttled)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }
}

final class AntigravityClientTests: XCTestCase {
    func testSendsBearerAndEmptyJSONBodyToTheGivenHost() async throws {
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: antigravityFixture)])
        let client = AntigravityClient(http: http)
        let summary = try await client.fetch(accessToken: "tok", host: AntigravityClient.dailyHost)
        XCTAssertEqual(summary.groups?.count, 2)
        let req = http.requests[0]
        let expected: URL? = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        XCTAssertEqual(req.url, expected)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), AntigravityClient.userAgent)
        XCTAssertEqual(req.httpBody, "{}".data(using: .utf8))
        let production: URL? = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        XCTAssertEqual(AntigravityClient.summaryURL(host: AntigravityClient.productionHost), production)
    }

    func testAccountPrefersPaidTierAndDefaultsToTheDailyHost() async throws {
        let body = Data(#"{"currentTier":{"name":"Antigravity"},"paidTier":{"name":"Google AI Pro"}}"#.utf8)
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: body)])
        let account = try await AntigravityClient(http: http).fetchAccount(accessToken: "tok")
        XCTAssertEqual(account.tier, "Google AI Pro")
        XCTAssertFalse(account.usesGcpTos)
        XCTAssertEqual(account.host, "https://daily-cloudcode-pa.googleapis.com")
        // The account lookup itself always goes to the production host, like Antigravity's first call.
        let accountURL: URL? = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        XCTAssertEqual(http.requests[0].url, accountURL)
    }

    func testAccountUnderGcpTermsUsesTheProductionHost() async throws {
        let body = Data(#"{"currentTier":{"name":"Antigravity"},"paidTier":{"name":"Standard","usesGcpTos":true}}"#.utf8)
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: body)])
        let account = try await AntigravityClient(http: http).fetchAccount(accessToken: "tok")
        XCTAssertEqual(account.tier, "Standard")
        XCTAssertTrue(account.usesGcpTos)
        XCTAssertEqual(account.host, "https://cloudcode-pa.googleapis.com")
    }

    func testAccountWithoutPaidTierFallsBackToCurrentTier() async throws {
        let body = Data(#"{"currentTier":{"name":"Antigravity"}}"#.utf8)
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: body)])
        let account = try await AntigravityClient(http: http).fetchAccount(accessToken: "tok")
        XCTAssertEqual(account.tier, "Antigravity")
        XCTAssertEqual(account.host, AntigravityClient.dailyHost)
    }

    func testAccountOnANonJSONBodyThrowsDecoding() async {
        let http = FakeHTTP([HTTPResponse(status: 200, headers: [:], body: Data("<html>".utf8))])
        do { _ = try await AntigravityClient(http: http).fetchAccount(accessToken: "t"); XCTFail() }
        catch UsageError.decoding {}
        catch { XCTFail("\(error)") }
    }

    func testKnownHosts() {
        XCTAssertTrue(AntigravityClient.isKnownHost(AntigravityClient.productionHost))
        XCTAssertTrue(AntigravityClient.isKnownHost(AntigravityClient.dailyHost))
        XCTAssertFalse(AntigravityClient.isKnownHost("https://example.com"))
        XCTAssertFalse(AntigravityClient.isKnownHost(""))
    }

    func testUsageRemembersItsHostAndDecodesOlderCachesWithoutOne() throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        let usage = AntigravityUsage(summary: summary, tier: "Google AI Pro", host: AntigravityClient.dailyHost)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(AntigravityUsage.self, from: data)
        XCTAssertEqual(decoded.host, AntigravityClient.dailyHost)
        let old = Data(#"{"groups":[],"tier":"Google AI Pro"}"#.utf8)
        let older = try JSONDecoder().decode(AntigravityUsage.self, from: old)
        XCTAssertNil(older.host)
    }

    func test429HonoursRetryAfter() async {
        let http = FakeHTTP([HTTPResponse(status: 429, headers: ["Retry-After": "120"], body: Data())])
        do { _ = try await AntigravityClient(http: http).fetch(accessToken: "t", host: AntigravityClient.dailyHost); XCTFail() }
        catch UsageError.rateLimited(let s) { XCTAssertEqual(s, 120) }
        catch { XCTFail("\(error)") }
    }

    func test401IsUnauthorized() async {
        let http = FakeHTTP([HTTPResponse(status: 401, headers: [:], body: Data())])
        do { _ = try await AntigravityClient(http: http).fetch(accessToken: "t", host: AntigravityClient.dailyHost); XCTFail() }
        catch UsageError.unauthorized {}
        catch { XCTFail("\(error)") }
    }
}

final class AntigravityStoreTests: XCTestCase {
    private func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ag-store-\(name)-\(UUID().uuidString).json")
    }

    /// A store whose token comes straight from a valid credential file, so every request the
    /// fake sees is the account lookup or the quota call.
    @MainActor
    private func makeStore(http: FakeHTTP, cacheURL: URL? = nil) throws -> AntigravityStore {
        let store = AntigravityStore(cacheURL: cacheURL)
        store.client = AntigravityClient(http: http)
        var auth = AntigravityAuth(client: AppConfig.OAuthClient(clientId: "cid-test", clientSecret: "cs-test"))
        auth.http = http
        auth.credentialFile = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(3600)))
        auth.cacheFile = tempURL("auth")
        auth.lastAttempt = { nil }
        auth.recordAttempt = { _ in }
        store.auth = auth
        return store
    }

    private func ok(_ body: Data) -> HTTPResponse { HTTPResponse(status: 200, headers: [:], body: body) }
    private let account = Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8)
    private let gcpAccount = Data(#"{"paidTier":{"name":"Standard","usesGcpTos":true}}"#.utf8)

    private func writeCache(to url: URL, host: String) throws {
        let summary = try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: antigravityFixture)
        let usage = AntigravityUsage(summary: summary, tier: "Google AI Pro", host: host)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let usageJSON = try JSONSerialization.jsonObject(with: enc.encode(usage))
        let cache: [String: Any] = ["usage": usageJSON, "lastUpdated": "2026-09-18T10:00:00Z"]
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
    }

    @MainActor
    func testPollAsksProductionForTheAccountThenTheAccountsHostForQuota() async throws {
        let http = FakeHTTP([ok(account), ok(antigravityFixture)])
        let store = try makeStore(http: http)
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].url, AntigravityClient.accountURL)
        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.dailyHost))
        XCTAssertEqual(store.usage?.host, AntigravityClient.dailyHost)
        XCTAssertEqual(store.usage?.tier, "Google AI Pro")
        XCTAssertEqual(store.state, .ok)
    }

    @MainActor
    func testAccountUnderGcpTermsSendsQuotaToProduction() async throws {
        let http = FakeHTTP([ok(gcpAccount), ok(antigravityFixture)])
        let store = try makeStore(http: http)
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.productionHost))
        XCTAssertEqual(store.usage?.host, AntigravityClient.productionHost)
        XCTAssertEqual(store.usage?.tier, "Standard")
    }

    @MainActor
    func testFreshStoreFallsBackToTheDailyHostWhenTheAccountLookupFails() async throws {
        let http = FakeHTTP([HTTPResponse(status: 500, headers: [:], body: Data()), ok(antigravityFixture)])
        let store = try makeStore(http: http)
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.dailyHost))
        XCTAssertEqual(store.usage?.host, AntigravityClient.dailyHost)
        XCTAssertNil(store.usage?.tier)
        XCTAssertEqual(store.state, .ok)
    }

    @MainActor
    func testCachedHostSurvivesAFailedAccountLookup() async throws {
        let cache = tempURL("cache")
        try writeCache(to: cache, host: AntigravityClient.productionHost)
        let http = FakeHTTP([HTTPResponse(status: 500, headers: [:], body: Data()), ok(antigravityFixture)])
        let store = try makeStore(http: http, cacheURL: cache)
        XCTAssertEqual(store.state, .stale("Cached"))
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.productionHost))
        XCTAssertEqual(store.usage?.host, AntigravityClient.productionHost)
        XCTAssertEqual(store.usage?.tier, "Google AI Pro")
        XCTAssertEqual(store.state, .ok)
    }

    @MainActor
    func testUnknownCachedHostIsIgnored() async throws {
        let cache = tempURL("cache")
        try writeCache(to: cache, host: "https://example.com")
        let http = FakeHTTP([HTTPResponse(status: 500, headers: [:], body: Data()), ok(antigravityFixture)])
        let store = try makeStore(http: http, cacheURL: cache)
        XCTAssertEqual(store.state, .stale("Cached"))
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.dailyHost))
        XCTAssertEqual(store.usage?.host, AntigravityClient.dailyHost)
    }

    @MainActor
    func testUnauthorizedAccountLookupStillReachesTheQuotaCall() async throws {
        // A stale token fails both calls; the quota call's 401 is what triggers the refresh and retry.
        let http = FakeHTTP([
            HTTPResponse(status: 401, headers: [:], body: Data()),
            HTTPResponse(status: 401, headers: [:], body: Data()),
            ok(Data(#"{"access_token":"at-new","expires_in":3600}"#.utf8)),
            ok(account),
            ok(antigravityFixture),
        ])
        let store = try makeStore(http: http)
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests.count, 5)
        XCTAssertEqual(http.requests[1].url, AntigravityClient.summaryURL(host: AntigravityClient.dailyHost))
        XCTAssertEqual(http.requests[4].value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
        XCTAssertEqual(store.state, .ok)
    }

    @MainActor
    func testRateLimitedAccountLookupBacksOffWithoutAQuotaCall() async throws {
        let http = FakeHTTP([HTTPResponse(status: 429, headers: ["Retry-After": "90"], body: Data())])
        let store = try makeStore(http: http)
        await store.refresh(reason: "test")

        XCTAssertEqual(http.requests.count, 1)
        guard case .error(let msg) = store.state else { return XCTFail("\(store.state)") }
        XCTAssertTrue(msg.contains("ate limit"), msg)
        await store.refresh(reason: "again")
        XCTAssertEqual(http.requests.count, 1, "backoff should skip the next poll")
    }

    /// A store whose token path is dead: an expired file token with no refresh token, so
    /// `accessToken()` throws `loginExpired` before any request.
    @MainActor
    private func makeExpiredStore(local: FakeHTTP, cacheURL: URL? = nil, ps: String? = nil) throws -> AntigravityStore {
        let store = AntigravityStore(cacheURL: cacheURL)
        var auth = AntigravityAuth(client: nil)
        auth.credentialFile = try tempAntigravityFile(expiry: rfc3339(Date().addingTimeInterval(-3600)), refresh: nil)
        auth.cacheFile = tempURL("auth")
        auth.lastAttempt = { nil }
        auth.recordAttempt = { _ in }
        store.auth = auth
        var probe = AntigravityLocalProbe()
        let ps = ps ?? """
        96528 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token tok-main --cloud_code_endpoint https://cloudcode-pa.googleapis.com
        """
        probe.processList = { ps }
        probe.listeningPorts = { _ in "language_ 96528 someone    7u  IPv4 0x1      0t0  TCP 127.0.0.1:62185 (LISTEN)\n" }
        probe.http = local
        store.localProbe = probe
        return store
    }

    @MainActor
    func testDeadTokenPathAsksTheRunningIDE() async throws {
        let local = FakeHTTP([ok(localQuotaFixture), ok(localStatusFixture)])
        let store = try makeExpiredStore(local: local)
        await store.refresh(reason: "test")

        XCTAssertEqual(local.requests.count, 2)
        XCTAssertEqual(local.requests[0].url?.host, "127.0.0.1")
        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(store.usage?.tier, "Google AI Pro")
        XCTAssertEqual(store.usage?.host, AntigravityClient.productionHost, "the server's backend is remembered")
        XCTAssertEqual(store.usage?.gemini?.buckets.map(\.window), ["5h", "weekly"])
    }

    @MainActor
    func testDeadTokenPathWithoutTheIDEShowsTheTokenError() async throws {
        let local = FakeHTTP([])
        let store = try makeExpiredStore(local: local, ps: "  512 /sbin/launchd\n")
        await store.refresh(reason: "test")

        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertEqual(store.state, .error(AntigravityAuthError.loginExpired.errorDescription!))
    }

    @MainActor
    func testIDEAnswerRefusedKeepsTheTokenError() async throws {
        let cache = tempURL("cache")
        try writeCache(to: cache, host: AntigravityClient.dailyHost)
        let local = FakeHTTP([HTTPResponse(status: 401, headers: [:], body: Data())])
        let store = try makeExpiredStore(local: local, cacheURL: cache)
        await store.refresh(reason: "test")

        XCTAssertEqual(local.requests.count, 1)
        XCTAssertEqual(store.state, .stale(AntigravityAuthError.loginExpired.errorDescription!))
        XCTAssertEqual(store.usage?.host, AntigravityClient.dailyHost, "the cache is untouched")
    }

    @MainActor
    func testRateLimitNeverAsksTheIDE() async throws {
        let http = FakeHTTP([HTTPResponse(status: 429, headers: ["Retry-After": "90"], body: Data())])
        let store = try makeStore(http: http)
        let local = FakeHTTP([ok(localQuotaFixture), ok(localStatusFixture)])
        var probe = AntigravityLocalProbe()
        probe.processList = { psShouldNotBeRead() }
        probe.http = local
        store.localProbe = probe
        await store.refresh(reason: "test")

        XCTAssertTrue(local.requests.isEmpty)
        guard case .error = store.state else { return XCTFail("\(store.state)") }
    }

    @MainActor
    func testSuccessfulPollWritesTheHostToTheCache() async throws {
        let cache = tempURL("cache")
        let http = FakeHTTP([ok(gcpAccount), ok(antigravityFixture)])
        let store = try makeStore(http: http, cacheURL: cache)
        await store.refresh(reason: "test")

        let reloaded = AntigravityStore(cacheURL: cache)
        XCTAssertEqual(reloaded.usage?.host, AntigravityClient.productionHost)
        XCTAssertEqual(reloaded.state, .stale("Cached"))
    }
}

/// Marks a process listing that a test expects never to happen.
func psShouldNotBeRead() -> String {
    XCTFail("the local probe should not have been consulted")
    return ""
}

// MARK: - Tokens

func tempTranscriptRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a transcript at `relative` under the root, creating session and subagent directories on the way.
@discardableResult
func writeTranscript(_ root: URL, _ relative: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func appendTranscript(_ url: URL, _ text: String) throws {
    let fh = try FileHandle(forWritingTo: url)
    defer { try? fh.close() }
    try fh.seekToEnd()
    try fh.write(contentsOf: text.data(using: .utf8)!)
}

func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

/// One assistant line shaped like the real files: compact JSON, `message` first, `type` and
/// `timestamp` near the end. `usage: false` drops the usage object, `cacheCreation: false` drops
/// the per-TTL breakdown (older lines only carry the flat count).
func assistantLine(id: String, ts: Date = Date(), model: String = "claude-opus-5",
                   in input: Int = 10, out: Int = 5, cw5: Int = 0, cw1: Int = 0, cr: Int = 0,
                   block: Int = 0, text: String = "ok", usage: Bool = true, cacheCreation: Bool = true,
                   session: String = "s", cwd: String? = "/Users/sam", branch: String? = nil, slug: String? = nil) -> String {
    let extras = (cwd.map { #","cwd":"\#($0)""# } ?? "")
        + (branch.map { #","gitBranch":"\#($0)""# } ?? "") + (slug.map { #","slug":"\#($0)""# } ?? "")
    var usageJSON = ""
    if usage {
        let breakdown = cacheCreation ? #","cache_creation":{"ephemeral_5m_input_tokens":\#(cw5),"ephemeral_1h_input_tokens":\#(cw1)}"# : ""
        usageJSON = #","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cw5 + cw1),"cache_read_input_tokens":\#(cr),"output_tokens":\#(out),"service_tier":"standard"\#(breakdown),"speed":"standard"}"#
    }
    return #"{"parentUuid":"\#(UUID().uuidString)","isSidechain":false,"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","stop_sequence":null\#(usageJSON)},"apiBlockIndex":\#(block),"requestId":"req_\#(id)","type":"assistant","uuid":"\#(UUID().uuidString)","timestamp":"\#(iso(ts))","sessionId":"\#(session)","version":"2.1.276"\#(extras)}"# + "\n"
}

/// The bookkeeping lines Claude Code rewrites as a session goes: `{"type":"…"` comes first.
func metaLine(_ type: String, session: String = "s", _ key: String, _ value: String) -> String {
    #"{"type":"\#(type)","\#(key)":"\#(value)","sessionId":"\#(session)"}"# + "\n"
}

/// One `~/.claude/sessions/<pid>.json` as Claude Code writes it.
func registryEntry(pid: Int32, session: String, status: String = "idle", cwd: String = "/Users/sam",
                   startedAt: Double = 1_789_754_103_203, updatedAt: Double = 1_789_762_570_826,
                   kind: String = "interactive", name: String = "sam-39", nameSource: String = "derived") -> String {
    #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"\#(cwd)","startedAt":\#(Int(startedAt)),"procStart":1,"version":"2.1.276","peerProtocol":1,"kind":"\#(kind)","entrypoint":"cli","pidDomain":"x","messagingSocketPath":"/tmp/cc-socks/\#(pid).sock","name":"\#(name)","nameSource":"\#(nameSource)","nameSince":1,"status":"\#(status)","updatedAt":\#(Int(updatedAt)),"statusUpdatedAt":\#(Int(updatedAt))}"#
}

func tempRegistryRoot(_ entries: [(Int32, String)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cub-sessions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (pid, json) in entries {
        try json.write(to: root.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try "k".write(to: root.appendingPathComponent("\(pid).abc.key"), atomically: true, encoding: .utf8)
    }
    return root
}

func userLine(ts: Date = Date(), text: String = "hi") -> String {
    #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"\#(UUID().uuidString)","timestamp":"\#(iso(ts))","sessionId":"s","cwd":"/Users/sam"}"# + "\n"
}

func tokenSum(_ records: [TokenRecord]) -> Int { records.reduce(0) { $0 + $1.total } }

/// The scanner keys offsets on the resolved path (the temp dir lives behind the /var symlink).
func cacheKey(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

final class TokenPricingTests: XCTestCase {
    func testPrefixMatch() {
        XCTAssertEqual(TokenPricing.rate(for: "claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertEqual(TokenPricing.rate(for: "claude-fable-5-1")?.cacheReadMultiplier, 0.025)
        XCTAssertEqual(TokenPricing.rate(for: "claude-fable-5-1-20260301")?.cacheReadMultiplier, 0.025)
        XCTAssertEqual(TokenPricing.rate(for: "claude-fable-5")?.cacheReadMultiplier, 0.1)
        // A hypothetical fable-5-10 belongs to fable-5, not fable-5-1: the prefix must end at a "-".
        XCTAssertEqual(TokenPricing.rate(for: "claude-fable-5-10")?.cacheReadMultiplier, 0.1)
        XCTAssertEqual(TokenPricing.rate(for: "claude-opus-5[1m]".replacingOccurrences(of: "[1m]", with: ""))?.output, 25)
        XCTAssertNil(TokenPricing.rate(for: "claude-opus-5[1m]"))
        XCTAssertNil(TokenPricing.rate(for: "claude-opus-50"))
        XCTAssertNil(TokenPricing.rate(for: "gpt-5"))
        XCTAssertNil(TokenPricing.rate(for: ""))
    }

    func testCostArithmetic() throws {
        let r = TokenRecord(timestamp: Date(), model: "claude-opus-5", input: 1000, output: 200,
                            cacheWrite5m: 400, cacheWrite1h: 300, cacheRead: 10_000)
        // (1000*5 + 200*25 + 400*5*1.25 + 300*5*2 + 10000*5*0.1) / 1e6
        XCTAssertEqual(try XCTUnwrap(TokenPricing.cost(r)), 0.0205, accuracy: 1e-9)
        XCTAssertEqual(r.total, 11_900)
        let fable = TokenRecord(timestamp: Date(), model: "claude-fable-5-1", input: 0, output: 0,
                                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(TokenPricing.cost(fable)), 0.25, accuracy: 1e-9)
        XCTAssertNil(TokenPricing.cost(TokenRecord(timestamp: Date(), model: "mystery-1", input: 1, output: 1,
                                                   cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)))
    }

    func testTotalsFlagUnpriced() {
        let now = Date()
        let records = [
            TokenRecord(timestamp: now, model: "claude-sonnet-5", input: 100, output: 50, cacheWrite5m: 10, cacheWrite1h: 20, cacheRead: 300),
            TokenRecord(timestamp: now, model: "mystery-1", input: 7, output: 3, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
            TokenRecord(timestamp: now.addingTimeInterval(-3600), model: "claude-sonnet-5", input: 1, output: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
        ]
        let t = TokenTotals.sum(records, since: now.addingTimeInterval(-60))
        XCTAssertEqual(t.input, 107)
        XCTAssertEqual(t.output, 53)
        XCTAssertEqual(t.cacheWrite, 30)
        XCTAssertEqual(t.cacheRead, 300)
        XCTAssertEqual(t.tokens, 490)
        XCTAssertEqual(t.unpricedTokens, 10)
        // Only the sonnet record is priced: (100*2 + 50*10 + 10*2*1.25 + 20*2*2 + 300*2*0.1) / 1e6
        XCTAssertEqual(t.cost, 0.000865, accuracy: 1e-12)
        XCTAssertEqual(TokenTotals.sum(records, since: now.addingTimeInterval(-7200)).tokens, 492)
        XCTAssertEqual(TokenTotals(), TokenTotals.sum([], since: now))
    }
}

final class TokenScannerTests: XCTestCase {
    /// Not `retain`: an ObjC-visible property of that name shadows NSObject's -retain.
    let since = Date().addingTimeInterval(-8 * 86400)

    func testParsesAssistantLinesAndSkipsOthers() async throws {
        let root = try tempTranscriptRoot()
        // A user line whose tool text mentions the marker passes the prefilter and must still be skipped.
        var text = userLine(text: #"see \"type\":\"assistant\" in the log"#)
        text += #"{"type":"cost-state","costUSD":1.5,"timestamp":"\#(iso(Date()))"}"# + "\n"
        text += assistantLine(id: "msg_synthetic", model: "<synthetic>", in: 99, out: 99)
        text += assistantLine(id: "msg_nousage", usage: false)
        text += assistantLine(id: "msg_1", model: "claude-opus-5[1m]", in: 2, out: 180, cw5: 0, cw1: 46_989, cr: 24_203)
        text += assistantLine(id: "msg_2", in: 3, out: 4, cw5: 5, cacheCreation: false)
        try writeTranscript(root, "p/session.jsonl", text)

        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 2)
        let first = try XCTUnwrap(records.first { $0.output == 180 })
        XCTAssertEqual(first.model, "claude-opus-5")
        XCTAssertEqual(first.input, 2)
        XCTAssertEqual(first.cacheWrite5m, 0)
        XCTAssertEqual(first.cacheWrite1h, 46_989)
        XCTAssertEqual(first.cacheRead, 24_203)
        XCTAssertEqual(first.total, 71_374)
        // Without the per-TTL object the flat count is priced as a 5 m write.
        let second = try XCTUnwrap(records.first { $0.output == 4 })
        XCTAssertEqual(second.cacheWrite5m, 5)
        XCTAssertEqual(second.cacheWrite1h, 0)
    }

    func testDedupsBlocksOfOneResponse() async throws {
        let root = try tempTranscriptRoot()
        let text = (0..<3).map { assistantLine(id: "msg_a", in: 100, out: 40, block: $0) }.joined()
        try writeTranscript(root, "p/session.jsonl", text)
        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(tokenSum(records), 140)
    }

    func testIterationsCarryTheCountsWhenTopLevelIsZeroed() async throws {
        func line(id: String, top: String, iterations: String) -> String {
            #"{"message":{"model":"claude-opus-5","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{\#(top),"iterations":\#(iterations)}},"requestId":"req_\#(id)","type":"assistant","uuid":"\#(UUID().uuidString)","timestamp":"\#(iso(Date()))"}"# + "\n"
        }
        let zero = #""input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":176,"ephemeral_5m_input_tokens":0}"#
        let real = #""input_tokens":2,"cache_creation_input_tokens":2329,"cache_read_input_tokens":164116,"output_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":2329,"ephemeral_5m_input_tokens":0}"#
        let iteration = #"[{"input_tokens":2,"output_tokens":992,"cache_read_input_tokens":165360,"cache_creation_input_tokens":176,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":176},"type":"message"}]"#
        let smaller = #"[{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":5,"type":"message"}]"#
        let root = try tempTranscriptRoot()
        // Seen in real files: zeroed top level with the numbers in iterations, and the reverse.
        try writeTranscript(root, "p/session.jsonl",
                            line(id: "msg_zeroed", top: zero, iterations: iteration)
                            + line(id: "msg_empty", top: real, iterations: "[]")
                            + line(id: "msg_smaller", top: real, iterations: smaller))

        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 3)
        let zeroed = try XCTUnwrap(records.first { $0.output == 992 })
        XCTAssertEqual(zeroed.input, 2)
        XCTAssertEqual(zeroed.cacheRead, 165_360)
        XCTAssertEqual(zeroed.cacheWrite1h, 176)
        XCTAssertEqual(zeroed.cacheWrite5m, 0)
        XCTAssertEqual(zeroed.total, 166_530)
        // The top level wins whenever it is the larger of the two.
        XCTAssertEqual(records.filter { $0.total == 166_457 }.count, 2)
    }

    func testCrossFileCopyDoesNotDoubleCount() async throws {
        for (real, copy) in [("p/a.jsonl", "p/b.jsonl"), ("p/b.jsonl", "p/a.jsonl")] {
            let root = try tempTranscriptRoot()
            try writeTranscript(root, real, assistantLine(id: "msg_a", in: 100, out: 40, cr: 1000))
            try writeTranscript(root, copy, assistantLine(id: "msg_a", in: 0, out: 0, cr: 0) + assistantLine(id: "msg_b", in: 1, out: 1))
            let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
            XCTAssertEqual(records.count, 2, "\(real) then \(copy)")
            XCTAssertEqual(tokenSum(records), 1142, "\(real) then \(copy)")
        }
    }

    func testIncludesNestedSubagents() async throws {
        let root = try tempTranscriptRoot()
        try writeTranscript(root, "p/s.jsonl", assistantLine(id: "msg_main", in: 1, out: 1))
        try writeTranscript(root, "p/s/subagents/agent-x.jsonl", assistantLine(id: "msg_x", in: 10, out: 10))
        try writeTranscript(root, "p/s/subagents/workflows/wf_1/agent-y.jsonl", assistantLine(id: "msg_y", in: 100, out: 100))
        try writeTranscript(root, "p/notes.txt", assistantLine(id: "msg_ignored", in: 1000, out: 1000))
        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(tokenSum(records), 222)
    }

    private struct CacheShape: Decodable {
        var version: Int
        var offsets: [String: UInt64]
        var records: [String: TokenRecord]
    }

    private func readCache(_ url: URL) throws -> CacheShape {
        try UsageClient.decoder.decode(CacheShape.self, from: Data(contentsOf: url))
    }

    func testIncrementalAppendOnlyReadsNewBytes() async throws {
        let root = try tempTranscriptRoot()
        let cache = root.appendingPathComponent("cache/tokens.json")
        let line1 = assistantLine(id: "msg_1", in: 10, out: 10)
        let line2 = assistantLine(id: "msg_2", in: 20, out: 20)
        let line3 = assistantLine(id: "msg_3", in: 30, out: 30)
        let half = line2.index(line2.startIndex, offsetBy: line2.count / 2)
        let file = try writeTranscript(root, "p/s.jsonl", line1 + line2[..<half])

        let scanner = TokenScanner(root: root, cacheURL: cache)
        let first = try await scanner.scan(retainSince: since)
        XCTAssertEqual(tokenSum(first), 20)
        var shape = try readCache(cache)
        XCTAssertEqual(shape.version, TokenScanner.cacheVersion)
        XCTAssertEqual(shape.records.count, 1)
        // The partial line is not consumed: the offset stops after line 1's newline.
        XCTAssertEqual(shape.offsets[cacheKey(file)], UInt64(line1.utf8.count))

        try appendTranscript(file, String(line2[half...]) + line3)
        let second = try await scanner.scan(retainSince: since)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(tokenSum(second), 120)
        shape = try readCache(cache)
        XCTAssertEqual(shape.records.count, 3)
        XCTAssertEqual(shape.offsets[cacheKey(file)], UInt64((line1 + line2 + line3).utf8.count))

        // Nothing appended: a third scan changes nothing.
        let third = try await scanner.scan(retainSince: since)
        XCTAssertEqual(tokenSum(third), 120)
    }

    func testTruncatedFileIsReread() async throws {
        let root = try tempTranscriptRoot()
        let cache = root.appendingPathComponent("cache/tokens.json")
        let file = try writeTranscript(root, "p/s.jsonl", assistantLine(id: "msg_1", in: 10, out: 10) + assistantLine(id: "msg_2", in: 20, out: 20))
        let scanner = TokenScanner(root: root, cacheURL: cache)
        let first = try await scanner.scan(retainSince: since)
        XCTAssertEqual(tokenSum(first), 60)

        // Replaced by something shorter: read again from the top, the earlier records stay (they were spent).
        let short = assistantLine(id: "msg_3", in: 1, out: 1)
        try short.write(to: file, atomically: true, encoding: .utf8)
        let records = try await scanner.scan(retainSince: since)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(tokenSum(records), 62)
        XCTAssertEqual(try readCache(cache).offsets[cacheKey(file)], UInt64(short.utf8.count))

        // Emptied entirely: the offset falls back to 0 without touching the records.
        try Data().write(to: file)
        let emptied = try await scanner.scan(retainSince: since)
        XCTAssertEqual(tokenSum(emptied), 62)
        XCTAssertEqual(try readCache(cache).offsets[cacheKey(file)], 0)
    }

    func testSkipsFilesOlderThanRetention() async throws {
        let root = try tempTranscriptRoot()
        let file = try writeTranscript(root, "p/old.jsonl", assistantLine(id: "msg_old", in: 10, out: 10))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: file.path)
        try writeTranscript(root, "p/new.jsonl", assistantLine(id: "msg_new", in: 1, out: 1))
        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(tokenSum(records), 2)
    }

    func testDropsRecordsOlderThanRetention() async throws {
        let root = try tempTranscriptRoot()
        let cache = root.appendingPathComponent("cache/tokens.json")
        let old = Date().addingTimeInterval(-9 * 86400)
        try writeTranscript(root, "p/s.jsonl", assistantLine(id: "msg_old", ts: old, in: 10, out: 10) + assistantLine(id: "msg_new", in: 1, out: 1))
        let scanner = TokenScanner(root: root, cacheURL: cache)
        // Wide window first so the old record is taken in, then the real window prunes it.
        let wide = try await scanner.scan(retainSince: Date().addingTimeInterval(-10 * 86400))
        XCTAssertEqual(tokenSum(wide), 22)
        let records = try await scanner.scan(retainSince: since)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(tokenSum(records), 2)
        XCTAssertEqual(try readCache(cache).records.count, 1)
        // A fresh scan with the real window never admits the old line in the first place.
        let fresh = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(fresh.count, 1)
    }

    func testCacheRoundTrip() async throws {
        let root = try tempTranscriptRoot()
        let cache = root.appendingPathComponent("cache/tokens.json")
        let file = try writeTranscript(root, "p/s.jsonl", assistantLine(id: "msg_1", in: 10, out: 10) + assistantLine(id: "msg_2", in: 20, out: 20))
        let first = try await TokenScanner(root: root, cacheURL: cache).scan(retainSince: since)
        XCTAssertEqual(first.count, 2)
        let consumed = try readCache(cache).offsets[cacheKey(file)]
        XCTAssertEqual(consumed, UInt64(try Data(contentsOf: file).count))

        // Overwrite the consumed prefix in place with a same-length user line: a second scanner that
        // trusted the cache never sees it, one that re-read from 0 would lose msg_1 and msg_2.
        let junk = String(repeating: "x", count: Int(consumed!) - userLine(text: "").utf8.count)
        let cover = userLine(text: junk)
        XCTAssertEqual(UInt64(cover.utf8.count), consumed)
        let fh = try FileHandle(forWritingTo: file)
        try fh.write(contentsOf: cover.data(using: .utf8)!)
        try fh.close()
        try appendTranscript(file, assistantLine(id: "msg_3", in: 1, out: 1))

        let second = try await TokenScanner(root: root, cacheURL: cache).scan(retainSince: since)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(tokenSum(second), 62)
        XCTAssertEqual(Set(try readCache(cache).records.keys), ["msg_1", "msg_2", "msg_3"])

        // A cache from another version is ignored and the files are read again.
        let stale = try Data(contentsOf: cache)
        let downgraded = String(decoding: stale, as: UTF8.self).replacingOccurrences(of: "\"version\":\(TokenScanner.cacheVersion)", with: "\"version\":0")
        XCTAssertNotEqual(downgraded, String(decoding: stale, as: UTF8.self))
        try downgraded.write(to: cache, atomically: true, encoding: .utf8)
        let third = try await TokenScanner(root: root, cacheURL: cache).scan(retainSince: since)
        XCTAssertEqual(Set(third.map(\.total)), [2])
        XCTAssertEqual(try readCache(cache).version, TokenScanner.cacheVersion)
    }

    func testLongLineSpanningChunks() async throws {
        let root = try tempTranscriptRoot()
        let huge = String(repeating: "a", count: 3 * 1024 * 1024)
        let big = String(repeating: "b", count: 1536 * 1024)
        try writeTranscript(root, "p/s.jsonl", userLine(text: huge) + assistantLine(id: "msg_big", in: 5, out: 5, text: big) + assistantLine(id: "msg_small", in: 1, out: 1))
        let records = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(tokenSum(records), 12)
    }

    func testMissingRootThrows() async throws {
        let root = try tempTranscriptRoot().appendingPathComponent("nope")
        do {
            _ = try await TokenScanner(root: root, cacheURL: nil).scan(retainSince: since)
            XCTFail("expected throw")
        } catch let e as TokenScanError {
            XCTAssertEqual(e, .missingRoot(root.path))
            XCTAssertTrue(e.localizedDescription.hasPrefix("No Claude Code transcripts at "))
        }
    }
}

final class TokenWindowTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_000_000)

    func testWeekStartAlignedToReset() {
        let reset = now.addingTimeInterval(2 * 86400)
        let w = TokenWindow.weekStart(resetsAt: reset, now: now)
        XCTAssertEqual(w.start, reset.addingTimeInterval(-7 * 86400))
        XCTAssertTrue(w.aligned)
    }

    func testWeekStartRollsForwardWhenResetPassed() {
        let reset = now.addingTimeInterval(-3 * 3600)
        let w = TokenWindow.weekStart(resetsAt: reset, now: now)
        XCTAssertEqual(w.start, reset)
        XCTAssertTrue(w.aligned)
        // Several cycles behind: the start still lands inside the last 7 days.
        let ancient = now.addingTimeInterval(-30 * 86400 - 3600)
        let far = TokenWindow.weekStart(resetsAt: ancient, now: now)
        XCTAssertEqual(far.start, ancient.addingTimeInterval(28 * 86400))
        XCTAssertTrue(far.start <= now && far.start > now.addingTimeInterval(-7 * 86400))
        // Exactly at the reset: a new cycle begins now.
        XCTAssertEqual(TokenWindow.weekStart(resetsAt: now, now: now).start, now)
    }

    func testWeekStartFallsBackToRolling() {
        let w = TokenWindow.weekStart(resetsAt: nil, now: now)
        XCTAssertEqual(w.start, now.addingTimeInterval(-7 * 86400))
        XCTAssertFalse(w.aligned)
    }

    func testTodayStartUsesCalendar() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TokenWindow.todayStart(now: now, calendar: utc), utc.startOfDay(for: now))
        XCTAssertEqual(utc.component(.hour, from: TokenWindow.todayStart(now: now, calendar: utc)), 0)
        XCTAssertLessThanOrEqual(TokenWindow.todayStart(now: now), now)
    }

    func testUsageExposesWeeklyReset() throws {
        let u = try UsageClient.decoder.decode(UsageResponse.self, from: sampleUsage)
        XCTAssertEqual(u.weeklyResetsAt, u.displayLimits[1].resetsAt)
        XCTAssertNotNil(u.weeklyResetsAt)
    }
}

final class TokenTextTests: XCTestCase {
    func testCompactNumbers() {
        XCTAssertEqual(TokenText.compact(0), "0")
        XCTAssertEqual(TokenText.compact(950), "950")
        XCTAssertEqual(TokenText.compact(1000), "1k")
        XCTAssertEqual(TokenText.compact(12_345), "12.3k")
        XCTAssertEqual(TokenText.compact(999_949), "999.9k")
        XCTAssertEqual(TokenText.compact(999_950), "1M")
        XCTAssertEqual(TokenText.compact(1_000_000), "1M")
        XCTAssertEqual(TokenText.compact(1_234_567), "1.2M")
        XCTAssertEqual(TokenText.compact(2_500_000_000), "2.5B")
    }

    func testCostStrings() {
        var t = TokenTotals()
        t.cost = 12.3449
        XCTAssertEqual(TokenText.cost(t), "$12.34 est.")
        t.unpricedTokens = 5
        XCTAssertEqual(TokenText.cost(t), "≥ $12.34 est.")
        XCTAssertEqual(TokenText.cost(TokenTotals()), "$0.00 est.")
    }

    func testBreakdown() {
        var t = TokenTotals(input: 12_000, output: 4500, cacheWrite: 900_000, cacheRead: 8_200_000)
        XCTAssertEqual(TokenText.breakdown(t), "Input 12k · Output 4.5k · Cache write 900k · Cache read 8.2M")
        t.unpricedTokens = 1500
        XCTAssertTrue(TokenText.breakdown(t).hasSuffix(" · 1.5k from models without a price"))
    }

    func testDollars() {
        XCTAssertEqual(TokenText.dollars(0), "$0.00")
        XCTAssertEqual(TokenText.dollars(0.041), "$0.04")
        XCTAssertEqual(TokenText.dollars(5286.29), "$5,286.29")
        XCTAssertEqual(TokenText.dollars(1_000_000), "$1,000,000.00")
    }

    func testModelNames() {
        XCTAssertEqual(TokenText.modelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(TokenText.modelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(TokenText.modelName("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(TokenText.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(TokenText.modelName("claude-opus-4-1-20250805"), "Opus 4.1")
        XCTAssertEqual(TokenText.modelName("mystery-1"), "mystery-1")
        XCTAssertEqual(TokenText.modelName("claude-"), "claude-")
    }
}

final class CostReportTests: XCTestCase {
    // 2026-09-11 (a Friday) at 20:26:40 UTC.
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func record(_ daysAgo: Int, hour: Int = 12, model: String = "claude-sonnet-5", input: Int = 1000, output: Int = 100,
                session: String? = nil) -> TokenRecord {
        let day = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: now))!
        return TokenRecord(timestamp: day.addingTimeInterval(TimeInterval(hour) * 3600), model: model,
                           input: input, output: output, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                           sessionId: session)
    }

    func testThirtyDaysOldestFirstWithEmptyDays() {
        let report = CostReport.build([record(0), record(29)], now: now, calendar: utc)
        XCTAssertEqual(report.days.count, 30)
        XCTAssertEqual(report.days.last?.start, utc.startOfDay(for: now))
        XCTAssertEqual(report.start, utc.date(byAdding: .day, value: -29, to: utc.startOfDay(for: now)))
        for (a, b) in zip(report.days, report.days.dropFirst()) {
            XCTAssertEqual(utc.dateComponents([.day], from: a.start, to: b.start).day, 1)
        }
        XCTAssertEqual(report.days.first?.totals.tokens, 1100)
        XCTAssertEqual(report.days.last?.totals.tokens, 1100)
        XCTAssertEqual(report.days.filter { $0.totals.tokens == 0 }.count, 28)
    }

    func testBucketsByCalendarDayAndIgnoresOutsideWindow() {
        let records = [record(3, hour: 0), record(3, hour: 23), record(4, hour: 12),
                       record(30), record(400), record(-1)]   // 30 days back, way back, and tomorrow
        let report = CostReport.build(records, now: now, calendar: utc)
        let threeBack = utc.date(byAdding: .day, value: -3, to: utc.startOfDay(for: now))!
        XCTAssertEqual(report.days.first { $0.start == threeBack }?.totals.tokens, 2200)
        XCTAssertEqual(report.total.tokens, 3300)
        XCTAssertEqual(report.today.tokens, 0)
    }

    func testTodayAndTotalSums() {
        let report = CostReport.build([record(0, hour: 1), record(0, hour: 20, output: 400), record(7)], now: now, calendar: utc)
        XCTAssertEqual(report.today.tokens, 2500)
        XCTAssertEqual(report.today.output, 500)
        XCTAssertEqual(report.total.tokens, 3600)
        // Sonnet 5 list price: $2 / M input, $10 / M output.
        let expected: Double = (2.0 * 2000.0 + 10.0 * 500.0) / 1_000_000.0
        XCTAssertEqual(report.today.cost, expected, accuracy: 1e-9)
        XCTAssertEqual(report.total.cost, report.days.reduce(0) { $0 + $1.totals.cost }, accuracy: 1e-9)
    }

    func testModelsSortByCostThenTokensThenName() {
        let records = [
            record(1, model: "claude-opus-5", input: 1000, output: 100),        // $0.0075
            record(1, model: "claude-sonnet-5", input: 1000, output: 100),      // $0.003
            record(2, model: "claude-sonnet-5", input: 1000, output: 100),      // $0.006 total, most tokens
            record(1, model: "mystery-b", input: 500, output: 0),               // unpriced, 500 tokens
            record(1, model: "mystery-a", input: 500, output: 0),               // unpriced, 500 tokens
            record(1, model: "mystery-c", input: 900, output: 0),               // unpriced, 900 tokens
        ]
        let report = CostReport.build(records, now: now, calendar: utc)
        XCTAssertEqual(report.models.map(\.model), ["claude-opus-5", "claude-sonnet-5", "mystery-c", "mystery-a", "mystery-b"])
        XCTAssertEqual(report.models[1].totals.tokens, 2200)
        XCTAssertEqual(report.models[2].totals.unpricedTokens, 900)
        XCTAssertEqual(report.total.unpricedTokens, 1900)
    }

    func testEmptyRecords() {
        let report = CostReport.build([], now: now, calendar: utc)
        XCTAssertEqual(report.days.count, 30)
        XCTAssertTrue(report.models.isEmpty)
        XCTAssertEqual(report.total, TokenTotals())
        XCTAssertEqual(report.today, TokenTotals())
    }

    func testRangeSetsTheDayCount() {
        let records = [record(0), record(6), record(7), record(29), record(30), record(89), record(90)]
        for range in CostRange.allCases {
            let report = CostReport.build(records, now: now, calendar: utc, dayCount: range.days)
            XCTAssertEqual(report.days.count, range.days, "\(range)")
            XCTAssertEqual(report.start, utc.date(byAdding: .day, value: 1 - range.days, to: utc.startOfDay(for: now)), "\(range)")
            XCTAssertEqual(report.days.last?.start, utc.startOfDay(for: now), "\(range)")
        }
        XCTAssertEqual(CostReport.build(records, now: now, calendar: utc, dayCount: 7).total.tokens, 2200)
        XCTAssertEqual(CostReport.build(records, now: now, calendar: utc, dayCount: 30).total.tokens, 4400)
        XCTAssertEqual(CostReport.build(records, now: now, calendar: utc, dayCount: 90).total.tokens, 6600)
    }

    func testCostRangeCoversNinetyDaysAndRetentionOneMore() {
        XCTAssertEqual(CostRange.allCases.map(\.days), [7, 30, 90])
        XCTAssertEqual(CostRange.month.days, CostReport.dayCount)
        XCTAssertEqual(CostRange.retentionDays, 91)
        XCTAssertEqual(TokenStore.retention, 91 * 86400)
        XCTAssertEqual(CostRange.allCases.map(\.axisStride), [1, 7, 14])
        XCTAssertEqual(CostRange.quarter.title, "90 days")
    }

    func testShareText() {
        XCTAssertEqual(CostView.shareText(37, of: 100, in: .month), "37% of the last 30 days' tokens")
        XCTAssertEqual(CostView.shareText(1, of: 3, in: .week), "33% of the last 7 days' tokens")
        XCTAssertEqual(CostView.shareText(0, of: 0, in: .quarter), "No tokens in the last 90 days")
    }

    @MainActor func testCostWindowStartIsTwentyNineDaysBeforeMidnight() {
        let start = TokenStore.costWindowStart(now: now, calendar: utc)
        XCTAssertEqual(start, utc.date(byAdding: .day, value: -29, to: utc.startOfDay(for: now)))
        XCTAssertEqual(start, CostReport.build([], now: now, calendar: utc).start)
    }

    func testAxisDollars() {
        XCTAssertEqual(CostView.axisDollars(0), "$0")
        XCTAssertEqual(CostView.axisDollars(12.6), "$13")
        XCTAssertEqual(CostView.axisDollars(0.5), "$0.50")
        XCTAssertEqual(CostView.axisDollars(1.5), "$1.50")
        XCTAssertEqual(CostView.axisDollars(2), "$2")
        XCTAssertEqual(CostView.axisDollars(1500), "$1.5k")
    }
}

final class SessionScanTests: XCTestCase {
    func testRecordsCarrySessionAndMetaLinesBuildSessions() async throws {
        let root = try tempTranscriptRoot()
        let t0 = Date().addingTimeInterval(-3600)
        let t1 = Date().addingTimeInterval(-60)
        // Bookkeeping lines arrive before the first answer and are rewritten as the session goes.
        let file = try writeTranscript(root, "p/a.jsonl",
            metaLine("agent-color", session: "a", "agentColor", "pink")
            + metaLine("ai-title", session: "a", "aiTitle", "First title")
            + metaLine("last-prompt", session: "a", "lastPrompt", "make it\\ncompact")
            + assistantLine(id: "msg_a1", ts: t0, in: 10, out: 10, session: "a", cwd: "/Users/sam/x", branch: "main", slug: "sunny-fox")
            + metaLine("ai-title", session: "a", "aiTitle", "Second title")
            + assistantLine(id: "msg_a2", ts: t1, in: 20, out: 20, session: "a"))
        // A subagent transcript under the session folder carries the parent's session id.
        try writeTranscript(root, "p/a/subagents/agent-1.jsonl",
            assistantLine(id: "msg_sub", ts: t1, in: 100, out: 0, session: "a", cwd: "/Users/sam/x"))
        try writeTranscript(root, "p/b.jsonl", assistantLine(id: "msg_b1", ts: t1, in: 1, out: 1, session: "b"))

        let scanner = TokenScanner(root: root, cacheURL: nil)
        let records = try await scanner.scan(retainSince: .distantPast)
        XCTAssertEqual(records.filter { $0.sessionId == "a" }.count, 3)
        XCTAssertEqual(records.filter { $0.sessionId == "b" }.count, 1)
        XCTAssertEqual(records.filter { $0.sessionId == "a" }.reduce(0) { $0 + $1.total }, 160)

        let sessions = Dictionary(uniqueKeysWithValues: await scanner.sessions().map { ($0.sessionId, $0) })
        let a = try XCTUnwrap(sessions["a"])
        XCTAssertEqual(a.title, "Second title")
        XCTAssertEqual(a.color, "pink")
        XCTAssertEqual(a.lastPrompt, "make it compact")
        XCTAssertEqual(a.cwd, "/Users/sam/x")
        XCTAssertEqual(a.gitBranch, "main")
        XCTAssertEqual(a.slug, "sunny-fox")
        XCTAssertEqual(a.firstSeen.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(a.lastSeen.timeIntervalSince1970, t1.timeIntervalSince1970, accuracy: 1)
        let b = try XCTUnwrap(sessions["b"])
        XCTAssertNil(b.title)
        XCTAssertNil(b.color)

        // An appended title shows up on the next incremental scan; the file offset carries over.
        try appendTranscript(file, metaLine("ai-title", session: "a", "aiTitle", "Third title"))
        _ = try await scanner.scan(retainSince: .distantPast)
        let rescanned = await scanner.sessions()
        XCTAssertEqual(rescanned.first { $0.sessionId == "a" }?.title, "Third title")
    }

    func testLongPromptIsClippedAndOldSessionsArePruned() async throws {
        let root = try tempTranscriptRoot()
        let old = Date().addingTimeInterval(-10 * 86400)
        let long = String(repeating: "x", count: 500)
        try writeTranscript(root, "p/a.jsonl",
            metaLine("last-prompt", session: "a", "lastPrompt", long)
            + assistantLine(id: "msg_a1", session: "a")
            + assistantLine(id: "msg_old", ts: old, session: "old"))
        let scanner = TokenScanner(root: root, cacheURL: nil)
        _ = try await scanner.scan(retainSince: Date().addingTimeInterval(-8 * 86400))
        let sessions = await scanner.sessions()
        XCTAssertEqual(sessions.map(\.sessionId), ["a"])
        XCTAssertEqual(sessions[0].lastPrompt?.count, 121)
        XCTAssertTrue(sessions[0].lastPrompt!.hasSuffix("…"))
    }

    func testSessionMetaSurvivesTheCache() async throws {
        let root = try tempTranscriptRoot()
        let cacheURL = root.appendingPathComponent("tokens.json")
        try writeTranscript(root, "p/a.jsonl",
            metaLine("ai-title", session: "a", "aiTitle", "Kept") + assistantLine(id: "msg_a1", session: "a"))
        _ = try await TokenScanner(root: root, cacheURL: cacheURL).scan(retainSince: .distantPast)

        let reopened = TokenScanner(root: root, cacheURL: cacheURL)
        let records = try await reopened.scan(retainSince: .distantPast)
        XCTAssertEqual(records.first?.sessionId, "a")
        let sessions = await reopened.sessions()
        XCTAssertEqual(sessions.first?.title, "Kept")
    }
}

final class SessionRegistryTests: XCTestCase {
    func testLiveFiltersDeadProcessesAndOtherKinds() throws {
        let root = try tempRegistryRoot([
            (10, registryEntry(pid: 10, session: "alive-busy", status: "busy", name: "Renamed", nameSource: "user")),
            (11, registryEntry(pid: 11, session: "alive-idle")),
            (12, registryEntry(pid: 12, session: "dead")),
            (13, registryEntry(pid: 13, session: "headless", kind: "headless")),
        ])
        try "not json".write(to: root.appendingPathComponent("14.json"), atomically: true, encoding: .utf8)
        let registry = SessionRegistry(root: root) { $0 != 12 }
        let live = registry.live().sorted { $0.pid < $1.pid }
        XCTAssertEqual(live.map(\.sessionId), ["alive-busy", "alive-idle"])
        XCTAssertTrue(live[0].isBusy)
        XCTAssertFalse(live[1].isBusy)
        XCTAssertEqual(live[0].userName, "Renamed")
        XCTAssertNil(live[1].userName)
        XCTAssertEqual(live[0].cwd, "/Users/sam")
        XCTAssertEqual(live[0].started?.timeIntervalSince1970 ?? 0, 1_789_754_103.203, accuracy: 0.01)
    }

    func testDuplicateSessionKeepsNewestEntry() throws {
        let root = try tempRegistryRoot([
            (20, registryEntry(pid: 20, session: "same", status: "idle", updatedAt: 1000)),
            (21, registryEntry(pid: 21, session: "same", status: "busy", updatedAt: 2000)),
        ])
        let live = SessionRegistry(root: root) { _ in true }.live()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].pid, 21)
    }

    func testMissingRootIsEmpty() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cub-none-\(UUID().uuidString)")
        XCTAssertEqual(SessionRegistry(root: root) { _ in true }.live(), [])
    }
}

final class SessionRowTests: XCTestCase {
    @MainActor
    func testRowsJoinRegistryAndTranscriptsInOrder() async throws {
        let root = try tempTranscriptRoot()
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)
        let yesterday = TokenWindow.todayStart(now: now).addingTimeInterval(-3600)
        try writeTranscript(root, "p/busy.jsonl",
            metaLine("ai-title", session: "busy", "aiTitle", "Busy one")
            + assistantLine(id: "m1", ts: earlier, in: 100, out: 0, session: "busy"))
        try writeTranscript(root, "p/idle-new.jsonl", assistantLine(id: "m2", ts: now, in: 10, out: 0, session: "idle-new"))
        try writeTranscript(root, "p/idle-old.jsonl", assistantLine(id: "m3", ts: earlier, in: 20, out: 0, session: "idle-old"))
        try writeTranscript(root, "p/closed.jsonl",
            metaLine("last-prompt", session: "closed", "lastPrompt", "fix the tests")
            + assistantLine(id: "m4", ts: now.addingTimeInterval(-120), in: 30, out: 0, session: "closed"))
        try writeTranscript(root, "p/stale.jsonl", assistantLine(id: "m5", ts: yesterday, in: 40, out: 0, session: "stale"))
        let registry = try tempRegistryRoot([
            (1, registryEntry(pid: 1, session: "idle-old")),
            (2, registryEntry(pid: 2, session: "busy", status: "busy")),
            (3, registryEntry(pid: 3, session: "idle-new")),
            // Never answered, so its last activity is the registry write: two hours ago, behind "busy".
            (4, registryEntry(pid: 4, session: "fresh", status: "busy",
                              updatedAt: now.addingTimeInterval(-7200).timeIntervalSince1970 * 1000,
                              name: "Fresh", nameSource: "user")),
        ])

        let store = TokenStore()
        store.scanner = TokenScanner(root: root, cacheURL: nil)
        store.registry = SessionRegistry(root: registry) { _ in true }
        await store.refresh(reason: "test")
        XCTAssertEqual(store.openCount, 4)
        XCTAssertEqual(store.busyCount, 2)

        let rows = store.sessionRows(closedSince: TokenWindow.todayStart(now: now))
        XCTAssertEqual(rows.map(\.id), ["busy", "fresh", "idle-new", "idle-old", "closed"])
        XCTAssertEqual(rows.map(\.isOpen), [true, true, true, true, false])
        XCTAssertEqual(rows[0].title, "Busy one")
        XCTAssertEqual(rows[0].totals.tokens, 100)
        XCTAssertEqual(rows[1].title, "Fresh")
        XCTAssertEqual(rows[1].totals.tokens, 0)
        XCTAssertEqual(rows[2].title, "idle-new")
        XCTAssertEqual(rows[4].title, "fix the tests")
        XCTAssertEqual(rows[4].totals.tokens, 30)
        XCTAssertNotNil(rows[1].started, "a session that has not answered yet dates from its process start")
    }

    func testTextHelpers() {
        XCTAssertEqual(SessionText.folder("/Users/sam/Coding/proj", home: "/Users/sam"), "~/Coding/proj")
        XCTAssertEqual(SessionText.folder("/Users/sam", home: "/Users/sam"), "~")
        XCTAssertEqual(SessionText.folder("/Volumes/Storage/Coding/proj", home: "/Users/sam"), "Coding/proj")
        let now = Date()
        XCTAssertEqual(SessionText.duration(from: now.addingTimeInterval(-90), to: now), "1m")
        XCTAssertEqual(SessionText.duration(from: now.addingTimeInterval(-(2 * 3600 + 14 * 60)), to: now), "2h 14m")
        XCTAssertEqual(SessionText.duration(from: now.addingTimeInterval(-(86400 + 3 * 3600)), to: now), "1d 3h")
        XCTAssertEqual(SessionText.ago(now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(SessionText.ago(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(SessionText.ago(now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(SessionColor.color(named: "pink"), .pink)
        XCTAssertEqual(SessionColor.color(named: nil), .secondary)
    }
}

final class TokenStoreTests: XCTestCase {
    @MainActor
    func testRefreshPopulatesAndReportsMissingRoot() async throws {
        let root = try tempTranscriptRoot()
        try writeTranscript(root, "p/s.jsonl", assistantLine(id: "msg_1", in: 10, out: 10) + assistantLine(id: "msg_2", in: 20, out: 20))
        let store = TokenStore()
        store.scanner = TokenScanner(root: root, cacheURL: nil)
        store.registry = SessionRegistry(root: root) { _ in true }
        XCTAssertNil(store.lastScanned)

        await store.refresh(reason: "test")
        XCTAssertEqual(store.records.count, 2)
        XCTAssertNotNil(store.lastScanned)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.totals(since: .distantPast).tokens, 60)
        XCTAssertEqual(store.totals(since: .distantFuture).tokens, 0)

        store.scanner = TokenScanner(root: root.appendingPathComponent("missing"), cacheURL: nil)
        await store.refresh(reason: "test")
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.error!.hasPrefix("No Claude Code transcripts at "))
        XCTAssertEqual(store.records.count, 2)

        store.scanner = TokenScanner(root: root, cacheURL: nil)
        await store.refresh(reason: "test")
        XCTAssertNil(store.error)
    }
}

// MARK: - Session launcher

/// Records every command the launcher would run and answers from a script of stdout strings.
final class FakeRunner: @unchecked Sendable {
    var commands: [SessionLauncher.Command] = []
    var replies: [String]

    init(replies: [String] = []) { self.replies = replies }

    func run(_ command: SessionLauncher.Command) async throws -> String {
        commands.append(command)
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}

final class SessionLauncherTests: XCTestCase {
    private func launcher(existing: Set<String>, runner: FakeRunner, configured: Bool = true) -> SessionLauncher {
        var launcher = SessionLauncher(settings: configured
            ? AppConfig.Settings.Resume(launcher: "/l/launch-claude.sh", envFile: "/l/launcher.env") : nil)
        launcher.fileExists = { existing.contains($0) }
        launcher.run = { try await runner.run($0) }
        return launcher
    }

    private func closedRow(id: String = "abc-123", cwd: String? = "/work", color: String? = "cyan") -> SessionRow {
        var meta = SessionMeta(sessionId: id, firstSeen: .distantFuture, lastSeen: .distantPast)
        meta.cwd = cwd
        meta.color = color
        return SessionRow(id: id, live: nil, meta: meta, totals: TokenTotals())
    }

    private func openRow(pid: Int32, id: String = "open-1") -> SessionRow {
        SessionRow(id: id, live: LiveSession(pid: pid, sessionId: id, cwd: "/work"), meta: nil, totals: TokenTotals())
    }

    /// Without a config file, Terminal gets a new window running `claude --resume` in the
    /// session's folder. No colour is passed: Claude Code restores the session's own colour.
    func testResumeWithoutConfigOpensTerminalOnClaudeResume() async throws {
        let runner = FakeRunner()
        let launcher = launcher(existing: ["/work"], runner: runner, configured: false)
        try await launcher.resume(closedRow(color: "cyan"))
        XCTAssertEqual(runner.commands, [SessionLauncher.Command(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Terminal\"\ndo script \"cd '/work' && claude --resume 'abc-123'\"\nactivate\nend tell"])])
    }

    func testTerminalScriptEscapesShellAndAppleScriptQuoting() {
        // Shell: single quotes, with ' as '\''. AppleScript: backslashes and double quotes escaped.
        let script = SessionLauncher.terminalScript(cwd: "/it's \"here\"", sessionId: "id")
        let lines = script.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "tell application \"Terminal\"")
        XCTAssertEqual(lines[1], #"do script "cd '/it'\\''s \"here\"' && claude --resume 'id'""#)
        XCTAssertEqual(lines[2], "activate")
        XCTAssertEqual(lines[3], "end tell")
    }

    /// A configured launcher gets the env file exported, then the script exec'd, with the session
    /// and its folder in the environment and nothing else.
    func testResumeWithConfiguredLauncherExportsEnvFileThenExecsIt() async throws {
        let runner = FakeRunner()
        let launcher = launcher(existing: ["/work", "/l/launcher.env", "/l/launch-claude.sh"], runner: runner)
        try await launcher.resume(closedRow(color: "cyan"))
        XCTAssertEqual(runner.commands, [SessionLauncher.Command(
            executable: "/bin/bash",
            arguments: ["-c", "set -a; [ -f '/l/launcher.env' ] && . '/l/launcher.env'; set +a; exec '/l/launch-claude.sh'"],
            environment: ["CLAUDE_RESUME": "abc-123", "CLAUDE_LAUNCH_DIR": "/work"])])
    }

    func testConfiguredLauncherWithoutEnvFileJustExecs() throws {
        var launcher = SessionLauncher(settings: AppConfig.Settings.Resume(launcher: "/l/go.sh"))
        launcher.fileExists = { _ in true }
        XCTAssertEqual(try launcher.resumeCommand(sessionId: "abc", cwd: "/work").arguments, ["-c", "exec '/l/go.sh'"])
    }

    func testConfigFileDecodesSnakeCaseAndExpandsTilde() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try #"{"resume": {"launcher": "~/bin/go.sh", "env_file": "~/bin/go.env"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let settings = AppConfig.loadSettings(from: file)
        XCTAssertEqual(settings.resume, AppConfig.Settings.Resume(launcher: "~/bin/go.sh", envFile: "~/bin/go.env"))
        let launcher = SessionLauncher(settings: settings.resume)
        XCTAssertEqual(launcher.launcher?.path, NSHomeDirectory() + "/bin/go.sh")
        XCTAssertEqual(launcher.envFile?.path, NSHomeDirectory() + "/bin/go.env")
        XCTAssertEqual(AppConfig.loadSettings(from: dir.appendingPathComponent("missing.json")), AppConfig.Settings())
        XCTAssertNil(AppConfig.loadAntigravityClient(from: dir.appendingPathComponent("missing.json")))
        let client = dir.appendingPathComponent("antigravity-client.json")
        try #"{"client_id": "cid", "client_secret": "cs"}"#.write(to: client, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppConfig.loadAntigravityClient(from: client), AppConfig.OAuthClient(clientId: "cid", clientSecret: "cs"))
        try #"{"client_id": "", "client_secret": "cs"}"#.write(to: client, atomically: true, encoding: .utf8)
        XCTAssertNil(AppConfig.loadAntigravityClient(from: client))
    }

    /// The real thing: an env file with EFFORT=xhigh must reach the launcher as an exported variable.
    func testResumeScriptExportsEnvFileToTheLauncher() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# comment\nEFFORT=xhigh\n".write(to: dir.appendingPathComponent("launcher.env"), atomically: true, encoding: .utf8)
        let fake = dir.appendingPathComponent("launch-claude.sh")
        try "#!/bin/bash\nprintf '%s|%s|%s|%s' \"$EFFORT\" \"$CLAUDE_RESUME\" \"$CLAUDE_LAUNCH_DIR\" \"${CLAUDE_LAUNCH_COLOR-unset}\"\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let launcher = SessionLauncher(settings: AppConfig.Settings.Resume(
            launcher: fake.path, envFile: dir.appendingPathComponent("launcher.env").path))
        let output = try await launcher.run(try launcher.resumeCommand(sessionId: "abc", cwd: dir.path))
        XCTAssertEqual(output, "xhigh|abc|\(dir.path)|unset")
    }

    func testShellQuoting() {
        XCTAssertEqual(SessionLauncher.quoted("/a b/c"), "'/a b/c'")
        XCTAssertEqual(SessionLauncher.quoted("/it's"), "'/it'\\''s'")
    }

    func testResumeRefusesMissingFolderOrLauncher() {
        let none = launcher(existing: ["/work", "/l/launcher.env"], runner: FakeRunner())
        XCTAssertThrowsError(try none.resumeCommand(sessionId: "abc", cwd: "/work")) {
            XCTAssertEqual($0 as? SessionLauncher.Failure, .noLauncher("/l/launch-claude.sh"))
        }
        let gone = launcher(existing: ["/l/launch-claude.sh"], runner: FakeRunner())
        XCTAssertThrowsError(try gone.resumeCommand(sessionId: "abc", cwd: "/gone")) {
            XCTAssertEqual($0 as? SessionLauncher.Failure, .noWorkingDirectory("/gone"))
        }
        XCTAssertThrowsError(try gone.resumeCommand(sessionId: "abc", cwd: nil)) {
            XCTAssertEqual($0 as? SessionLauncher.Failure, .noWorkingDirectory(nil))
        }
    }

    func testFocusLooksUpTTYThenRaisesTerminalWindow() async throws {
        let runner = FakeRunner(replies: ["ttys004\n", "ok\n"])
        let launcher = launcher(existing: [], runner: runner)
        try await launcher.focus(openRow(pid: 4242))
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(runner.commands[0].executable, "/bin/ps")
        XCTAssertEqual(runner.commands[0].arguments, ["-o", "tty=", "-p", "4242"])
        XCTAssertEqual(runner.commands[1].executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.commands[1].arguments.first, "-e")
        XCTAssertTrue(runner.commands[1].arguments[1].contains("if tty of t is \"/dev/ttys004\""))
        XCTAssertTrue(runner.commands[1].arguments[1].contains("tell application \"Terminal\""))
    }

    func testFocusReportsNoTerminalAndNoTTY() async {
        let missing = launcher(existing: [], runner: FakeRunner(replies: ["ttys004\n", "none\n"]))
        do {
            try await missing.focus(openRow(pid: 7))
            XCTFail("expected noTerminalWindow")
        } catch {
            XCTAssertEqual(error as? SessionLauncher.Failure, .noTerminalWindow(7, "/dev/ttys004"))
        }
        let headless = launcher(existing: [], runner: FakeRunner(replies: ["??\n"]))
        do {
            try await headless.focus(openRow(pid: 8))
            XCTFail("expected noTTY")
        } catch {
            XCTAssertEqual(error as? SessionLauncher.Failure, .noTTY(8))
        }
    }

    func testTTYParsing() {
        XCTAssertEqual(SessionLauncher.tty(fromPS: "ttys000\n"), "/dev/ttys000")
        XCTAssertEqual(SessionLauncher.tty(fromPS: "  ttys12 "), "/dev/ttys12")
        XCTAssertNil(SessionLauncher.tty(fromPS: "??\n"))
        XCTAssertNil(SessionLauncher.tty(fromPS: ""))
        XCTAssertNil(SessionLauncher.tty(fromPS: "tty\"s0"))
    }
}

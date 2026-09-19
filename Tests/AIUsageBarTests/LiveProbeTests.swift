import XCTest
@testable import AIUsageBar

/// Starts the real `claude` on a pty. Skipped unless AIUSAGEBAR_LIVE_PROBE=1: it needs a signed-in
/// Claude Code on the machine and answers the trust question for the app's own probe folder.
final class LiveProbeTests: XCTestCase {
    func testProbeStartsAndStopsClaude() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIUSAGEBAR_LIVE_PROBE"] == "1")
        let mode = ProcessInfo.processInfo.environment["AIUSAGEBAR_LIVE_PROBE_TRUST"] ?? "leave"
        var probe = ClaudeCLIProbe()
        probe.timeout = 12
        probe.trustAfter = mode == "accept" ? 4 : 60
        XCTAssertNotNil(probe.binary)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: probe.sessionsRoot.path)) ?? [])
        let changed = try await probe.run(until: { false })
        XCTAssertFalse(changed)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: probe.sessionsRoot.path)) ?? [])
        XCTAssertEqual(after.subtracting(before), [], "probe left registry files behind")
        let log = try String(contentsOf: ClaudeCLIProbe.logFile, encoding: .utf8)
        print("LIVE PROBE LOG:\n\(log)")
        // The trust question, or the prompt of a trusted folder (its screen is a banner and a bare marker).
        XCTAssertTrue(log.contains("trustthisfolder") || log.contains("❯"), "no trust question or prompt seen")
        XCTAssertTrue(log.contains("exit clean"), "claude did not leave on its own: \(log.prefix(200))")
    }
}

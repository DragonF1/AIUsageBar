import XCTest
@testable import AIUsageBar

/// `ps -axo pid=,command=` as macOS prints it: the IDE's main server, a per-workspace server on
/// the other backend, a shell whose command line quotes the same words, and an unrelated process.
private let psFixture = """
  512 /sbin/launchd
96528 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token tok-main --extension_server_port 62160 --extension_server_csrf_token tok-ext --app_data_dir antigravity-ide --subclient_type ide --cloud_code_endpoint https://cloudcode-pa.googleapis.com
96854 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --enable_lsp --csrf_token=tok-lsp --workspace_id file_Users_someone_Code_project --cloud_code_endpoint=https://daily-cloudcode-pa.googleapis.com
65037 /bin/zsh -c ps -axo pid=,command= | grep -i 'language_server' | grep -i antigravity --csrf_token nope
70001 /Applications/Antigravity IDE.app/Contents/MacOS/Electron --type=renderer
"""

private let lsofFixture = """
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
language_ 96528 someone    7u  IPv4 0x5ea92ff170fbd24f      0t0  TCP 127.0.0.1:62187 (LISTEN)
language_ 96528 someone    8u  IPv4 0x574d64b316b50cde      0t0  TCP 127.0.0.1:62185 (LISTEN)
language_ 96528 someone    9u  IPv6 0x574d64b316b50cdf      0t0  TCP [::1]:62185 (LISTEN)
language_ 96528 someone   10u  IPv4 0x574d64b316b50ce0      0t0  TCP 127.0.0.1:62190->127.0.0.1:443 (ESTABLISHED)
"""

/// `RetrieveUserQuotaSummary` wraps the backend's payload in `response`.
let localQuotaFixture = Data(("{\"response\":" + String(decoding: antigravityFixture, as: UTF8.self) + "}").utf8)
let localStatusFixture = Data(#"{"userStatus":{"name":"x","email":"x@example.com","planStatus":{"planInfo":{"planName":"Pro"}},"userTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}}"#.utf8)

final class AntigravityLocalProbeTests: XCTestCase {
    private func ok(_ body: Data) -> HTTPResponse { HTTPResponse(status: 200, headers: [:], body: body) }
    private func status(_ code: Int) -> HTTPResponse { HTTPResponse(status: code, headers: [:], body: Data()) }

    private func makeProbe(http: FakeHTTP, ps: String = psFixture, lsof: String = lsofFixture) -> AntigravityLocalProbe {
        var probe = AntigravityLocalProbe()
        probe.processList = { ps }
        probe.listeningPorts = { _ in lsof }
        probe.http = http
        return probe
    }

    func testFindsTheLanguageServersAndTheirFlags() {
        let servers = AntigravityLocalProbe.servers(in: psFixture)
        XCTAssertEqual(servers, [
            .init(pid: 96528, csrfToken: "tok-main", endpoint: "https://cloudcode-pa.googleapis.com"),
            .init(pid: 96854, csrfToken: "tok-lsp", endpoint: "https://daily-cloudcode-pa.googleapis.com"),
        ])
    }

    func testFlagNeedsItsOwnDashes() {
        let line = "bin --extension_server_csrf_token tok-ext --csrf_token=tok-main --cloud_code_endpoint"
        XCTAssertEqual(AntigravityLocalProbe.flag("csrf_token", in: line), "tok-main")
        XCTAssertNil(AntigravityLocalProbe.flag("cloud_code_endpoint", in: line), "a flag with no value is no value")
        XCTAssertNil(AntigravityLocalProbe.flag("csrf", in: line), "a prefix of a flag is not that flag")
    }

    func testListeningPortsAscendingAndOnce() {
        XCTAssertEqual(AntigravityLocalProbe.ports(in: lsofFixture), [62185, 62187])
        XCTAssertEqual(AntigravityLocalProbe.ports(in: ""), [])
    }

    func testPreferredBackendFirstThenLowestPid() {
        let servers = AntigravityLocalProbe.servers(in: psFixture)
        XCTAssertEqual(AntigravityLocalProbe.ordered(servers, preferring: nil).map(\.pid), [96528, 96854])
        XCTAssertEqual(AntigravityLocalProbe.ordered(servers, preferring: AntigravityClient.dailyHost).map(\.pid), [96854, 96528])
        XCTAssertEqual(AntigravityLocalProbe.ordered(servers.reversed(), preferring: "https://example.com").map(\.pid), [96528, 96854])
    }

    func testRequestShape() {
        let req = AntigravityLocalProbe.request(port: 62185, rpc: AntigravityLocalProbe.quotaRPC,
                                                body: AntigravityLocalProbe.quotaBody, token: "tok-main")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://127.0.0.1:62185/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "tok-main")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "no Google token goes to the local server")
        XCTAssertEqual(req.httpBody, Data(#"{"forceRefresh":true}"#.utf8))
    }

    func testFetchTriesEachPortAndReadsTheEnvelope() async throws {
        // 62185 refuses (a 404 here stands in for it), 62187 answers both calls.
        let http = FakeHTTP([status(404), ok(localQuotaFixture), ok(localStatusFixture)])
        let result = try await makeProbe(http: http).fetch()

        XCTAssertEqual(http.requests.map { $0.url?.port }, [62185, 62187, 62187])
        XCTAssertEqual(http.requests[2].url?.lastPathComponent, "GetUserStatus")
        XCTAssertEqual(http.requests[2].httpBody, Data(AntigravityLocalProbe.statusBody.utf8))
        XCTAssertEqual(result.pid, 96528)
        XCTAssertEqual(result.port, 62187)
        XCTAssertEqual(result.endpoint, "https://cloudcode-pa.googleapis.com")
        XCTAssertEqual(result.tier, "Google AI Pro")
        XCTAssertEqual(result.summary.logLine, "gemini-weekly=0.4851 gemini-5h=1.0000 3p-weekly=0.6651 3p-5h=1.0000")
    }

    func testStatusFailureOnlyCostsTheTier() async throws {
        let http = FakeHTTP([ok(localQuotaFixture), status(500)])
        let result = try await makeProbe(http: http).fetch()
        XCTAssertNil(result.tier)
        XCTAssertEqual(result.summary.groups?.count, 2)
    }

    func testPlanNameIsTheFallbackTier() async throws {
        let http = FakeHTTP([ok(localQuotaFixture), ok(Data(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"}}}}"#.utf8))])
        let result = try await makeProbe(http: http).fetch()
        XCTAssertEqual(result.tier, "Pro")
    }

    func testPreferredBackendPicksTheServer() async throws {
        let http = FakeHTTP([ok(localQuotaFixture), ok(localStatusFixture)])
        let result = try await makeProbe(http: http).fetch(preferring: AntigravityClient.dailyHost)
        XCTAssertEqual(result.pid, 96854)
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "tok-lsp")
    }

    func testNoServerMeansNotRunning() async {
        let http = FakeHTTP([])
        do {
            _ = try await makeProbe(http: http, ps: "  512 /sbin/launchd\n").fetch()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AntigravityLocalProbeError, .notRunning)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testEveryPortFailingReportsTheLastOne() async {
        // Two servers, two ports each, every quota call rejected.
        let http = FakeHTTP([status(401), status(401), status(401), status(401)])
        do {
            _ = try await makeProbe(http: http).fetch()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AntigravityLocalProbeError,
                           .unreachable("pid 96854 port 62187: Antigravity's language server answered HTTP 401."))
        }
        XCTAssertEqual(http.requests.count, 4)
    }

    func testEmptyGroupsCountAsNoAnswer() async {
        let http = FakeHTTP([ok(Data(#"{"response":{"groups":[]}}"#.utf8)), ok(Data(#"{}"#.utf8)),
                             ok(Data(#"{"response":{"groups":[]}}"#.utf8)), ok(Data(#"{}"#.utf8))])
        do {
            _ = try await makeProbe(http: http).fetch()
            XCTFail("should throw")
        } catch {
            guard case .unreachable(let why)? = error as? AntigravityLocalProbeError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("no quota groups"), why)
        }
    }
}

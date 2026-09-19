import Foundation

enum AntigravityLocalProbeError: LocalizedError, Equatable {
    case notRunning
    case unreachable(String)
    case rejected(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Antigravity is not running."
        case .unreachable(let why): return "Antigravity's language server did not answer: \(why)"
        case .rejected(let status): return "Antigravity's language server answered HTTP \(status)."
        case .decoding(let msg): return "Could not read Antigravity's local quota answer: \(msg)"
        }
    }
}

/// Asks the running Antigravity IDE for the numbers behind its own quota panel. Its language
/// server (`language_server_macos_arm` inside the app bundle) answers Connect RPCs over HTTPS on
/// a localhost port with a self-signed certificate, guarded by the CSRF token on its own command
/// line; both are readable through `ps` and `lsof` by any process of the same user, which is how
/// CodexBar reads them too. The IDE keeps its own login fresh, so this works while the token path
/// is stuck: no token file, login expired with no refresh client, or a token the backend rejects.
/// Read-only: the two calls are the ones the panel makes, and the token is never logged or stored.
struct AntigravityLocalProbe {
    struct Server: Equatable {
        var pid: Int32
        var csrfToken: String
        /// The `--cloud_code_endpoint` the server talks to: the backend that metered its numbers.
        var endpoint: String?
    }

    struct Result {
        var summary: AntigravityQuotaSummary
        var tier: String?
        var endpoint: String?
        var pid: Int32
        var port: Int
    }

    static let service = "/exa.language_server_pb.LanguageServerService/"
    static let quotaRPC = "RetrieveUserQuotaSummary"
    static let statusRPC = "GetUserStatus"
    /// The panel's own body: the server refetches from the backend instead of answering from memory.
    static let quotaBody = #"{"forceRefresh":true}"#
    /// What every request from the IDE carries.
    static let statusBody = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
    static let timeout: TimeInterval = 5

    var processList: @Sendable () throws -> String = {
        try Shell.run("/bin/ps", ["-axo", "pid=,command="]).stdout
    }
    var listeningPorts: @Sendable (Int32) throws -> String = { pid in
        try Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)]).stdout
    }
    var http: HTTPClient = LocalhostHTTPClient()

    // MARK: - Parsing

    /// Every Antigravity language server in `ps -axo pid=,command=` output: the binary is named
    /// `language_server` (with a platform suffix) under a path that mentions Antigravity, and the
    /// command line carries `--csrf_token`. A shell whose command line merely quotes those words
    /// has neither the path nor the flag.
    static func servers(in ps: String) -> [Server] {
        ps.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: #/^\s*(\d+)\s+(.*)$/#), let pid = Int32(match.1) else { return nil }
            let command = String(match.2)
            guard command.contains(#/(^|/)language[_-]server[^/\s]*(\s|$)/#.ignoresCase()),
                  command.contains(#/antigravity/#.ignoresCase()),
                  let token = flag("csrf_token", in: command) else { return nil }
            return Server(pid: pid, csrfToken: token, endpoint: flag("cloud_code_endpoint", in: command))
        }
    }

    /// `--name value` or `--name=value`; the name must follow `--` directly, so `--csrf_token`
    /// never reads `--extension_server_csrf_token`.
    static func flag(_ name: String, in command: String) -> String? {
        guard let range = command.range(of: "--\(name)") else { return nil }
        var rest = command[range.upperBound...]
        guard let first = rest.first, first == "=" || first == " " else { return nil }
        rest = rest.drop { $0 == "=" || $0 == " " }
        let value = rest.prefix { $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    /// Listening TCP ports in `lsof -nP -iTCP -sTCP:LISTEN` output, ascending, each once.
    static func ports(in lsof: String) -> [Int] {
        var seen = Set<Int>()
        for match in lsof.matches(of: #/:(\d+)\s+\(LISTEN\)/#) {
            if let port = Int(match.1) { seen.insert(port) }
        }
        return seen.sorted()
    }

    /// The server whose backend the caller already trusts first, then the IDE's main server
    /// (the lowest pid; the per-workspace servers come later and can point at the other backend).
    static func ordered(_ servers: [Server], preferring host: String?) -> [Server] {
        servers.sorted { a, b in
            let aPreferred = a.endpoint == host, bPreferred = b.endpoint == host
            if aPreferred != bPreferred { return aPreferred }
            return a.pid < b.pid
        }
    }

    static func request(port: Int, rpc: String, body: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(service)\(rpc)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        req.httpBody = body.data(using: .utf8)
        return req
    }

    // MARK: - Fetch

    /// The quota summary from the first server and port that answer, plus the plan name when the
    /// status call answers too. `host` is the backend the caller would rather match.
    func fetch(preferring host: String? = nil) async throws -> Result {
        let processList = processList, listeningPorts = listeningPorts
        let servers = try await Task.detached(priority: .utility) { Self.servers(in: try processList()) }.value
        guard !servers.isEmpty else { throw AntigravityLocalProbeError.notRunning }
        var lastFailure = "no listening port"
        for server in Self.ordered(servers, preferring: host) {
            let ports = try await Task.detached(priority: .utility) { Self.ports(in: try listeningPorts(server.pid)) }.value
            for port in ports {
                do {
                    let envelope = try await call(Self.quotaRPC, body: Self.quotaBody, port: port,
                                                  token: server.csrfToken, as: QuotaEnvelope.self)
                    guard let summary = envelope.response, !(summary.groups ?? []).isEmpty else {
                        throw AntigravityLocalProbeError.decoding("no quota groups")
                    }
                    // Best effort: the badge keeps its last name when this one fails.
                    let status = try? await call(Self.statusRPC, body: Self.statusBody, port: port,
                                                 token: server.csrfToken, as: StatusEnvelope.self)
                    return Result(summary: summary, tier: status?.tier, endpoint: server.endpoint, pid: server.pid, port: port)
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    lastFailure = "pid \(server.pid) port \(port): \(msg)"
                }
            }
        }
        throw AntigravityLocalProbeError.unreachable(lastFailure)
    }

    private func call<T: Decodable>(_ rpc: String, body: String, port: Int, token: String, as type: T.Type) async throws -> T {
        let resp = try await http.send(Self.request(port: port, rpc: rpc, body: body, token: token))
        guard resp.status == 200 else { throw AntigravityLocalProbeError.rejected(resp.status) }
        do { return try UsageClient.decoder.decode(T.self, from: resp.body) }
        catch { throw AntigravityLocalProbeError.decoding(String(describing: error)) }
    }

    /// `RetrieveUserQuotaSummary` wraps the backend's payload in `response`.
    private struct QuotaEnvelope: Decodable {
        var response: AntigravityQuotaSummary?
    }

    /// `GetUserStatus`: `userTier.name` is the same "Google AI Pro" that `loadCodeAssist` reports
    /// as the paid tier; `planStatus.planInfo.planName` ("Pro") is the fallback.
    private struct StatusEnvelope: Decodable {
        struct UserStatus: Decodable {
            struct Tier: Decodable { var name: String? }
            struct PlanStatus: Decodable {
                struct PlanInfo: Decodable { var planName: String? }
                var planInfo: PlanInfo?
            }
            var userTier: Tier?
            var planStatus: PlanStatus?
        }
        var userStatus: UserStatus?

        var tier: String? {
            let tier = userStatus?.userTier?.name ?? userStatus?.planStatus?.planInfo?.planName
            return tier.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

// MARK: - Localhost TLS

/// URLSession client for the language server: accepts its self-signed certificate, and only when
/// the peer is 127.0.0.1; any other host gets the system's normal verification.
final class LocalhostHTTPClient: HTTPClient, @unchecked Sendable {
    private final class Trust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.host == "127.0.0.1",
                  let trust = challenge.protectionSpace.serverTrust else {
                return completionHandler(.performDefaultHandling, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AntigravityLocalProbe.timeout
        session = URLSession(configuration: config, delegate: Trust(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await session.data(for: request)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

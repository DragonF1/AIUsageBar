import Foundation

enum RefreshError: LocalizedError, Equatable {
    case noRefreshToken
    case disabled
    case throttled
    case cliOwnsRefresh
    case rejected(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noRefreshToken: return "No refresh token stored. Run `claude` once to sign in again."
        case .disabled:
            return "Claude Code's token has expired. Run `claude` to refresh it, or set {\"claude\": {\"refresh\": true}} in ~/.config/aiusagebar/config.json to let this app refresh it."
        case .throttled: return "Refresh attempted less than a minute ago."
        case .cliOwnsRefresh: return "A `claude` session is running; waiting for it to refresh the token."
        case .rejected(let code, let body): return "Token refresh rejected (HTTP \(code)): \(body.prefix(120))"
        case .malformedResponse: return "Token refresh returned an unexpected response."
        }
    }
}

/// Runs Claude Code's own refresh-token flow and writes the result back so
/// the CLI picks it up. Refresh tokens rotate and are single-use, so every
/// guard here exists to avoid racing a live `claude` process. Off unless
/// `config.json` opts in: by default an expired token is only reported, and
/// the next poll picks up whatever Claude Code has refreshed since.
struct OAuthRefresher {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]
    /// Never hit the token endpoint more often than this.
    static let minInterval: TimeInterval = 60
    /// If the CLI is running and the token only just expired, let the CLI do it.
    static let cliGrace: TimeInterval = 3 * 60

    var http: HTTPClient = URLSessionHTTPClient()
    var store = CredentialStore()
    var enabled: Bool = AppConfig.loadSettings().refreshesClaudeToken
    var isCLIRunning: () -> Bool = { Shell.isRunning(processNamed: "claude") }
    var now: () -> Date = Date.init
    var lastAttempt: () -> Date? = { RefreshStamp.read() }
    var recordAttempt: (Date) -> Void = { RefreshStamp.write($0) }

    /// Returns fresh credentials, or the current ones if somebody else already refreshed.
    func refreshIfNeeded(force: Bool) async throws -> StoredCredentials {
        // Guard 1: re-read right before deciding; the CLI may have refreshed already.
        let current = try store.read()
        if !force && !current.oauth.isExpired(now: now()) { return current }

        guard enabled else { throw RefreshError.disabled }
        guard let refreshToken = current.oauth.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.noRefreshToken
        }
        // Guard 2: rate guard.
        if let last = lastAttempt(), now().timeIntervalSince(last) < Self.minInterval {
            throw RefreshError.throttled
        }
        // Guard 3: freshly expired + CLI alive = CLI's job.
        if isCLIRunning(), current.oauth.expiredFor(now: now()) < Self.cliGrace {
            throw RefreshError.cliOwnsRefresh
        }
        recordAttempt(now())

        let payload = try await exchange(refreshToken: refreshToken)

        // Guard 4: if the stored refresh token changed while we were talking to the
        // endpoint, someone else won; keep theirs.
        if let latest = try? store.read(), latest.oauth.refreshToken != refreshToken {
            return latest
        }
        let updated = current.merging(accessToken: payload.accessToken,
                                      refreshToken: payload.refreshToken,
                                      expiresIn: payload.expiresIn,
                                      now: now())
        try store.write(updated)
        return updated
    }

    struct TokenPayload: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func exchange(refreshToken: String) async throws -> TokenPayload {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        var lastError: Error = RefreshError.malformedResponse
        for url in Self.tokenURLs {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let resp = try await http.send(req)
                if resp.status == 404 { lastError = RefreshError.rejected(404, "not found"); continue }
                guard resp.status == 200 else {
                    throw RefreshError.rejected(resp.status, String(decoding: resp.body, as: UTF8.self))
                }
                guard let payload = try? JSONDecoder().decode(TokenPayload.self, from: resp.body),
                      !payload.accessToken.isEmpty else {
                    throw RefreshError.malformedResponse
                }
                return payload
            } catch let e as RefreshError {
                // 4xx other than 404 is final: do not retry with the same single-use token.
                if case .rejected(let code, _) = e, code != 404 { throw e }
                lastError = e
            } catch {
                lastError = error   // network error, try the fallback host
            }
        }
        throw lastError
    }
}

/// Timestamp of the last refresh attempt, kept on disk so relaunches stay throttled too.
enum RefreshStamp {
    static var url: URL { AppPaths.supportDirectory.appendingPathComponent("refresh.stamp") }

    static func read() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    static func write(_ date: Date) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

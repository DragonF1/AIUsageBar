import Foundation

enum AntigravityAuthError: LocalizedError, Equatable {
    case loginExpired
    case noRefreshClient
    case throttled
    case http(Int, String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .loginExpired: return "Antigravity login expired. Sign in again in Antigravity."
        case .noRefreshClient:
            return "Antigravity's token has expired. Open Antigravity so it refreshes the token, or add its OAuth client in Settings, under Antigravity, to let this app refresh it."
        case .throttled: return "Antigravity token refresh throttled; try again in a minute."
        case let .http(status, body): return "Antigravity token refresh failed (HTTP \(status)): \(body)"
        case .malformed: return "Antigravity token refresh returned an unexpected payload."
        }
    }
}

/// Produces a usable Antigravity access token without ever touching Antigravity's own
/// credential file. Order: this app's cached token, then the app's file token if still
/// valid, then a refresh against Google's token endpoint using the refresh token. The refresh
/// needs the OAuth client Antigravity signs in with, which this app does not ship: it comes from
/// the Keychain item saved in Settings, or else `~/.config/aiusagebar/antigravity-client.json`
/// (see `AntigravityClientStore`). Without either an expired token is reported, and the next poll
/// picks up whatever Antigravity itself has refreshed. The token file is the one set in Settings,
/// or Antigravity's default.
struct AntigravityAuth {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let minInterval: TimeInterval = 60

    var http: HTTPClient = URLSessionHTTPClient()
    /// Asked only when a refresh is due, so a client saved in Settings applies to the next one.
    var clientProvider: () -> AppConfig.OAuthClient? = { AntigravityClientStore.live.resolve()?.client }
    /// Antigravity's token file; nil means the one Settings names, or the default.
    var credentialFile: URL?
    var cacheFile: URL = AppPaths.supportDirectory.appendingPathComponent("antigravity-token.json")
    var lastAttempt: () -> Date? = { Self.stampDate() }
    var recordAttempt: (Date) -> Void = { Self.writeStamp($0) }
    var now: () -> Date = Date.init

    struct Cached: Codable {
        var accessToken: String
        var expiresAt: Date
    }

    func accessToken(force: Bool = false) async throws -> String {
        let now = now()
        if !force, let cached = loadCache(), cached.expiresAt.timeIntervalSince(now) > 60 {
            return cached.accessToken
        }
        let file = try AntigravityToken.read(from: credentialFile ?? AntigravityToken.effectiveFile())
        if !force, !file.isExpired(now: now) {
            return file.accessToken
        }
        guard let refreshToken = file.refreshToken, !refreshToken.isEmpty else {
            throw AntigravityAuthError.loginExpired
        }
        guard let client = clientProvider() else { throw AntigravityAuthError.noRefreshClient }
        if let last = lastAttempt(), now.timeIntervalSince(last) < Self.minInterval {
            // A refresh just happened; the file token is our best remaining option.
            if !file.isExpired(now: now) { return file.accessToken }
            throw AntigravityAuthError.throttled
        }
        recordAttempt(now)
        let fresh = try await exchange(refreshToken: refreshToken, client: client, now: now)
        saveCache(fresh)
        return fresh.accessToken
    }

    private func exchange(refreshToken: String, client: AppConfig.OAuthClient, now: Date) async throws -> Cached {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
        ])
        let response = try await http.send(request)
        let body = String(decoding: response.body, as: UTF8.self)
        guard response.status == 200 else {
            if body.contains("invalid_grant") { throw AntigravityAuthError.loginExpired }
            throw AntigravityAuthError.http(response.status, String(body.prefix(200)))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty else {
            throw AntigravityAuthError.malformed
        }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        return Cached(accessToken: token, expiresAt: now.addingTimeInterval(ttl))
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    static var stampURL: URL { AppPaths.supportDirectory.appendingPathComponent("antigravity-refresh.stamp") }

    static func stampDate() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stampURL.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    static func writeStamp(_ date: Date) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stampURL.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: stampURL.path)
    }

    private func loadCache() -> Cached? {
        guard let data = FileManager.default.contents(atPath: cacheFile.path) else { return nil }
        return try? UsageClient.decoder.decode(Cached.self, from: data)
    }

    private func saveCache(_ cached: Cached) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cached) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
    }
}

extension AntigravityAuth {
    /// A fixed client, or none: never consults the Keychain or `antigravity-client.json`.
    init(client: AppConfig.OAuthClient?) {
        self.init()
        clientProvider = { client }
    }
}

import Foundation

// MARK: - Wire model

/// `v1internal:retrieveUserQuotaSummary`: the payload behind Antigravity's own quota panel.
/// Two groups (Gemini models; Claude and GPT models), each with a weekly and a 5-hour bucket.
struct AntigravityQuotaSummary: Codable {
    struct Bucket: Codable {
        var bucketId: String?
        var displayName: String?
        var window: String?
        var resetTime: Date?
        var description: String?
        var remainingFraction: Double?
    }

    struct Group: Codable {
        var displayName: String?
        var description: String?
        var buckets: [Bucket]?
    }

    var groups: [Group]?
    var description: String?
}

extension AntigravityQuotaSummary {
    /// "gemini-weekly=0.4851 gemini-5h=1.0000 3p-weekly=0.6651 3p-5h=absent": raw wire values in wire
    /// order, so a log line can be held against Antigravity's own panel. "absent" is proto3's zero.
    var logLine: String {
        (groups ?? []).flatMap { $0.buckets ?? [] }.map { b in
            let value = b.remainingFraction.map { String(format: "%.4f", $0) } ?? "absent"
            return "\(b.bucketId ?? "?")=\(value)"
        }.joined(separator: " ")
    }
}

// MARK: - Derived view

struct AntigravityUsage: Codable, Equatable {
    struct Bucket: Codable, Equatable, Identifiable {
        var id: String
        /// "Weekly Limit Remaining" / "Five Hour Limit Remaining", as Antigravity labels them.
        var title: String
        /// "weekly" / "5h".
        var window: String?
        var percentRemaining: Double
        var resetsAt: Date?
        /// Google's own sentence ("You have used some of your weekly limit, it will fully refresh in 2 days, 17 hours.").
        var description: String?

        var percentUsed: Double { 100 - percentRemaining }

        /// Google reports an untouched 5-hour bucket as remainingFraction 1 with resetTime = query time + 5h,
        /// so its reset time is meaningless until something is used.
        var isIdle: Bool { window == "5h" && percentRemaining >= 100 }
    }

    struct Group: Codable, Equatable, Identifiable {
        var id: String { title }
        /// "Gemini Models" / "Claude and GPT models".
        var title: String
        /// "Models within this group: Gemini Flash, Gemini Pro".
        var description: String?
        var buckets: [Bucket]

        /// The bucket closest to its cap, as percent used; drives the menu bar and the ring color.
        var highestUsed: Double? { buckets.map(\.percentUsed).max() }
    }

    var groups: [Group]
    var tier: String?
    /// Backend the numbers came from; kept in the cache so a poll whose `loadCodeAssist` fails asks the same one.
    var host: String?
    /// True when the plan can spend Google One AI credits once a limit is out (`loadCodeAssist`
    /// lists them under `paidTier.availableCredits`). Nil until an account lookup has said either way.
    /// No endpoint reports the balance, so the row it feeds stays an empty bar.
    var aiCredits: Bool?

    init(summary: AntigravityQuotaSummary, tier: String? = nil, host: String? = nil, aiCredits: Bool? = nil) {
        groups = (summary.groups ?? []).enumerated().compactMap { index, g in
            let buckets = (g.buckets ?? []).enumerated().map { bIndex, b -> Bucket in
                // proto3 JSON omits zero-valued fields: an exhausted bucket arrives without remainingFraction.
                let fraction = b.remainingFraction ?? 0
                let remaining = (min(max(fraction, 0), 1) * 1000).rounded() / 10
                return Bucket(id: b.bucketId ?? "\(index)-\(bIndex)",
                              title: b.displayName ?? Self.windowTitle(b.window),
                              window: b.window,
                              percentRemaining: remaining,
                              resetsAt: b.resetTime,
                              description: b.description)
            }
            guard !buckets.isEmpty else { return nil }
            // 5-hour first, then weekly, matching the Claude tab's order.
            let ordered = buckets.sorted { Self.windowRank($0.window) < Self.windowRank($1.window) }
            return Group(title: g.displayName ?? "Group \(index + 1)", description: g.description, buckets: ordered)
        }
        self.tier = tier
        self.host = host
        self.aiCredits = aiCredits
    }

    private static func windowRank(_ window: String?) -> Int {
        switch window {
        case "5h": return 0
        case "weekly": return 1
        default: return 2
        }
    }

    private static func windowTitle(_ window: String?) -> String {
        switch window {
        case "weekly": return "Weekly Limit Remaining"
        case "5h": return "Five Hour Limit Remaining"
        default: return "Limit Remaining"
        }
    }

    /// The Gemini group is the one whose title mentions Gemini; the other one is everything else.
    var gemini: Group? { groups.first { $0.title.localizedCaseInsensitiveContains("gemini") } }
    var other: Group? { groups.first { !$0.title.localizedCaseInsensitiveContains("gemini") } }
}

// MARK: - Client

struct AntigravityClient {
    /// Antigravity picks its backend the same way (cloudCode.js in the IDE bundle): an account under
    /// GCP terms of service talks to cloudcode-pa, a consumer Google account to daily-cloudcode-pa.
    /// Quota is metered per host, so the panel's numbers only match when the app asks the same one.
    static let productionHost = "https://cloudcode-pa.googleapis.com"
    static let dailyHost = "https://daily-cloudcode-pa.googleapis.com"
    /// Antigravity asks the production host which backend to use before it knows the answer, so this one does too.
    static let accountURL = URL(string: productionHost + "/v1internal:loadCodeAssist")!
    static let userAgent = "antigravity/2.13.0 darwin/arm64"

    static func summaryURL(host: String) -> URL {
        URL(string: host + "/v1internal:retrieveUserQuotaSummary")!
    }

    /// The cache is the only other source of a host; anything else in there is ignored.
    static func isKnownHost(_ host: String) -> Bool {
        host == productionHost || host == dailyHost
    }

    /// What `loadCodeAssist` says about the signed-in account: the plan name for the header badge and
    /// which backend meters its quota.
    struct Account: Equatable {
        var tier: String?
        var usesGcpTos: Bool
        /// The paid tier lists `availableCredits` with `creditType` "GOOGLE_ONE_AI" when the plan
        /// may spend Google One AI credits; the free tier lists nothing.
        var aiCredits = false

        var host: String { usesGcpTos ? AntigravityClient.productionHost : AntigravityClient.dailyHost }
    }

    var http: HTTPClient = URLSessionHTTPClient()

    func fetch(accessToken: String, host: String) async throws -> AntigravityQuotaSummary {
        let resp = try await send(Self.summaryURL(host: host), accessToken: accessToken, body: "{}")
        do { return try UsageClient.decoder.decode(AntigravityQuotaSummary.self, from: resp.body) }
        catch { throw UsageError.decoding(String(describing: error)) }
    }

    /// Plan name ("Google AI Pro") and backend choice. Antigravity reads `paidTier.usesGcpTos`, absent
    /// for consumer accounts, so absent means the daily host.
    func fetchAccount(accessToken: String) async throws -> Account {
        let body = #"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
        let resp = try await send(Self.accountURL, accessToken: accessToken, body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw UsageError.decoding("loadCodeAssist: not a JSON object")
        }
        let paid = obj["paidTier"] as? [String: Any]
        let current = (obj["currentTier"] as? [String: Any])?["name"] as? String
        let credits = (paid?["availableCredits"] as? [[String: Any]]) ?? []
        return Account(tier: (paid?["name"] as? String) ?? current,
                       usesGcpTos: (paid?["usesGcpTos"] as? Bool) ?? false,
                       aiCredits: credits.contains { ($0["creditType"] as? String) == "GOOGLE_ONE_AI" })
    }

    private func send(_ url: URL, accessToken: String, body: String) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body.data(using: .utf8)
        let resp = try await http.send(req)
        switch resp.status {
        case 200:
            return resp
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retry = resp.header("Retry-After").flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
                ?? UsageClient.defaultBackoff
            throw UsageError.rateLimited(retryAfter: max(60, retry))
        default:
            throw UsageError.http(resp.status)
        }
    }
}

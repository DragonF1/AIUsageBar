import Foundation

/// Anthropic's public status page (Statuspage.io), no auth.
struct StatusSummary: Codable, Equatable {
    var status: Overall?
    var components: [Component]?
    var incidents: [Incident]?
    var scheduledMaintenances: [Incident]?

    enum CodingKeys: String, CodingKey {
        case status, components, incidents
        case scheduledMaintenances = "scheduled_maintenances"
    }

    struct Overall: Codable, Equatable {
        /// none | minor | major | critical | maintenance
        var indicator: String?
        var description: String?
    }

    struct Component: Codable, Equatable, Identifiable {
        var id: String
        var name: String?
        /// operational | degraded_performance | partial_outage | major_outage | under_maintenance
        var status: String?
        var position: Int?
        var group: Bool?
        var groupId: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status, position, group
            case groupId = "group_id"
        }

        var statusLabel: String {
            switch status {
            case "operational": return "Operational"
            case "degraded_performance": return "Degraded"
            case "partial_outage": return "Partial outage"
            case "major_outage": return "Major outage"
            case "under_maintenance": return "Maintenance"
            default: return (status ?? "Unknown").replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    struct Incident: Codable, Equatable, Identifiable {
        var id: String
        var name: String?
        /// none | minor | major | critical
        var impact: String?
        /// investigating | identified | monitoring | resolved
        var status: String?
        var shortlink: String?
        var updatedAt: Date?
        var components: [Component]?
        var incidentUpdates: [Update]?

        enum CodingKeys: String, CodingKey {
            case id, name, impact, status, shortlink, components
            case updatedAt = "updated_at"
            case incidentUpdates = "incident_updates"
        }

        struct Update: Codable, Equatable {
            var status: String?
            var body: String?
            var updatedAt: Date?
            enum CodingKeys: String, CodingKey { case status, body; case updatedAt = "updated_at" }
        }

        var latestBody: String? { incidentUpdates?.first?.body }
        var affected: String { (components ?? []).compactMap(\.name).joined(separator: ", ") }
    }

    var isAllClear: Bool { (status?.indicator ?? "none") == "none" && (incidents ?? []).isEmpty }

    /// Every product row on status.claude.com, in page order (group headers excluded).
    var productComponents: [Component] {
        (components ?? []).filter { $0.group != true }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }

    var activeIncidents: [Incident] {
        (incidents ?? []) + (scheduledMaintenances ?? [])
    }

    var affectedNames: String {
        let names = (components ?? []).filter { $0.status != "operational" }.compactMap(\.name)
        return names.joined(separator: ", ")
    }

    /// "1 active incident", "2 active incidents, 1 scheduled maintenance"; nil when there is nothing.
    var incidentCount: String? {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if let n = incidents?.count, n > 0 { parts.append(plural(n, "active incident")) }
        if let n = scheduledMaintenances?.count, n > 0 { parts.append(plural(n, "scheduled maintenance")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A public status page the popover can summarise: Anthropic's for the Claude tab, Google
/// Cloud's for Antigravity. Each feed folds its own format into a `StatusSummary`.
protocol StatusFeed: Sendable {
    /// The page the card's "Open status page" link opens.
    var pageURL: URL { get }
    func fetch() async throws -> StatusSummary
}

struct StatusClient: StatusFeed {
    static let summaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!
    static let pageURL = URL(string: "https://status.claude.com")!

    var http: HTTPClient = URLSessionHTTPClient()
    var pageURL: URL { Self.pageURL }
    /// The summary page sends an ETag, so every poll after the first is conditional.
    var cache = FeedCache<StatusSummary>()

    func fetch() async throws -> StatusSummary {
        var req = URLRequest(url: Self.summaryURL)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await cache.fetch(req, http: http) { body in
            try UsageClient.decoder.decode(StatusSummary.self, from: body)
        }
    }
}

/// Remembers a feed's last decoded body together with the validators its server sent (ETag,
/// Last-Modified), so every later request is conditional and a 304 hands the remembered value
/// back with nothing to download or decode. A class so the copies of a client struct share it.
final class FeedCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var etag: String?
    private var lastModified: String?
    private var value: Value?

    init() {}

    /// The value the last 200 decoded to, nil before the first.
    var remembered: Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Sends `request` with the validators of the last 200 added, decodes a 200 and remembers
    /// it, returns the remembered value on a 304, and throws `UsageError.http` otherwise (a 304
    /// with nothing remembered included, which a server should never send).
    func fetch(_ request: URLRequest, http: HTTPClient, decode: (Data) throws -> Value) async throws -> Value {
        var req = request
        prepare(&req)
        let resp = try await http.send(req)
        switch resp.status {
        case 200:
            let value: Value
            do { value = try decode(resp.body) }
            catch { throw UsageError.decoding(String(describing: error)) }
            remember(value, from: resp)
            return value
        case 304:
            guard let value = remembered else { throw UsageError.http(304) }
            return value
        default:
            throw UsageError.http(resp.status)
        }
    }

    /// Adds If-None-Match / If-Modified-Since when the last 200 gave the matching validator.
    func prepare(_ request: inout URLRequest) {
        lock.lock(); defer { lock.unlock() }
        guard value != nil else { return }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
    }

    private func remember(_ value: Value, from response: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
        etag = response.header("ETag")
        lastModified = response.header("Last-Modified")
    }
}

@MainActor @Observable
final class StatusStore {
    private(set) var summary: StatusSummary?
    private(set) var checkedAt: Date?
    private(set) var failed = false

    var client: any StatusFeed
    /// The defaults key remembering whether the card's details are folded away.
    let hiddenKey: String
    private var timer: Timer?
    private var inFlight = false

    init(client: any StatusFeed = StatusClient(), hiddenKey: String = "statusHidden") {
        self.client = client
        self.hiddenKey = hiddenKey
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refreshIfStale() {
        let age = checkedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > UsageStore.popoverRefetchAge { Task { await refresh() } }
    }

    func refresh() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        do {
            summary = try await client.fetch()
            checkedAt = Date()
            failed = false
        } catch {
            failed = true
        }
    }
}

enum RelativeText {
    /// "just now", "3 mins ago", "1 day ago"
    static func ago(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = max(0, now.timeIntervalSince(date))
        let m = Int(s / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min\(m == 1 ? "" : "s") ago" }
        let h = m / 60
        if h < 24 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = h / 24
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}

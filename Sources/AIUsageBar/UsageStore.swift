import Foundation
import Observation

@MainActor @Observable
final class UsageStore {
    enum State: Equatable {
        case loading
        case ok
        case stale(String)
        case error(String)
    }

    private(set) var usage: UsageResponse?
    private(set) var lastUpdated: Date?
    private(set) var state: State = .loading
    private(set) var subscriptionType: String?

    static let pollInterval: TimeInterval = 5 * 60
    static let popoverRefetchAge: TimeInterval = 60

    var client = UsageClient()
    var refresher = OAuthRefresher()
    var store = CredentialStore()
    /// Told about every successful poll, for the pace lines and the notifications.
    var monitor: QuotaMonitor?

    private var timer: Timer?
    private var backoffUntil: Date?
    private var inFlight = false
    /// nil disables the cache; tests and the screenshot renderer pass nil so they never touch the app's real file.
    private let cacheURL: URL?

    init(cacheURL: URL? = AppPaths.supportDirectory.appendingPathComponent("usage.json")) {
        self.cacheURL = cacheURL
        loadCache()
    }

    // MARK: - scheduling

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        Task { await refresh(reason: "launch") }
    }

    func refreshIfStale() {
        let age = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > Self.popoverRefetchAge { Task { await refresh(reason: "popover") } }
    }

    func refresh(reason: String) async {
        if inFlight { return }
        if let until = backoffUntil, until > Date() { return }
        inFlight = true
        defer { inFlight = false }

        do {
            var creds = try store.read()
            subscriptionType = creds.oauth.subscriptionType
            if creds.oauth.isExpired() {
                creds = try await refresher.refreshIfNeeded(force: false)
            }
            do {
                try await apply(try await client.fetch(accessToken: creds.oauth.accessToken))
            } catch UsageError.unauthorized {
                // Token rejected despite expiresAt: refresh once and retry.
                let fresh = try await refresher.refreshIfNeeded(force: true)
                try await apply(try await client.fetch(accessToken: fresh.oauth.accessToken))
            }
        } catch UsageError.rateLimited(let retryAfter) {
            backoffUntil = Date().addingTimeInterval(retryAfter)
            state = usage == nil ? .error(UsageError.rateLimited(retryAfter: retryAfter).localizedDescription)
                                 : .stale("Rate limited, retrying at \(Self.timeFormatter.string(from: backoffUntil!))")
        } catch let e as RefreshError {
            state = usage == nil ? .error(e.localizedDescription) : .stale(e.localizedDescription)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = usage == nil ? .error(msg) : .stale(msg)
        }
    }

    private func apply(_ response: UsageResponse) async throws {
        adopt(response, plan: subscriptionType, at: Date())
    }

    /// Takes a response as if a poll had just returned it: the rows, the plan badge, the
    /// "Updated" time and the pace tracker all follow. The screenshot renderer feeds fixtures this way.
    func adopt(_ response: UsageResponse, plan: String?, at date: Date) {
        usage = response
        subscriptionType = plan
        lastUpdated = date
        state = .ok
        backoffUntil = nil
        saveCache()
        monitor?.observe(response.readings(extraUsage: Preferences.extraUsage), now: date)
    }

    // MARK: - derived

    var sessionPercent: Double? { usage?.sessionPercent }
    var weeklyPercent: Double? { usage?.weeklyPercent }

    var isStale: Bool {
        if case .ok = state { return false }
        return true
    }

    // MARK: - cache

    private struct Cache: Codable {
        var usage: UsageResponse
        var lastUpdated: Date
        var subscriptionType: String?
    }
    private func loadCache() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? UsageClient.decoder.decode(Cache.self, from: data) else { return }
        usage = cache.usage
        lastUpdated = cache.lastUpdated
        subscriptionType = cache.subscriptionType
        state = .stale("Cached")
    }

    private func saveCache() {
        guard let cacheURL, let usage, let lastUpdated else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Cache(usage: usage, lastUpdated: lastUpdated, subscriptionType: subscriptionType)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// Green / yellow / red thresholds, shared by the menu bar title and the rows.
enum UsageColor {
    enum Level { case low, medium, high }

    static func level(for percent: Double) -> Level {
        switch percent {
        case ..<50: return .low
        case ..<80: return .medium
        default: return .high
        }
    }

    /// Menu bar icon tint. `red` is the 5-hour window's high level; `lightRed` and
    /// `darkRed` only ever come from the weekly window.
    enum Icon: Equatable { case green, yellow, red, lightRed, darkRed }

    /// `auto`: the icon follows the 5-hour window (green / yellow / red at the row
    /// thresholds), except that a weekly window at 85% or more takes over so a
    /// nearly spent week is never hidden behind a fresh session: yellow from 85,
    /// light red from 95, dark red at 100. `session` and `weekly` follow that one
    /// window alone at the row thresholds (weekly still goes dark red at 100).
    /// Nil when there is nothing to colour.
    static func icon(session: Double?, weekly: Double?, metric: MenuBarMetric = .auto) -> Icon? {
        switch metric {
        case .auto:
            if let weekly, weekly >= 85 {
                if weekly >= 100 { return .darkRed }
                if weekly >= 95 { return .lightRed }
                return .yellow
            }
            return session.map(rowIcon)
        case .session:
            return session.map(rowIcon)
        case .weekly:
            guard let weekly else { return nil }
            return weekly >= 100 ? .darkRed : rowIcon(weekly)
        }
    }

    private static func rowIcon(_ percent: Double) -> Icon {
        switch level(for: percent) {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}

enum ResetText {
    enum Window { case fiveHour, other }

    /// Weekly rows: "Resets on Friday Sep 14th at 3:45 PM". 5h rows: "Resets at 3:45 PM (2h 10m left)".
    /// "Resetting" once the window has passed.
    static func describe(_ date: Date?, window: Window, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "Resetting" }
        let time = timeFormatter.string(from: date)
        switch window {
        case .fiveHour:
            return "Resets at \(time) (\(remaining(interval)) left)"
        case .other:
            let weekday = weekdayFormatter.string(from: date)
            let month = monthFormatter.string(from: date)
            let day = ordinal(calendar.component(.day, from: date))
            return "Resets on \(weekday) \(month) \(day) at \(time)"
        }
    }

    /// A time on its own for the pace text and notifications: "2:20 PM" for a 5-hour
    /// window, "Thursday 2:20 PM" for a weekly one.
    static func clock(_ date: Date, window: Window) -> String {
        let time = timeFormatter.string(from: date)
        switch window {
        case .fiveHour: return time
        case .other: return "\(weekdayFormatter.string(from: date)) \(time)"
        }
    }

    /// "2h 10m", "45m", "1h". Minutes round up so a future reset never reads 0m.
    static func remaining(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let weekdayFormatter = formatter("EEEE")
    private static let monthFormatter = formatter("MMM")
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}


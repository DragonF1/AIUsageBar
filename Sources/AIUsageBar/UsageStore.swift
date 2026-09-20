import AppKit
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

/// Green / yellow / red / dark red thresholds, shared by the menu bar icon and the rows. The
/// cutoffs and colours are user-customisable (see `ColorScale`); callers that do not pass one
/// get `.default`, which reproduces the original fixed 75/85/95 scale.
enum UsageColor {
    enum Level: CaseIterable {
        case low, medium, high, critical

        /// The label a settings row shows next to this band.
        var title: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .critical: return "Critical"
            }
        }
    }

    static func level(for percent: Double, scale: ColorScale = .default) -> Level {
        scale.level(for: percent)
    }

    /// Menu bar icon tint, one colour per level.
    enum Icon: Equatable { case green, yellow, red, darkRed }

    // Red is the system red; dark red sits well below it so the two stay tellable apart
    // in the menu bar and on the bars alike.
    static let darkRed = NSColor(srgbRed: 0.62, green: 0.05, blue: 0.09, alpha: 1)

    /// `auto`: the icon follows the 5-hour window, except that a weekly window at or past
    /// `scale`'s high cutoff takes over so a nearly spent week is never hidden behind a fresh
    /// session. `session` and `weekly` follow that one window alone. Nil when there is nothing
    /// to colour.
    static func icon(session: Double?, weekly: Double?, metric: MenuBarMetric = .auto, scale: ColorScale = .default) -> Icon? {
        switch metric {
        case .auto:
            if let weekly, weekly >= scale.highCutoff { return rowIcon(weekly, scale: scale) }
            return session.map { rowIcon($0, scale: scale) }
        case .session:
            return session.map { rowIcon($0, scale: scale) }
        case .weekly:
            return weekly.map { rowIcon($0, scale: scale) }
        }
    }

    static func rowIcon(_ percent: Double, scale: ColorScale = .default) -> Icon {
        switch level(for: percent, scale: scale) {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        case .critical: return .darkRed
        }
    }
}

/// Percent text shared by the menu bar and the rows: plain for the icon's title, a labelled
/// form for a row's number. Both read "used" by default and flip to "remaining" for the
/// battery-style "Show remaining instead of used" switch.
enum PercentText {
    /// "34%", or "–" when there is nothing to show.
    static func bare(_ v: Double?, remaining: Bool) -> String {
        guard let v else { return "–" }
        return "\(whole(v, remaining: remaining))%"
    }

    /// "34%" used, "66% left" remaining, "–" when there is nothing to show.
    static func labelled(_ v: Double?, remaining: Bool) -> String {
        guard let v else { return "–" }
        let value = whole(v, remaining: remaining)
        return remaining ? "\(value)% left" : "\(value)%"
    }

    /// Used reads as reported, past 100 included (extra usage can run over its limit);
    /// remaining floors at 0 so the same account says "0% left", never "-5% left".
    private static func whole(_ v: Double, remaining: Bool) -> Int {
        Int((remaining ? max(0, 100 - v) : v).rounded())
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

    /// "3d 4h", "5d", "2h 10m", "45m", "1h". Minutes round up so a future reset never reads 0m.
    static func remaining(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        if h >= 24 {
            let d = h / 24, hh = h % 24
            return hh == 0 ? "\(d)d" : "\(d)d \(hh)h"
        }
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


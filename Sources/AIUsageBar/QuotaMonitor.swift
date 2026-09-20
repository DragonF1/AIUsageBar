import Foundation
import Observation

// MARK: - Readings

/// One usage window as a store reports it after a successful poll. The id is stable from poll
/// to poll and unique across products, so the monitor can follow a window through its cycles.
struct QuotaReading: Equatable {
    enum Window: String, Codable {
        case fiveHour
        case weekly
        /// Extra-usage credits: the endpoint gives no reset time, so there is never a pace.
        case monthly
    }

    var id: String
    /// "Claude Code" / "Antigravity": the first words of a notification.
    var product: String
    /// The row title: "All models 5h", "Gemini weekly".
    var name: String
    var window: Window
    var percent: Double
    var resetsAt: Date?

    /// Nil for a limit without a percentage; there is nothing to follow then.
    static func claude(_ limit: UsageResponse.Limit) -> QuotaReading? {
        guard let percent = limit.percent else { return nil }
        return QuotaReading(id: "claude|\(limit.id)", product: "Claude Code", name: limit.title,
                            window: limit.kind == "session" ? .fiveHour : .weekly,
                            percent: percent, resetsAt: limit.resetsAt)
    }

    /// Nil when the account has no extra usage, or the endpoint gave no figure to follow.
    static func extraUsage(_ extra: UsageResponse.ExtraUsage) -> QuotaReading? {
        guard extra.isActive, let percent = extra.percent else { return nil }
        return QuotaReading(id: "claude|extra_usage", product: "Claude Code", name: "Extra usage",
                            window: .monthly, percent: percent, resetsAt: nil)
    }

    static func antigravity(group: AntigravityUsage.Group, bucket: AntigravityUsage.Bucket) -> QuotaReading {
        QuotaReading(id: "antigravity|\(group.id)|\(bucket.id)", product: "Antigravity",
                     name: bucket.rowTitle(in: group),
                     window: bucket.window == "5h" ? .fiveHour : .weekly,
                     percent: bucket.percentUsed, resetsAt: bucket.resetsAt)
    }
}

extension UsageResponse {
    var readings: [QuotaReading] { displayLimits.compactMap(QuotaReading.claude) }

    /// The rows plus the extra-usage credits when the switch is on and the account has them.
    func readings(extraUsage: Bool) -> [QuotaReading] {
        var all = readings
        if extraUsage, let extra = self.extraUsage, let reading = QuotaReading.extraUsage(extra) {
            all.append(reading)
        }
        return all
    }
}

extension AntigravityUsage {
    var readings: [QuotaReading] {
        groups.flatMap { group in group.buckets.map { QuotaReading.antigravity(group: group, bucket: $0) } }
    }
}

// MARK: - Pace

enum PaceForecast: Equatable {
    /// The window hits 100% before it resets, at about this time.
    case runsOut(at: Date)
    /// Where the window ends up when it resets, at the current rate.
    case atReset(percent: Double)
}

/// Percent-used samples per window for its current reset cycle, and the straight-line forecast
/// they support: the rate over the recent samples, carried forward to the reset.
struct PaceTracker: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var at: Date
        var percent: Double
    }

    struct Series: Codable, Equatable {
        var window: QuotaReading.Window
        var resetsAt: Date?
        var samples: [Sample]
    }

    private(set) var series: [String: Series] = [:]

    /// Samples older than this no longer describe the current pace.
    static func lookback(_ window: QuotaReading.Window) -> TimeInterval {
        switch window {
        case .fiveHour: return 60 * 60
        case .weekly, .monthly: return 24 * 60 * 60
        }
    }

    /// The oldest and newest sample must be this far apart before a rate means anything.
    static func minimumSpan(_ window: QuotaReading.Window) -> TimeInterval {
        switch window {
        case .fiveHour: return 10 * 60
        case .weekly, .monthly: return 2 * 60 * 60
        }
    }

    /// Usage only grows inside a cycle; a drop this large means the window reset.
    static let resetDrop = 5.0
    /// A day of 5-minute polls, with room to spare.
    static let maxSamples = 320

    /// Adds the reading to its series. True when it began a new cycle: the window reset since
    /// the previous sample, which the drop in percent or the moved reset time gives away.
    @discardableResult
    mutating func record(_ reading: QuotaReading, at now: Date) -> Bool {
        let sample = Sample(at: now, percent: reading.percent)
        guard var current = series[reading.id], !current.samples.isEmpty else {
            series[reading.id] = Series(window: reading.window, resetsAt: reading.resetsAt, samples: [sample])
            return false
        }
        if Self.isNewCycle(previous: current, reading: reading) {
            series[reading.id] = Series(window: reading.window, resetsAt: reading.resetsAt, samples: [sample])
            return true
        }
        current.window = reading.window
        current.resetsAt = reading.resetsAt ?? current.resetsAt
        current.samples.append(sample)
        if current.samples.count > Self.maxSamples {
            current.samples.removeFirst(current.samples.count - Self.maxSamples)
        }
        series[reading.id] = current
        return false
    }

    static func isNewCycle(previous: Series, reading: QuotaReading) -> Bool {
        if let last = previous.samples.last, reading.percent < last.percent - resetDrop { return true }
        if let old = previous.resetsAt, let new = reading.resetsAt, abs(new.timeIntervalSince(old)) > 60 { return true }
        return false
    }

    /// Nil until the series spans the minimum, when the rate is zero or falling, once the
    /// window is already used up, and when the reset has passed.
    func forecast(for id: String, now: Date) -> PaceForecast? {
        guard let series = series[id], let resetsAt = series.resetsAt, resetsAt > now,
              let last = series.samples.last, last.percent < 100 else { return nil }
        let cutoff = now.addingTimeInterval(-Self.lookback(series.window))
        guard let first = series.samples.first(where: { $0.at >= cutoff }) else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan(series.window) else { return nil }
        let rate = (last.percent - first.percent) / span   // percent per second
        guard rate > 0 else { return nil }
        let projected = last.percent + rate * resetsAt.timeIntervalSince(last.at)
        guard projected >= 100 else { return .atReset(percent: projected) }
        let out = last.at.addingTimeInterval((100 - last.percent) / rate)
        // A pace that already ran out but a percent still under 100 means the pace changed;
        // the next poll sorts it out.
        return out > now ? .runsOut(at: out) : nil
    }
}

/// The forecast worded for a row's caption, orange when the window runs out before it resets.
struct PaceLine: Equatable {
    var text: String
    var urgent: Bool
    /// Where the pace lands: 100 for a window that runs out before it resets, the forecast
    /// percent otherwise. Feeds the row's ghost tick, a preview of where the bar is headed.
    var projectedPercent: Double

    init(_ forecast: PaceForecast, window: QuotaReading.Window) {
        switch forecast {
        case .runsOut(let at):
            text = "At this pace: out at \(ResetText.clock(at, window: window == .fiveHour ? .fiveHour : .other))"
            urgent = true
            projectedPercent = 100
        case .atReset(let percent):
            text = "At this pace: ~\(Int(percent.rounded()))% at reset"
            urgent = false
            projectedPercent = percent
        }
    }

    /// Where to draw the ghost tick against the bar's current fill: nil when the pace has not
    /// moved past `percent` (nothing to preview), else the projected percent clamped to the bar.
    func tickPercent(aheadOf percent: Double) -> Double? {
        guard projectedPercent > percent else { return nil }
        return min(100, max(0, projectedPercent))
    }
}

// MARK: - Notifications

struct QuotaNotification: Equatable {
    var id: String
    var title: String
    var body: String
}

protocol Notifier: AnyObject {
    func requestAuthorization()
    func post(_ notification: QuotaNotification)
}

// MARK: - Monitor

/// Follows every window both stores report: keeps the pace samples, and decides which polls
/// deserve a notification. One notification per window per poll at most, the most serious one:
/// used up, then a threshold crossed, then the pace running the window out before its reset.
/// Each fires once per cycle; a reset after any of them is announced too.
@MainActor @Observable
final class QuotaMonitor {
    nonisolated static let defaultThresholds: [Double] = [80, 95]

    struct AlertState: Codable, Equatable {
        var warned: [Double] = []
        var depleted = false
        var paceWarned = false

        var announced: Bool { depleted || paceWarned || !warned.isEmpty }
    }

    private(set) var pace = PaceTracker()
    private var alerts: [String: AlertState] = [:]
    let thresholds: [Double]
    var notifier: any Notifier
    /// Read at post time, so the menu switch applies without a restart. The state advances
    /// either way: switching notifications on never replays what was missed.
    var isEnabled: () -> Bool = { Preferences.notifications }
    /// nil disables the cache; tests pass nil so they never touch the app's real file.
    private let cacheURL: URL?

    init(notifier: any Notifier, thresholds: [Double] = QuotaMonitor.defaultThresholds,
         cacheURL: URL? = AppPaths.supportDirectory.appendingPathComponent("quota.json"))
    {
        self.notifier = notifier
        self.thresholds = thresholds.sorted()
        self.cacheURL = cacheURL
        load()
    }

    func observe(_ readings: [QuotaReading], now: Date = Date()) {
        for reading in readings { observe(reading, now: now) }
        save()
    }

    func forecast(for id: String, now: Date) -> PaceForecast? {
        pace.forecast(for: id, now: now)
    }

    func paceLine(for id: String, window: QuotaReading.Window, now: Date) -> PaceLine? {
        forecast(for: id, now: now).map { PaceLine($0, window: window) }
    }

    private func observe(_ r: QuotaReading, now: Date) {
        let reset = pace.record(r, at: now)
        var state = alerts[r.id] ?? AlertState()
        var posted = false
        if reset {
            let wasAnnounced = state.announced
            state = AlertState()
            if wasAnnounced {
                post(r, kind: "reset", title: "\(r.product): \(r.name) reset",
                     body: ["Now at \(Self.pct(r.percent))", Self.resetText(r, now: now)].compactMap { $0 }.joined(separator: ". "))
                posted = true
            }
        }
        if r.percent >= 100, !state.depleted {
            state.depleted = true
            state.warned = thresholds
            if !posted {
                post(r, kind: "depleted", title: "\(r.product): \(r.name) used up", body: Self.resetText(r, now: now) ?? "")
                posted = true
            }
        }
        let crossed = thresholds.filter { r.percent >= $0 && !state.warned.contains($0) }
        if let highest = crossed.last {
            state.warned.append(contentsOf: crossed)
            if !posted {
                post(r, kind: "at\(Int(highest))", title: "\(r.product): \(r.name) at \(Self.pct(r.percent))",
                     body: Self.resetText(r, now: now) ?? "")
                posted = true
            }
        }
        if !state.paceWarned, r.percent < 100, case .runsOut(let at)? = pace.forecast(for: r.id, now: now) {
            state.paceWarned = true
            if !posted {
                let window: ResetText.Window = r.window == .fiveHour ? .fiveHour : .other
                var body = "At this pace it is used up at \(ResetText.clock(at, window: window))"
                if let resetsAt = r.resetsAt { body += ", before the reset at \(ResetText.clock(resetsAt, window: window))" }
                post(r, kind: "pace", title: "\(r.product): \(r.name) running out", body: body + ".")
            }
        }
        alerts[r.id] = state
    }

    private func post(_ r: QuotaReading, kind: String, title: String, body: String) {
        guard isEnabled() else { return }
        notifier.post(QuotaNotification(id: "\(r.id)|\(kind)", title: title, body: body))
    }

    private static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    private static func resetText(_ r: QuotaReading, now: Date) -> String? {
        ResetText.describe(r.resetsAt, window: r.window == .fiveHour ? .fiveHour : .other, now: now)
    }

    // MARK: - cache

    private struct Cache: Codable {
        var version = 1
        var pace: PaceTracker
        var alerts: [String: AlertState]
    }

    private func load() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 else { return }
        pace = cache.pace
        alerts = cache.alerts
    }

    private func save() {
        guard let cacheURL, let data = try? JSONEncoder().encode(Cache(pace: pace, alerts: alerts)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

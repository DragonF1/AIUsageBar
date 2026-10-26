import Foundation
import Observation

/// Sibling of `UsageStore` for the cost rows on the Claude tab: same polling, but the data
/// comes from Claude Code's local transcripts and there is nothing to cache beyond the scanner's own file.
@MainActor @Observable
final class TokenStore: TokenLedger {
    var product: TokenProduct { .claudeCode }
    /// Deduplicated responses from the last `retention` seconds, oldest first.
    private(set) var records: [TokenRecord] = []
    private(set) var lastScanned: Date?
    private(set) var error: String?

    /// One day past the cost window's longest range (90 calendar days), so the oldest bar is
    /// complete however far into today the scan runs (and the week aligned to the API reset is
    /// always covered).
    nonisolated static let retention: TimeInterval = TimeInterval(CostRange.retentionDays) * 86400

    var scanner = TokenScanner()
    /// The Claude folder in use, asked at every refresh so a Settings change applies to the next one.
    var folder: () -> ClaudeFolder = { ClaudeFolder.current() }
    /// The `projects` root the scanner was last aimed at by `followFolder`.
    private var followedRoot = TokenScanner.defaultRoot

    private var timer: Timer?
    private var inFlight = false

    // MARK: - scheduling

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.statusPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        // The first scan streams every recent transcript once; keep it off the interactive lanes.
        Task(priority: .utility) { await refresh(reason: "launch") }
    }

    func refreshIfStale() {
        let age = lastScanned.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > UsageStore.popoverRefetchAge { Task { await refresh(reason: "popover") } }
    }

    func refresh(reason: String) async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        await followFolder()
        do {
            let scanned = try await scanner.scan(retainSince: Date().addingTimeInterval(-Self.retention))
            // A scan that read nothing returns the same buffer; compare before assigning so the
            // views observing `records` are not invalidated every poll.
            if scanned != records { records = scanned }
            lastScanned = Date()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Points the scanner (with the cache of that folder) at the Claude folder
    /// when the setting has moved since the last refresh.
    private func followFolder() async {
        let current = folder()
        guard current.projectsRoot != followedRoot else { return }
        followedRoot = current.projectsRoot
        // The old folder's cache may hold up to `saveInterval` of unsaved progress.
        await scanner.flush()
        scanner = TokenScanner(root: current.projectsRoot, cacheURL: current.tokenCacheURL)
    }

    /// Writes the scanner's pending cache changes (the app is quitting).
    func flush() async {
        await scanner.flush()
    }

    /// Takes a scan's worth of data as if the scanner had just produced it. The screenshot
    /// renderer feeds fixtures this way; nothing is read from disk.
    func adopt(records: [TokenRecord], at date: Date) {
        self.records = records.sorted { $0.timestamp < $1.timestamp }
        lastScanned = date
        error = nil
    }

    // MARK: - derived

    /// Rolling 30 calendar days ending today: local midnight `CostReport.dayCount - 1` days ago.
    static func costWindowStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1 - CostReport.dayCount, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
    }
}

// MARK: - Windows

enum TokenWindow {
    static let week: TimeInterval = 7 * 86400

    /// Local midnight.
    static func todayStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    /// The 7 days ending at the API's weekly reset when known (rolled forward by whole cycles
    /// if the cached reset has already passed), otherwise a rolling 7 days.
    static func weekStart(resetsAt: Date?, now: Date = Date()) -> (start: Date, aligned: Bool) {
        guard var reset = resetsAt else { return (now.addingTimeInterval(-week), false) }
        let behind = now.timeIntervalSince(reset)
        if behind >= 0 {
            reset = reset.addingTimeInterval((floor(behind / week) + 1) * week)
        }
        return (reset.addingTimeInterval(-week), true)
    }
}

// MARK: - Text

enum TokenText {
    /// "950", "12.3k", "1.2M", "2.5B": one decimal, no trailing ".0".
    static func compact(_ n: Int) -> String {
        if n < 1000 { return String(n) }
        let suffixes = ["", "k", "M", "B", "T"]
        var value = Double(n)
        var unit = 0
        // 999.95 rounds up to "1000.0", so step up to the next unit a hair early.
        while value >= 999.95 && unit < suffixes.count - 1 {
            value /= 1000
            unit += 1
        }
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffixes[unit]
    }

    /// "$12.34 est.", or "≥ $12.34 est." when some tokens came from models the table does not price.
    static func cost(_ t: TokenTotals) -> String {
        let usd = dollars(t.cost) + " est."
        return t.unpricedTokens > 0 ? "≥ " + usd : usd
    }

    /// "$0.04", "$5,286.29": always two decimals, thousands grouped.
    static func dollars(_ usd: Double) -> String {
        "$" + (dollarFormatter.string(from: usd as NSNumber) ?? String(format: "%.2f", usd))
    }

    private static let dollarFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// "Opus 5", "Sonnet 4.6", "Haiku 4.5" from a Claude model id (the date suffix and the
    /// `claude-` prefix go); "Gemini 3.1 Pro Low", "Gemini 3.8 Flash" from a Gemini one (every
    /// dash-separated part capitalised); anything else comes back as it is.
    static func modelName(_ id: String) -> String {
        if id.hasPrefix("gemini-") {
            return id.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    /// Tooltip: "Input 12k · Output 4.5k · Cache write 900k · Cache read 8.2M".
    static func breakdown(_ t: TokenTotals) -> String {
        var parts = [
            "Input \(compact(t.input))",
            "Output \(compact(t.output))",
            "Cache write \(compact(t.cacheWrite))",
            "Cache read \(compact(t.cacheRead))",
        ]
        if t.unpricedTokens > 0 {
            parts.append("\(compact(t.unpricedTokens)) from models without a price")
        }
        return parts.joined(separator: " · ")
    }
}

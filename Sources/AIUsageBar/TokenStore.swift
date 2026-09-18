import Foundation
import Observation

/// Sibling of `UsageStore` for the token rows on the Claude tab: same polling, but the data
/// comes from Claude Code's local transcripts and there is nothing to cache beyond the scanner's own file.
@MainActor @Observable
final class TokenStore {
    /// Deduplicated responses from the last `retention` seconds.
    private(set) var records: [TokenRecord] = []
    /// Every session the retained transcripts mention, keyed by session id.
    private(set) var sessions: [String: SessionMeta] = [:]
    /// Sessions whose `claude` process is running right now.
    private(set) var live: [LiveSession] = []
    private(set) var lastScanned: Date?
    private(set) var error: String?

    /// One day past the longest window shown, so a week aligned to the API reset is always covered.
    nonisolated static let retention: TimeInterval = 8 * 86400

    var scanner = TokenScanner()
    var registry = SessionRegistry()

    private var timer: Timer?
    private var inFlight = false

    // MARK: - scheduling

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.pollInterval, repeats: true) { [weak self] _ in
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
        do {
            records = try await scanner.scan(retainSince: Date().addingTimeInterval(-Self.retention))
            sessions = Dictionary(uniqueKeysWithValues: await scanner.sessions().map { ($0.sessionId, $0) })
            lastScanned = Date()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Cheap and independent of the transcripts, so a scan failure still shows what is open.
        let registry = registry
        live = await Task.detached(priority: .utility) { registry.live() }.value
    }

    // MARK: - derived

    func totals(since start: Date) -> TokenTotals {
        TokenTotals.sum(records, since: start)
    }

    var openCount: Int { live.count }
    var busyCount: Int { live.filter(\.isBusy).count }

    /// Open sessions first (busy before idle, then most recent activity), followed by sessions
    /// that answered since `closedSince` but whose process is gone.
    func sessionRows(closedSince: Date) -> [SessionRow] {
        var byId: [String: [TokenRecord]] = [:]
        for r in records { byId[r.sessionId ?? "", default: []].append(r) }
        func row(id: String, live: LiveSession?, meta: SessionMeta?) -> SessionRow {
            SessionRow(id: id, live: live, meta: meta,
                       totals: TokenTotals.sum(byId[id] ?? [], since: .distantPast))
        }
        var rows = live.map { row(id: $0.sessionId, live: $0, meta: sessions[$0.sessionId]) }
        let openIds = Set(live.map(\.sessionId))
        for meta in sessions.values
            where !openIds.contains(meta.sessionId) && meta.lastSeen >= closedSince {
            rows.append(row(id: meta.sessionId, live: nil, meta: meta))
        }
        return rows.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.lastActivity > b.lastActivity
        }
    }
}

/// One line of the sessions window: the registry entry (when open), what the transcript says,
/// and the session's tokens summed over the retained days.
struct SessionRow: Identifiable, Equatable {
    var id: String
    var live: LiveSession?
    var meta: SessionMeta?
    var totals: TokenTotals

    var isOpen: Bool { live != nil }
    var isBusy: Bool { live?.isBusy ?? false }
    var cwd: String? { live?.cwd ?? meta?.cwd }

    /// A /rename wins, then Claude Code's own title, then the last prompt, then the slug.
    var title: String {
        if let name = live?.userName, !name.isEmpty { return name }
        if let title = meta?.title, !title.isEmpty { return title }
        if let prompt = meta?.lastPrompt, !prompt.isEmpty { return prompt }
        if let slug = meta?.slug, !slug.isEmpty { return slug }
        return String(id.prefix(8))
    }

    /// The transcript's last answer, or the registry's last write for a session that has not answered yet.
    var lastActivity: Date {
        if let seen = meta?.lastSeen, seen != .distantPast { return seen }
        return live?.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
    }

    /// When the session began: the first transcript answer, else the process start.
    var started: Date? {
        if let first = meta?.firstSeen, first != .distantFuture { return first }
        return live?.started
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
        let usd = String(format: "$%.2f est.", t.cost)
        return t.unpricedTokens > 0 ? "≥ " + usd : usd
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

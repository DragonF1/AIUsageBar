import Foundation
import Observation

/// The Antigravity tab's counterpart of `TokenStore`: same polling and the same views, fed by
/// the conversation databases Antigravity keeps locally instead of Claude Code's transcripts.
@MainActor @Observable
final class AntigravityTokenStore: TokenLedger {
    let product = TokenProduct.antigravity
    private(set) var records: [TokenRecord] = []
    private(set) var lastScanned: Date?
    private(set) var error: String?

    var scanner = AntigravityTokenScanner()

    private var timer: Timer?
    private var inFlight = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.statusPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        // The first scan decodes every recent conversation once; keep it off the interactive lanes.
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
            let scanned = Self.ordered(try await scanner.scan(retainSince: Date().addingTimeInterval(-TokenStore.retention)))
            // Unchanged records keep the old array, so nothing observing them redraws.
            if scanned != records { records = scanned }
            lastScanned = Date()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Takes a scan's worth of records as if the scanner had just produced them (the screenshot renderer).
    func adopt(records: [TokenRecord], at date: Date) {
        self.records = Self.ordered(records)
        lastScanned = date
        error = nil
    }

    /// Oldest first, as `TokenLedger` promises; ties broken on content so the same set of
    /// records always comes out in the same order and compares equal to the last scan's.
    private static func ordered(_ records: [TokenRecord]) -> [TokenRecord] {
        records.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            if a.total != b.total { return a.total < b.total }
            if a.model != b.model { return a.model < b.model }
            return (a.sessionId ?? "") < (b.sessionId ?? "")
        }
    }
}

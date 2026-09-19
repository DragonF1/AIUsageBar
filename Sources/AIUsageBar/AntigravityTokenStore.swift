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
    /// Antigravity conversations are not tied to a folder, so the cost window shows no projects.
    let sessionFolders: [String: String]? = nil

    var scanner = AntigravityTokenScanner()

    private var timer: Timer?
    private var inFlight = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.pollInterval, repeats: true) { [weak self] _ in
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
            records = try await scanner.scan(retainSince: Date().addingTimeInterval(-TokenStore.retention))
            lastScanned = Date()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Takes a scan's worth of records as if the scanner had just produced them (the screenshot renderer).
    func adopt(records: [TokenRecord], at date: Date) {
        self.records = records
        lastScanned = date
        error = nil
    }
}

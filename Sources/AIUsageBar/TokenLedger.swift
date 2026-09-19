import Foundation
import Observation

/// What the cost rows and the cost window need from a store, so the Claude Code and Antigravity
/// stores share one set of views: the retained records, when they were last scanned, and the
/// words to put around them.
@MainActor
protocol TokenLedger: AnyObject, Observable {
    var product: TokenProduct { get }
    /// Deduplicated responses from the last `TokenStore.retention` seconds.
    var records: [TokenRecord] { get }
    var lastScanned: Date? { get }
    var error: String? { get }
    /// Session id -> the folder that session ran in, for the cost window's By project rows;
    /// nil when the product has no folders to speak of.
    var sessionFolders: [String: String]? { get }
    func refresh(reason: String) async
}

extension TokenLedger {
    func totals(since start: Date) -> TokenTotals {
        TokenTotals.sum(records, since: start)
    }

    func costReport(now: Date = Date(), range: CostRange = .month) -> CostReport {
        CostReport.build(records, now: now, dayCount: range.days, folders: sessionFolders)
    }
}

/// The product a ledger counts for, as the shared views name it.
struct TokenProduct: Equatable {
    /// "Claude Code" / "Antigravity": prefixes the window title and the empty-chart caption.
    var name: String
    /// Shown until the first scan finishes.
    var scanning: String
    /// The cost window's footer: where the numbers come from and what they are not.
    var footer: String

    static let claudeCode = TokenProduct(
        name: "Claude Code",
        scanning: "Scanning Claude Code transcripts…",
        footer: "Estimates at list prices from the transcripts under ~/.claude/projects, not what a subscription bills. Hover a bar for that day.")

    static let antigravity = TokenProduct(
        name: "Antigravity",
        scanning: "Scanning Antigravity conversations…",
        footer: "Estimates at Gemini API list prices from the conversations under ~/.gemini/antigravity, not what an Antigravity plan bills. Thinking tokens count as output. Hover a bar for that day.")
}

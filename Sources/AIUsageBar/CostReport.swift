import Foundation

/// The cost window's numbers, derived from the token records the store holds: one bucket per
/// calendar day for the chart (empty days included, so the bars line up), the same days summed
/// per model and per project folder, and today on its own. Every figure is the list-price
/// estimate the cost rows use.
struct CostReport: Equatable {
    struct Day: Equatable, Identifiable {
        var start: Date
        var totals: TokenTotals
        var id: Date { start }
    }

    struct ModelShare: Equatable, Identifiable {
        var model: String
        var totals: TokenTotals
        var id: String { model }
    }

    /// One folder's share: the working directory of every session that ran there. `folder` is
    /// nil for records whose session the ledger cannot place (a transcript with no cwd line).
    struct ProjectShare: Equatable, Identifiable {
        var folder: String?
        var totals: TokenTotals
        var id: String { folder ?? "" }
    }

    /// Calendar days the popover's cost row and the default report cover, today included.
    static let dayCount = 30

    /// Oldest first, exactly `dayCount` entries.
    var days: [Day]
    /// Costliest first; models the price table does not know sort by tokens after the priced ones.
    var models: [ModelShare]
    /// Costliest first, same tie-breaks as `models`; empty when the ledger has no folders to offer.
    var projects: [ProjectShare]
    var today: TokenTotals
    /// Every day in `days` summed.
    var total: TokenTotals

    var start: Date { days.first?.start ?? .distantPast }

    /// `folders` maps a session id to the folder it ran in; nil (the Antigravity ledger) leaves
    /// `projects` empty, while a session missing from the map lands in the nil-folder share.
    static func build(_ records: [TokenRecord], now: Date = Date(), calendar: Calendar = .current,
                      dayCount: Int = CostReport.dayCount, folders: [String: String]? = nil) -> CostReport
    {
        let todayStart = calendar.startOfDay(for: now)
        let starts = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: todayStart) }
        var byDay: [Date: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byFolder: [String?: TokenTotals] = [:]
        var today = TokenTotals()
        var total = TokenTotals()

        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            // Before the window, or stamped after today by a skewed clock: not on the chart.
            guard let first = starts.first, day >= first, day <= todayStart else { continue }
            byDay[day, default: TokenTotals()].add(record)
            byModel[record.model, default: TokenTotals()].add(record)
            if let folders {
                byFolder[record.sessionId.flatMap { folders[$0] }, default: TokenTotals()].add(record)
            }
            total.add(record)
            if day == todayStart { today.add(record) }
        }

        let models = byModel.map { ModelShare(model: $0.key, totals: $0.value) }.sorted { a, b in
            rank(a.totals, a.model, before: b.totals, b.model)
        }
        // A nil folder names nothing, so it sorts last among equals.
        let projects = byFolder.map { ProjectShare(folder: $0.key, totals: $0.value) }.sorted { a, b in
            rank(a.totals, a.folder ?? "\u{10FFFF}", before: b.totals, b.folder ?? "\u{10FFFF}")
        }
        return CostReport(days: starts.map { Day(start: $0, totals: byDay[$0] ?? TokenTotals()) },
                          models: models,
                          projects: projects,
                          today: today,
                          total: total)
    }

    /// Cost, then tokens, then name: the order every share list uses.
    private static func rank(_ a: TokenTotals, _ aName: String, before b: TokenTotals, _ bName: String) -> Bool {
        if a.cost != b.cost { return a.cost > b.cost }
        if a.tokens != b.tokens { return a.tokens > b.tokens }
        return aName < bName
    }
}

/// How far back the cost window looks. The raw value is the day count, today included.
enum CostRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { "\(rawValue) days" }

    /// Days between the chart's x-axis labels, so every range shows a handful.
    var axisStride: Int {
        switch self {
        case .week: return 1
        case .month: return 7
        case .quarter: return 14
        }
    }

    /// The longest range plus one day, so the oldest bar is complete however far into today the scan runs.
    static let retentionDays = (allCases.map(\.rawValue).max() ?? CostReport.dayCount) + 1
}

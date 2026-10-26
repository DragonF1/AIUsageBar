import Foundation

/// The cost window's numbers, derived from the token records the store holds: one bucket per
/// calendar day for the chart (empty days included, so the bars line up), the same days summed
/// per model, and today on its own. Every figure is the list-price estimate the cost rows use.
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

    /// Calendar days the popover's cost row and the default report cover, today included.
    static let dayCount = 30

    /// Oldest first, exactly `dayCount` entries.
    var days: [Day]
    /// Costliest first; models the price table does not know sort by tokens after the priced ones.
    var models: [ModelShare]
    var today: TokenTotals
    /// Every day in `days` summed.
    var total: TokenTotals

    var start: Date { days.first?.start ?? .distantPast }

    static func build(_ records: [TokenRecord], now: Date = Date(), calendar: Calendar = .current,
                      dayCount: Int = CostReport.dayCount) -> CostReport
    {
        let todayStart = calendar.startOfDay(for: now)
        let starts = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: todayStart) }
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86400)
        var byDay = [TokenTotals](repeating: TokenTotals(), count: starts.count)
        var byModel: [String: TokenTotals] = [:]
        var today = TokenTotals()
        var total = TokenTotals()
        var prices = TokenPricing.Lookup()
        let todayIndex = starts.last == todayStart ? starts.count - 1 : nil

        for record in records {
            let ts = record.timestamp
            // Before the window, or stamped after today by a skewed clock: not on the chart.
            guard let first = starts.first, ts >= first, ts < end else { continue }
            // The day is the last start at or before the timestamp: the same bucket
            // `startOfDay` names, without a calendar computation per record.
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= ts { lo = mid + 1 } else { hi = mid }
            }
            let day = lo - 1
            let usd = prices.cost(record)
            byDay[day].add(record, cost: usd)
            byModel[record.model, default: TokenTotals()].add(record, cost: usd)
            total.add(record, cost: usd)
            if day == todayIndex { today.add(record, cost: usd) }
        }

        let models = byModel.map { ModelShare(model: $0.key, totals: $0.value) }.sorted { a, b in
            rank(a.totals, a.model, before: b.totals, b.model)
        }
        return CostReport(days: zip(starts, byDay).map { Day(start: $0, totals: $1) },
                          models: models,
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

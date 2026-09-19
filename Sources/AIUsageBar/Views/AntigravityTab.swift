import SwiftUI

/// Antigravity's four limits (weekly and 5-hour for the Gemini group, the same two for the
/// Claude and GPT group) drawn with the same bars as the Claude tab, as percent used.
struct AntigravityTab: View {
    var store: AntigravityStore
    var monitor: QuotaMonitor
    var now: Date

    var body: some View {
        let groups = store.usage?.groups ?? []
        if groups.isEmpty {
            Text(emptyText).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group.buckets) { bucket in
                        let reading = QuotaReading.antigravity(group: group, bucket: bucket)
                        LimitRow(title: reading.name,
                                 percent: bucket.percentUsed,
                                 detail: bucket.detail(now: now),
                                 pace: monitor.paceLine(for: reading.id, window: reading.window, now: now),
                                 dimmed: store.isStale)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if case .error(let why) = store.state { return why }
        return "No Antigravity usage yet."
    }
}

extension AntigravityUsage.Group {
    /// "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude and GPT".
    var shortTitle: String {
        var s = title
        for suffix in [" Models", " models"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}

extension AntigravityUsage.Bucket {
    /// "Gemini 5h" / "Gemini weekly" / "Claude and GPT 5h" / "Claude and GPT weekly".
    func rowTitle(in group: AntigravityUsage.Group) -> String {
        let window: String
        switch self.window {
        case "5h": window = "5h"
        case "weekly": window = "weekly"
        default: window = title.replacingOccurrences(of: " Limit Remaining", with: "").lowercased()
        }
        return "\(group.shortTitle) \(window)"
    }

    /// The reset time, worded like the Claude rows. Google's own sentence is deliberately not
    /// shown. An idle 5-hour row says so instead of counting down a reset that moves with every poll.
    func detail(now: Date) -> String? {
        if isIdle { return "No usage this window yet" }
        return ResetText.describe(resetsAt, window: window == "5h" ? .fiveHour : .other, now: now)
    }
}

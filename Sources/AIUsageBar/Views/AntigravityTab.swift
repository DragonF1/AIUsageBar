import SwiftUI

/// Antigravity's four limits (weekly and 5-hour for the Gemini group, the same two for the
/// Claude and GPT group) drawn with the same bars as the Claude tab, as percent used.
struct AntigravityTab: View {
    var store: AntigravityStore
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
                        LimitRow(title: title(group: group, bucket: bucket),
                                 percent: bucket.percentUsed,
                                 detail: bucket.detail(now: now),
                                 dimmed: store.isStale)
                    }
                }
            }
        }
    }

    /// "Gemini 5h" / "Gemini weekly" / "Claude and GPT 5h" / "Claude and GPT weekly".
    private func title(group: AntigravityUsage.Group, bucket: AntigravityUsage.Bucket) -> String {
        let window: String
        switch bucket.window {
        case "5h": window = "5h"
        case "weekly": window = "weekly"
        default: window = bucket.title.replacingOccurrences(of: " Limit Remaining", with: "").lowercased()
        }
        return "\(shortGroup(group.title)) \(window)"
    }

    /// "Gemini Models" -> "Gemini", "Claude and GPT models" -> "Claude and GPT".
    private func shortGroup(_ title: String) -> String {
        var s = title
        for suffix in [" Models", " models"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }

    private var emptyText: String {
        if case .error(let why) = store.state { return why }
        return "No Antigravity usage yet."
    }
}

extension AntigravityUsage.Bucket {
    /// The reset time, worded like the Claude rows. Google's own sentence is deliberately not
    /// shown. An idle 5-hour row says so instead of counting down a reset that moves with every poll.
    func detail(now: Date) -> String? {
        if isIdle { return "No usage this window yet" }
        return ResetText.describe(resetsAt, window: window == "5h" ? .fiveHour : .other, now: now)
    }
}

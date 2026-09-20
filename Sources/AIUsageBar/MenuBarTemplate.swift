import Foundation

/// Everything a menu bar template can quote a number from: both windows' percentages, both
/// windows' reset times, and today's spend, all read against one instant. Pure and
/// product-agnostic, so the same values feed the live menu bar and a settings preview.
struct MenuBarValues: Equatable {
    var sessionPercent: Double?
    var weeklyPercent: Double?
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var todayCost: Double?
    var now: Date
    var showRemaining: Bool

    /// The values behind whichever tab is showing, read once against `now`. The live menu bar
    /// and the Appearance preview both build from here, so a new token cannot land in one and
    /// not the other.
    @MainActor static func current(tab: UsageTab, usage: UsageStore, antigravity: AntigravityStore,
                                   tokens: TokenStore, antigravityTokens: AntigravityTokenStore,
                                   now: Date, showRemaining: Bool) -> MenuBarValues
    {
        let today = TokenWindow.todayStart(now: now)
        switch tab {
        case .claude:
            return MenuBarValues(sessionPercent: usage.sessionPercent, weeklyPercent: usage.weeklyPercent,
                                 sessionResetsAt: usage.usage?.sessionResetsAt, weeklyResetsAt: usage.usage?.weeklyResetsAt,
                                 todayCost: tokens.totals(since: today).cost, now: now, showRemaining: showRemaining)
        case .antigravity:
            return MenuBarValues(sessionPercent: antigravity.geminiSessionPercent, weeklyPercent: antigravity.geminiWeeklyPercent,
                                 sessionResetsAt: antigravity.geminiSessionResetsAt, weeklyResetsAt: antigravity.geminiWeeklyResetsAt,
                                 todayCost: antigravityTokens.totals(since: today).cost, now: now, showRemaining: showRemaining)
        }
    }
}

/// The menu bar's text as a small template language: `{5h}`, `{week}`, `{reset5h}`,
/// `{resetWeek}` and `{cost}`, substituted with plain string replacement (no regex, no escaping
/// needed since none of the tokens are valid substrings of each other). An empty format is a
/// deliberate value, not an error: it draws the icon alone.
enum MenuBarTemplate {
    static let tokens = ["{5h}", "{week}", "{reset5h}", "{resetWeek}", "{cost}"]

    /// Unknown tokens (a typo, a token from a future build) pass through verbatim rather than
    /// vanish, so a bad edit is obvious instead of silently empty.
    static func render(_ format: String, values: MenuBarValues) -> String {
        var text = format
        text = text.replacingOccurrences(of: "{5h}", with: PercentText.bare(values.sessionPercent, remaining: values.showRemaining))
        text = text.replacingOccurrences(of: "{week}", with: PercentText.bare(values.weeklyPercent, remaining: values.showRemaining))
        text = text.replacingOccurrences(of: "{reset5h}", with: resetText(values.sessionResetsAt, now: values.now))
        text = text.replacingOccurrences(of: "{resetWeek}", with: resetText(values.weeklyResetsAt, now: values.now))
        text = text.replacingOccurrences(of: "{cost}", with: values.todayCost.map(TokenText.dollars) ?? "–")
        return text
    }

    /// "3d 4h" style remaining time for a future date; "–" for a missing or already-past one, so
    /// the template never shows "Resetting" mid-word.
    private static func resetText(_ date: Date?, now: Date) -> String {
        guard let date, date > now else { return "–" }
        return ResetText.remaining(date.timeIntervalSince(now))
    }
}

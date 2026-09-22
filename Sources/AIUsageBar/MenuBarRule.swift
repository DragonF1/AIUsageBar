import Foundation

/// Which window a rule's condition reads.
enum MenuBarWindow: String, Codable, CaseIterable {
    case session, weekly

    var title: String {
        switch self {
        case .session: return "5-hour"
        case .weekly: return "Weekly"
        }
    }
}

/// How a rule's condition tests its number against its threshold. Declared in picker order
/// (`under` first, `over` last) since the editor's `Picker` walks `allCases`; the raw values of
/// `atLeast` and `under` predate the other three cases and are persisted in UserDefaults, so they
/// must never change even though their titles have.
enum MenuBarComparison: String, Codable, CaseIterable {
    case under, atMost, equal, atLeast, over

    var title: String {
        switch self {
        case .under: return "less than"
        case .atMost: return "less than or equal to"
        case .equal: return "equal to"
        case .atLeast: return "greater than or equal to"
        case .over: return "greater than"
        }
    }
}

/// One rule's number to test against: a straight percent, or a place on the colour scale, so a
/// rule can follow the user's own cutoffs instead of a fixed figure.
enum MenuBarThreshold: Codable, Equatable {
    case percent(Double)
    case band(UsageColor.Level)
}

/// One specific limit family a rule can target instead of a tab-relative window, "Claude: Fable"
/// say. `scope` matches a `QuotaReading.scope` (stable across that family's 5-hour and weekly
/// readings, unique across products); the condition's own `window` then picks which of the
/// family's windows is actually read, the same independent setting it is for a tab-relative rule.
/// `product` and `name` are stored alongside `scope`, not derived at match time, so the editor
/// can still label the rule after that limit stops being reported (a plan change, a renamed
/// model, a group that no longer appears).
struct MenuBarLimitRef: Codable, Equatable {
    var scope: String
    var product: String
    var name: String
}

/// "5-hour greater than or equal to 80%", or "Fable weekly greater than or equal to 80%": the
/// window plus the comparison and the threshold a rule watches for. With `limit` set, `window`
/// still picks the 5-hour or weekly reading, but now from that one limit family rather than from
/// whichever tab is showing: which limit and which window are two independent settings. A nil
/// `limit` is exactly today's tab-relative behaviour; a non-nil one is evaluated globally, the
/// same regardless of which tab's numbers `window` would otherwise have read. Pure and stateless;
/// `matches` is the only place a live number ever touches this type.
struct MenuBarCondition: Codable, Equatable {
    var window: MenuBarWindow
    var comparison: MenuBarComparison
    var threshold: MenuBarThreshold
    /// nil for a tab-relative window rule (today's behaviour); set for a rule that targets one
    /// specific limit family regardless of the tab showing. Optional so a rule saved before this
    /// feature existed, whose JSON has no `limit` key at all, still decodes.
    var limit: MenuBarLimitRef?

    /// The percent and reset time this condition actually tests: a specific limit's reading when
    /// `limit` is set (nil when that scope has no reading fitting `window`, e.g. the limit has
    /// not reported yet, reads differently after a plan change, or the family (Fable) simply has
    /// no 5-hour reading to pick), otherwise the tab's session or weekly percent and reset,
    /// matching `window`.
    func reading(in values: MenuBarValues) -> (percent: Double?, resetsAt: Date?) {
        if let limit {
            let reading = values.readings.first { $0.scope == limit.scope && Self.fits($0.window, window) }
            return (reading?.percent, reading?.resetsAt)
        }
        switch window {
        case .session: return (values.sessionPercent, values.sessionResetsAt)
        case .weekly: return (values.weeklyPercent, values.weeklyResetsAt)
        }
    }

    /// Whether a reading's own window belongs under a rule's `.session`/`.weekly` setting: a
    /// `.fiveHour` reading fits `.session`, a `.weekly` reading fits `.weekly`, and a `.monthly`
    /// reading (extra usage, a single-window family with nothing to choose between) fits either,
    /// so the rule's window field is simply ignored for it.
    private static func fits(_ readingWindow: QuotaReading.Window, _ ruleWindow: MenuBarWindow) -> Bool {
        switch readingWindow {
        case .fiveHour: return ruleWindow == .session
        case .weekly: return ruleWindow == .weekly
        case .monthly: return true
        }
    }

    /// Reads the targeted number (never adjusted for "Show remaining", which only affects
    /// rendering) and compares it to the threshold; a missing percent never matches, so a rule
    /// stays quiet rather than firing on a window or limit that has not reported yet.
    func matches(_ values: MenuBarValues, scale: ColorScale) -> Bool {
        guard let percent = reading(in: values).percent else { return false }
        switch threshold {
        case .percent(let n):
            switch comparison {
            case .under: return percent < n
            case .atMost: return percent <= n
            // Rounded to match what the menu bar itself displays (`PercentText`), so "equal to
            // 3" fires on the same numbers a user would read as "3%".
            case .equal: return percent.rounded() == n
            case .atLeast: return percent >= n
            case .over: return percent > n
            }
        case .band(let band):
            let level = scale.level(for: percent)
            switch comparison {
            case .under: return level < band
            case .atMost: return level <= band
            case .equal: return level == band
            case .atLeast: return level >= band
            case .over: return level > band
            }
        }
    }
}

/// One entry in the menu bar's rule list: a condition and the template to use while it holds.
/// The list is checked in order and the first match wins (`MenuBarRules`); a fresh install has
/// none, so nothing changes until the user adds one.
struct MenuBarRule: Identifiable, Codable, Equatable {
    var id: UUID
    var condition: MenuBarCondition
    var format: String

    init(id: UUID = UUID(), condition: MenuBarCondition, format: String) {
        self.id = id
        self.condition = condition
        self.format = format
    }

    /// Field by field, same spirit as `ColorScale.init(from:)`: a missing `id` gets a fresh one
    /// and a missing `format` becomes "", so a rule an older or newer build wrote keeps working;
    /// `condition` is the one thing a rule cannot do without, so its absence still throws.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        condition = try container.decode(MenuBarCondition.self, forKey: .condition)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
    }

    /// Decodes one rule permissively: an entry this build cannot make sense of (an unknown
    /// window or comparison, a threshold matching neither case, something that is not an object
    /// at all) fails quietly instead of invalidating every rule around it.
    private struct LenientRule: Decodable {
        let rule: MenuBarRule?
        init(from decoder: Decoder) throws {
            rule = try? MenuBarRule(from: decoder)
        }
    }

    /// `nil` or unparsable data is the same as an empty list, the pre-feature behaviour; any
    /// element this build cannot read drops out of the list on its own, the rest survive.
    static func decodeList(_ data: Data?) -> [MenuBarRule] {
        guard let data, let decoded = try? JSONDecoder().decode([LenientRule].self, from: data) else { return [] }
        return decoded.compactMap(\.rule)
    }

    static func encodeList(_ rules: [MenuBarRule]) -> Data {
        (try? JSONEncoder().encode(rules)) ?? Data()
    }
}

/// Picks the first rule (in list order) whose condition matches the current numbers, and
/// resolves the menu bar's text from it, falling back to the plain template field when no rule
/// matches or the list is empty.
enum MenuBarRules {
    static func winner(for values: MenuBarValues, rules: [MenuBarRule], scale: ColorScale) -> MenuBarRule? {
        rules.first { $0.condition.matches(values, scale: scale) }
    }

    static func format(for values: MenuBarValues, rules: [MenuBarRule], fallback: String, scale: ColorScale) -> String {
        winner(for: values, rules: rules, scale: scale)?.format ?? fallback
    }

    /// Picks the winner exactly like `format`, but also carries the number a limit rule's
    /// template needs: a copy of `values` with `matchedPercent`/`matchedResetsAt` filled from
    /// whatever the winning condition actually tested (`MenuBarCondition.reading(in:)`), so
    /// `{value}`/`{reset}` quote that limit's own figures rather than the tab's. Both stay nil on
    /// the fallback template, so its tokens read as missing instead of quoting a stale number.
    static func resolve(for values: MenuBarValues, rules: [MenuBarRule], fallback: String, scale: ColorScale)
        -> (format: String, values: MenuBarValues)
    {
        guard let winner = winner(for: values, rules: rules, scale: scale) else { return (fallback, values) }
        var resolved = values
        let reading = winner.condition.reading(in: values)
        resolved.matchedPercent = reading.percent
        resolved.matchedResetsAt = reading.resetsAt
        return (winner.format, resolved)
    }
}

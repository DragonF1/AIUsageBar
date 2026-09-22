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

/// "5-hour greater than or equal to 80%": the window, the comparison and the threshold a rule
/// watches for.
/// Pure and stateless; `matches` is the only place a live number ever touches this type.
struct MenuBarCondition: Codable, Equatable {
    var window: MenuBarWindow
    var comparison: MenuBarComparison
    var threshold: MenuBarThreshold

    /// Reads the window's used percent (never adjusted for "Show remaining", which only affects
    /// rendering) and compares it to the threshold; a missing percent never matches, so a rule
    /// stays quiet rather than firing on a window that has not reported yet.
    func matches(_ values: MenuBarValues, scale: ColorScale) -> Bool {
        let percent: Double?
        switch window {
        case .session: percent = values.sessionPercent
        case .weekly: percent = values.weeklyPercent
        }
        guard let percent else { return false }
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
}

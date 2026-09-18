import Foundation

/// Which provider the popover (and the menu bar item) is showing.
enum UsageTab: String, CaseIterable, Identifiable {
    case claude
    case antigravity

    static let key = "selectedTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }

    static var current: UsageTab {
        UsageTab(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .claude
    }
}

import AppKit
import ServiceManagement

/// The switches in the status item's right-click menu. Stored in UserDefaults; every read
/// falls back to the built-in default so a fresh install behaves as it did before the switches.
enum Preferences {
    enum Key {
        static let startAtLogin = "startAtLogin"
        static let notifications = "notifications"
        static let menuBarMetric = "menuBarMetric"
        static let costRange = "costRange"
        static let extraUsage = "extraUsage"
        static let colorScale = "colorScale"
    }

    static var defaults: UserDefaults = .standard

    /// Register the app as a login item (on by default, as it always was).
    static var startAtLogin: Bool {
        get { defaults.object(forKey: Key.startAtLogin) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.startAtLogin) }
    }

    /// Post quota notifications (thresholds, used up, reset, pace).
    static var notifications: Bool {
        get { defaults.object(forKey: Key.notifications) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notifications) }
    }

    /// Show the credits rows: the month's extra-usage credits under the Claude rows (warned on
    /// like any other window) and the AI credits row under the Antigravity rows. On by default.
    static var extraUsage: Bool {
        get { defaults.object(forKey: Key.extraUsage) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.extraUsage) }
    }

    /// Which window colours the menu bar icon.
    static var menuBarMetric: MenuBarMetric {
        get { MenuBarMetric(rawValue: defaults.string(forKey: Key.menuBarMetric) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarMetric) }
    }

    /// The cutoffs and colours for the four usage bands; garbage or missing data falls back
    /// to `.default`, which is the original fixed 75/85/95 scale.
    static var colorScale: ColorScale {
        get { ColorScale.decode(defaults.data(forKey: Key.colorScale)) }
        set { defaults.set(newValue.normalized().encoded(), forKey: Key.colorScale) }
    }
}

/// What tints the menu bar icon. `auto` is the original rule: the 5-hour window, unless the
/// weekly one has reached the scale's high cutoff (85% on the default scale).
enum MenuBarMetric: String, CaseIterable {
    case auto
    case session
    case weekly

    /// Named against the current scale, so the `auto` label quotes the cutoff it really uses.
    var title: String { title(scale: Preferences.colorScale) }

    func title(scale: ColorScale) -> String {
        switch self {
        case .auto: return "Auto (5-hour, weekly from \(Int(scale.highCutoff.rounded()))%)"
        case .session: return "5-hour window"
        case .weekly: return "Weekly window"
        }
    }
}

/// The web page behind the menus' last item, per tab. claude.ai has a usage page; Antigravity
/// shows its quota only in the app, so its tab opens the Google One page that sets the plan
/// (and sells the AI credits that extend it).
enum UsagePage {
    static let claude = URL(string: "https://claude.ai/settings/usage")!
    static let antigravity = URL(string: "https://one.google.com/ai")!

    static func url(for tab: UsageTab) -> URL {
        switch tab {
        case .claude: return claude
        case .antigravity: return antigravity
        }
    }

    static func title(for tab: UsageTab) -> String {
        switch tab {
        case .claude: return "Usage on claude.ai"
        case .antigravity: return "Plan on Google One"
        }
    }

    static func open(for tab: UsageTab) {
        NSWorkspace.shared.open(url(for: tab))
    }
}

enum LoginItem {
    /// Registers or drops the login item to match the switch. Errors are ignored: System
    /// Settings can override either way, and the status is read again on the next launch.
    static func apply(_ wanted: Bool) {
        let service = SMAppService.mainApp
        if wanted {
            if service.status != .enabled { try? service.register() }
        } else if service.status == .enabled {
            try? service.unregister()
        }
    }
}

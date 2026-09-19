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

    /// Which window colours the menu bar icon.
    static var menuBarMetric: MenuBarMetric {
        get { MenuBarMetric(rawValue: defaults.string(forKey: Key.menuBarMetric) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarMetric) }
    }
}

/// What tints the menu bar icon. `auto` is the original rule: the 5-hour window, unless the
/// weekly one is at 85% or more.
enum MenuBarMetric: String, CaseIterable {
    case auto
    case session
    case weekly

    var title: String {
        switch self {
        case .auto: return "Auto (5-hour, weekly from 85%)"
        case .session: return "5-hour window"
        case .weekly: return "Weekly window"
        }
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

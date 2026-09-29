import Foundation

/// How the sessions window reopens a closed session.
enum ResumeMode: String, CaseIterable, Sendable {
    /// A new Terminal window running `claude --resume`.
    case terminal
    /// The user's own script, run with the session and its folder in the environment.
    case launcher

    var title: String {
        switch self {
        case .terminal: return "Terminal window"
        case .launcher: return "Custom launcher script"
        }
    }
}

/// The resume choices in force: what Settings saved, and where it never saved anything, what
/// `config.json` names. The values are as typed (a tilde is expanded where they are used), so
/// Settings can show them back unchanged.
struct ResumeSettings: Equatable, Sendable {
    var mode: ResumeMode
    var launcher: String
    var envFile: String
    /// Raw text appended after `claude --resume '<id>'` in Terminal mode.
    var extraArguments: String

    /// A saved value wins, one at a time, so saving the launcher does not hide config.json's env
    /// file. The mode follows the launcher when it was never picked: a config.json that names a
    /// launcher gets the custom launcher, anything else the Terminal window.
    static func effective(defaults: UserDefaults = Preferences.defaults, config: AppConfig.Settings.Resume?) -> ResumeSettings {
        let launcher = defaults.string(forKey: Preferences.Key.resumeLauncher) ?? config?.launcher ?? ""
        let saved = defaults.string(forKey: Preferences.Key.resumeMode).flatMap(ResumeMode.init(rawValue:))
        return ResumeSettings(
            mode: saved ?? (launcher.trimmingCharacters(in: .whitespaces).isEmpty ? .terminal : .launcher),
            launcher: launcher,
            envFile: defaults.string(forKey: Preferences.Key.resumeEnvFile) ?? config?.envFile ?? "",
            extraArguments: defaults.string(forKey: Preferences.Key.resumeExtraArguments) ?? "")
    }
}

import SwiftUI

/// The "Claude" tab of the Settings window: which folder Claude Code keeps its state in, and how
/// the sessions window reopens a closed session. Values are read when the tab is built and after
/// each save; the folder applies to the next refresh with no restart.
struct ClaudeSettingsView: View {
    private let config = AppConfig.loadSettings().resume

    @State private var folder = Preferences.claudeFolder
    @State private var resume: ResumeSettings

    init() {
        _resume = State(initialValue: ResumeSettings.effective(config: AppConfig.loadSettings().resume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Claude Code folder")
                SettingsField("~/.claude", value: folder, choice: .folder, canReset: true) { typed in
                    Preferences.claudeFolder = typed
                    folder = Preferences.claudeFolder
                }
                SettingCaption("Where Claude Code keeps its login, transcripts and sessions. Leave it empty for "
                               + "~/.claude; set it when you run claude with CLAUDE_CONFIG_DIR.")
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Resume")
                HStack {
                    Text("Open in")
                    Spacer()
                    Picker("", selection: modeBinding) {
                        ForEach(ResumeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                switch resume.mode {
                case .terminal:
                    terminalFields
                case .launcher:
                    launcherFields
                }
                if let claudeConfigDir = ClaudeFolder(configured: folder).claudeConfigDir {
                    SettingCaption("claude is started with CLAUDE_CONFIG_DIR=\(claudeConfigDir).")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra arguments").frame(width: 110, alignment: .leading)
                SettingsField("--effort high", value: resume.extraArguments) { typed in
                    Preferences.resumeExtraArguments = typed
                    resume.extraArguments = typed
                }
            }
            SettingCaption("Added as typed after claude --resume '<id>' in a new Terminal window. Empty adds nothing.")
        }
    }

    private var launcherFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Launcher").frame(width: 110, alignment: .leading)
                SettingsField("Path to a script", value: resume.launcher, choice: .file) { typed in
                    Preferences.resumeLauncher = typed
                    resume.launcher = typed
                }
            }
            if launcherIsMissing {
                SettingCaption("No file at \(AppConfig.expand(resume.launcher.trimmingCharacters(in: .whitespaces))). "
                               + "Resuming will fail until it exists.", isWarning: true)
            }
            HStack {
                Text("Env file").frame(width: 110, alignment: .leading)
                SettingsField("Optional KEY=value file", value: resume.envFile, choice: .file) { typed in
                    Preferences.resumeEnvFile = typed
                    resume.envFile = typed
                }
            }
            SettingCaption("The script runs with CLAUDE_RESUME (the session id) and CLAUDE_LAUNCH_DIR in its "
                           + "environment, after the env file's lines are exported. It opens the window itself.")
        }
    }

    private var modeBinding: Binding<ResumeMode> {
        Binding(get: { resume.mode }, set: { mode in
            Preferences.resumeMode = mode
            resume.mode = mode
        })
    }

    private var launcherIsMissing: Bool {
        let path = resume.launcher.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty || !FileManager.default.fileExists(atPath: AppConfig.expand(path))
    }
}

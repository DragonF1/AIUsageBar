import SwiftUI

/// The "Claude" tab of the Settings window: which folder Claude Code keeps its state in.
/// Values are read when the tab is built and after each save; the folder applies to the next refresh with no restart.
struct ClaudeSettingsView: View {
    @State private var folder = Preferences.claudeFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Claude Code folder")
                SettingsField("~/.claude", value: folder, choice: .folder, canReset: true) { typed in
                    Preferences.claudeFolder = typed
                    folder = Preferences.claudeFolder
                }
                SettingCaption("Where Claude Code keeps its login and transcripts. Leave it empty for "
                               + "~/.claude; set it when you run claude with CLAUDE_CONFIG_DIR.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

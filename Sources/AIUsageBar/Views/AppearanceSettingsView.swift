import SwiftUI

/// The window behind "Appearance…": the menu bar's text template above the colour scale editor,
/// both applying live to the popover and the menu bar icon.
struct AppearanceSettingsView: View {
    var usage: UsageStore
    var antigravity: AntigravityStore
    var tokens: TokenStore
    var antigravityTokens: AntigravityTokenStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MenuBarFormatSection(usage: usage, antigravity: antigravity,
                                  tokens: tokens, antigravityTokens: antigravityTokens)
            Divider()
            ColorScaleSettingsView()
        }
        .padding(20)
        .frame(width: 380)
    }
}

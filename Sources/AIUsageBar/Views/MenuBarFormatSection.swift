import SwiftUI

/// The "Menu bar text" section of the Appearance window: a template editor with a token legend
/// and a live preview built from whichever tab (Claude or Antigravity) is currently showing.
struct MenuBarFormatSection: View {
    var usage: UsageStore
    var antigravity: AntigravityStore
    var tokens: TokenStore
    var antigravityTokens: AntigravityTokenStore

    @AppStorage(UsageTab.key) private var tab: UsageTab = .claude
    @AppStorage(Preferences.Key.showRemaining) private var showRemaining = false

    @State private var draft: String = Preferences.menuBarFormat
    /// The pending write; a fast typist edits many times a second, and every write wakes the
    /// menu bar's redraw, so the store only sees the value once the hand rests.
    @State private var pendingSave: Task<Void, Never>?
    @State private var now = Date()

    /// The preview's countdowns move in whole minutes, so the popover's beat is plenty; the
    /// window is kept alive once opened and this keeps ticking behind it.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar text").font(.body.weight(.medium))
            Text("Build the menu bar's label from these tokens. Leave it empty for the icon alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft) { _, newValue in commit(newValue) }

            Text(MenuBarTemplate.tokens.joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Preview:").font(.caption).foregroundStyle(.secondary)
                Text(preview.isEmpty ? "(icon only)" : preview)
                    .font(.caption.monospaced())
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var preview: String {
        MenuBarTemplate.render(draft, values: previewValues)
    }

    /// Whichever tab is showing, so the preview matches what the menu bar would actually draw.
    private var previewValues: MenuBarValues {
        MenuBarValues.current(tab: tab, usage: usage, antigravity: antigravity, tokens: tokens,
                              antigravityTokens: antigravityTokens, now: now, showRemaining: showRemaining)
    }

    /// Same beat as the colour scale editor: publish to the field at once, persist 150ms later
    /// so a fast typist's every keystroke does not wake the menu bar's redraw.
    private func commit(_ new: String) {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            Preferences.menuBarFormat = new
        }
    }
}

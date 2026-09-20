import SwiftUI

/// The "Menu bar" pane of the Settings window: an ordered list of rules above a fallback
/// template field and a token legend.
struct MenuBarFormatSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An ordered list of rules can swap in a different template when the 5-hour or weekly "
                + "window crosses a percent or a colour band; the first one that matches wins. The field "
                + "below is what shows otherwise. Leave a template empty for the icon alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            MenuBarRulesEditor()
        }
    }
}

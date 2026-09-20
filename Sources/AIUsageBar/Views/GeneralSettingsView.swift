import SwiftUI

/// The "General" tab of the Settings window: the switches that used to live behind the
/// popover's gear menu and still live, unchanged, in the right-click menu. Same labels, same
/// bindings, same side effects, just laid out as a pane instead of a dropdown, with room for a
/// caption under Notifications that a menu item's `.help` text used to carry instead.
struct GeneralSettingsView: View {
    var monitor: QuotaMonitor

    @AppStorage(Preferences.Key.notifications, store: Preferences.defaults) private var notifications = true
    @AppStorage(Preferences.Key.startAtLogin, store: Preferences.defaults) private var startAtLogin = true
    @AppStorage(Preferences.Key.extraUsage, store: Preferences.defaults) private var extraUsage = true
    @AppStorage(Preferences.Key.showRemaining, store: Preferences.defaults) private var showRemaining = false
    @AppStorage(Preferences.Key.showPace, store: Preferences.defaults) private var showPace = true
    @AppStorage(Preferences.Key.menuBarMetric, store: Preferences.defaults) private var metric: MenuBarMetric = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Notifications", isOn: $notifications)
                Text("Warns at \(StatusItemController.thresholdText(monitor.thresholds)), when a window is used up, "
                     + "runs out at the current pace, or resets after a warning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Start at login", isOn: $startAtLogin)
            Toggle("Extra usage credits", isOn: $extraUsage)
            Toggle("Show remaining instead of used", isOn: $showRemaining)
            Toggle("Show pace forecast", isOn: $showPace)

            HStack {
                Text("Menu bar tint")
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onChange(of: notifications) { _, on in
            if on { monitor.notifier.requestAuthorization() }
        }
        .onChange(of: startAtLogin) { _, on in LoginItem.apply(on) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

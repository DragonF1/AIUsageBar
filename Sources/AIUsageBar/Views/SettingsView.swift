import SwiftUI

/// The window behind the popover's gear and the right-click menu's "Settings…": the switches
/// on "General", the menu bar text editor on "Menu bar", and the colour scale editor on
/// "Colours". A segmented switch and a `switch` over the pane, not a `TabView`: the NSTabView
/// behind that draws its tab strip in the light appearance while the window is dark, and the
/// pane box it adds has no inner padding.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, menuBar, colours

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .menuBar: return "Menu bar"
            case .colours: return "Colours"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Switches and the menu bar tint"
            case .menuBar: return "What the menu bar reads"
            case .colours: return "Bands, cutoffs and their colours"
            }
        }
    }

    var monitor: QuotaMonitor
    var usage: UsageStore
    var antigravity: AntigravityStore
    @State private var pane: Pane

    init(monitor: QuotaMonitor, usage: UsageStore, antigravity: AntigravityStore, pane: Pane = .general) {
        self.monitor = monitor
        self.usage = usage
        self.antigravity = antigravity
        _pane = State(initialValue: pane)
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(title: "Settings", subtitle: pane.subtitle) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, Chrome.inset).padding(.vertical, 12)

            Divider()

            Group {
                switch pane {
                case .general:
                    GeneralSettingsView(monitor: monitor)
                case .menuBar:
                    MenuBarFormatSection(usage: usage, antigravity: antigravity)
                case .colours:
                    ColorScaleSettingsView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Chrome.inset)
        }
        .frame(width: 560)
    }
}

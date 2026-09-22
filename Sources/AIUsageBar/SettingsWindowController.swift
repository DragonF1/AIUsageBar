import AppKit
import SwiftUI

/// One floating window over a settings view, the same shape as `TokenWindowController` but
/// without a ledger: built lazily on first `show()` and kept around between showings.
@MainActor
final class SettingsWindowController {
    private let title: String
    private let autosaveName: String
    private let makeView: () -> AnyView
    private var window: PanelWindow?
    private var sizeObservation: NSKeyValueObservation?

    init(title: String, autosaveName: String, makeView: @escaping () -> AnyView) {
        self.title = title
        self.autosaveName = autosaveName
        self.makeView = makeView
    }

    /// The window behind the popover's gear and the right-click menu's "Settings…": General,
    /// Menu bar and Colours panes. A new autosave name ("Settings", not the old
    /// "ColorScaleSettings") because that frame was sized for the single-section "Appearance…"
    /// window and would be too small now the switches moved in beside it.
    static func settings(monitor: QuotaMonitor, usage: UsageStore, antigravity: AntigravityStore) -> SettingsWindowController {
        SettingsWindowController(title: "Settings", autosaveName: "Settings") {
            AnyView(SettingsView(monitor: monitor, usage: usage, antigravity: antigravity))
        }
    }

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> PanelWindow {
        let hosting = NSHostingController(rootView: makeView())
        // The view sets its own fixed width and hugs its height; let the window follow it
        // rather than guessing a size.
        hosting.sizingOptions = [.preferredContentSize]
        let window = PanelWindow.make(title: title, hosting: hosting, resizable: false)
        window.center()
        // After center(), so a frame saved from an earlier showing wins over the default spot.
        window.setFrameAutosaveName(autosaveName)
        // The saved frame carries the height of whichever pane was showing when it was saved;
        // keep its position and size the window to the General pane it opens on. fittingSize
        // is available at once; preferredContentSize is still zero until the first layout.
        let fitting = hosting.view.fittingSize
        if fitting != .zero { window.setContentSize(fitting) }
        // preferredContentSize sizes the window correctly the first time it is shown, but
        // switching panes changes the fitting size after that; watch it explicitly and resize
        // the window to match rather than count on AppKit picking the change up on its own.
        // KVO fires on the thread that set the property, and SwiftUI lays out on the main
        // thread; the assumption is asserted, not assumed, so a violation shows up at once.
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak window] _, change in
            guard let size = change.newValue, size != .zero else { return }
            MainActor.assumeIsolated { window?.setContentSize(size) }
        }
        self.window = window
        return window
    }
}

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

    init(title: String, autosaveName: String, makeView: @escaping () -> AnyView) {
        self.title = title
        self.autosaveName = autosaveName
        self.makeView = makeView
    }

    /// The editor behind "Usage colours…", both the right-click menu's entry and the
    /// popover's gear menu.
    static func colors() -> SettingsWindowController {
        SettingsWindowController(title: "Usage colours", autosaveName: "ColorScaleSettings") {
            AnyView(ColorScaleSettingsView())
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
        let window = PanelWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock icon to bring the window back with, so it stays on top.
        window.level = .floating
        window.center()
        // After center(), so a frame saved from an earlier showing wins over the default spot.
        window.setFrameAutosaveName(autosaveName)
        self.window = window
        return window
    }
}

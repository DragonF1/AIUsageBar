import AppKit
import SwiftUI

/// The floating window every surface (Sessions, Cost, Settings) is built from, so they read as
/// one product: Esc and ⌘W close it (the accessory app has no menu bar to route ⌘W through),
/// and `make` gives every window the same chrome.
final class PanelWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        let isEscape = event.keyCode == 53
        let isCommandW = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "w"
        if isEscape || isCommandW {
            performClose(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Builds a titled, closable panel over `hosting`, with a hidden system title (the in-content
    /// header row is the title now: the popover never had a system title bar, so the windows
    /// match it rather than the other way round) and an explicit opaque background, so every
    /// window is the same colour whether it is key or not and whatever the desktop under it is.
    /// Without this, the default translucent window material dims an inactive window and tints
    /// it with whatever is behind it.
    @MainActor
    static func make(title: String, hosting: NSHostingController<AnyView>, resizable: Bool) -> PanelWindow {
        let window = PanelWindow(contentViewController: hosting)
        window.title = title
        var styleMask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { styleMask.insert(.resizable) }
        window.styleMask = styleMask
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock icon to bring the window back with, so it stays on top.
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        return window
    }
}

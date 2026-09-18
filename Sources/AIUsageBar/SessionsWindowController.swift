import AppKit
import SwiftUI

/// The one sessions window, kept around between showings; refreshes the token store every
/// 15 s while it is on screen (the scanner is incremental, so that is a few file stats).
@MainActor
final class SessionsWindowController {
    private let tokens: TokenStore
    private var window: SessionsWindow?
    private var timer: Timer?

    static let refreshInterval: TimeInterval = 15

    init(tokens: TokenStore) {
        self.tokens = tokens
    }

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        Task { await tokens.refresh(reason: "sessions") }
    }

    private func makeWindow() -> SessionsWindow {
        let view = SessionsView(tokens: tokens,
                                onRefresh: { [weak self] in self?.refresh() },
                                onOpened: { [weak self] in self?.window?.performClose(nil) })
        let hosting = NSHostingController(rootView: view)
        let window = SessionsWindow(contentViewController: hosting)
        window.title = "Claude Code Sessions"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock icon to bring the window back with, so it stays on top.
        window.level = .floating
        window.setContentSize(NSSize(width: 660, height: 380))
        window.center()
        // After center(), so a frame saved from an earlier showing wins over the default spot.
        window.setFrameAutosaveName("SessionsWindow")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
        self.window = window
        return window
    }
}

/// Esc and ⌘W close it; the accessory app has no menu bar to route ⌘W through.
final class SessionsWindow: NSWindow {
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
}

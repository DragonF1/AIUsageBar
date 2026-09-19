import AppKit
import SwiftUI

/// One floating window over a token ledger (the sessions list or a cost report), kept around
/// between showings; refreshes the ledger every 15 s while it is on screen (the scanners are
/// incremental, so that is a few file stats).
@MainActor
final class TokenWindowController {
    private let ledger: any TokenLedger
    private let title: String
    private let size: NSSize
    private let autosaveName: String
    private let makeView: (TokenWindowController) -> AnyView
    private var window: PanelWindow?
    private var timer: Timer?

    static let refreshInterval: TimeInterval = 15

    init(ledger: any TokenLedger, title: String, size: NSSize, autosaveName: String,
         makeView: @escaping (TokenWindowController) -> AnyView)
    {
        self.ledger = ledger
        self.title = title
        self.size = size
        self.autosaveName = autosaveName
        self.makeView = makeView
    }

    /// Every Claude Code session with its tokens and cost, with Show / Resume per row.
    static func sessions(tokens: TokenStore) -> TokenWindowController {
        TokenWindowController(ledger: tokens, title: "Claude Code Sessions",
                              size: NSSize(width: 660, height: 380), autosaveName: "SessionsWindow") { controller in
            AnyView(SessionsView(tokens: tokens,
                                 onRefresh: { [weak controller] in controller?.refresh() },
                                 onOpened: { [weak controller] in controller?.close() }))
        }
    }

    /// Today and the last 30 days, a bar per day, and the split by model, for one ledger.
    /// `autosaveName` keeps each product's window frame apart.
    static func cost(ledger: any TokenLedger, autosaveName: String) -> TokenWindowController {
        TokenWindowController(ledger: ledger, title: "\(ledger.product.name) Cost",
                              size: NSSize(width: 520, height: 520), autosaveName: autosaveName) { controller in
            AnyView(CostView(tokens: ledger, onRefresh: { [weak controller] in controller?.refresh() }))
        }
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

    func close() {
        window?.performClose(nil)
    }

    func refresh() {
        Task { await ledger.refresh(reason: "window") }
    }

    private func makeWindow() -> PanelWindow {
        let hosting = NSHostingController(rootView: makeView(self))
        let window = PanelWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock icon to bring the window back with, so it stays on top.
        window.level = .floating
        window.setContentSize(size)
        window.center()
        // After center(), so a frame saved from an earlier showing wins over the default spot.
        window.setFrameAutosaveName(autosaveName)
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
}

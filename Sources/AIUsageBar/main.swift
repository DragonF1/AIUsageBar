import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private let store = UsageStore()
    private let antigravity = AntigravityStore()
    private let status = StatusStore()
    private let tokens = TokenStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController(store: store, antigravity: antigravity, status: status, tokens: tokens)
        store.start()
        antigravity.start()
        status.start()
        tokens.start()
        // Always a login item; re-registers if it was switched off in System Settings.
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

MainActor.assumeIsolated {
    // Used by scripts/build-app.sh --install to drop the login item at the old path.
    if CommandLine.arguments.contains("--unregister-login") {
        try? SMAppService.mainApp.unregister()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

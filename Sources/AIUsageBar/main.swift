import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private let store = UsageStore()
    private let antigravity = AntigravityStore()
    private let status = StatusStore()
    private let antigravityStatus = StatusStore(client: GoogleStatusClient(), hiddenKey: "antigravityStatusHidden")
    private let tokens = TokenStore()
    private let antigravityTokens = AntigravityTokenStore()
    private let monitor = QuotaMonitor(notifier: UserNotifier(),
                                       thresholds: AppConfig.loadSettings().notificationThresholds)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.monitor = monitor
        antigravity.monitor = monitor
        controller = StatusItemController(store: store, antigravity: antigravity, status: status,
                                          antigravityStatus: antigravityStatus, tokens: tokens, antigravityTokens: antigravityTokens, monitor: monitor)
        store.start()
        antigravity.start()
        status.start()
        antigravityStatus.start()
        tokens.start()
        antigravityTokens.start()
        // The login item follows the menu switch (on by default); re-registers if it was
        // switched off in System Settings while the switch stayed on.
        LoginItem.apply(Preferences.startAtLogin)
        if Preferences.notifications { monitor.notifier.requestAuthorization() }
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

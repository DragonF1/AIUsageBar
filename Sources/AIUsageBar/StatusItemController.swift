import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let antigravity: AntigravityStore
    private let status: StatusStore
    private let antigravityStatus: StatusStore
    private let tokens: TokenStore
    private let antigravityTokens: AntigravityTokenStore
    private let monitor: QuotaMonitor
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let sessionsWindow: TokenWindowController
    private let costWindow: TokenWindowController
    private let antigravityCostWindow: TokenWindowController
    private var observation: Task<Void, Never>?
    private var outsideClickMonitor: Any?

    init(store: UsageStore, antigravity: AntigravityStore, status: StatusStore, antigravityStatus: StatusStore,
         tokens: TokenStore, antigravityTokens: AntigravityTokenStore, monitor: QuotaMonitor)
    {
        self.store = store
        self.antigravity = antigravity
        self.status = status
        self.antigravityStatus = antigravityStatus
        self.tokens = tokens
        self.antigravityTokens = antigravityTokens
        self.monitor = monitor
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        sessionsWindow = .sessions(tokens: tokens)
        costWindow = .cost(ledger: tokens, autosaveName: "CostWindow")
        antigravityCostWindow = .cost(ledger: antigravityTokens, autosaveName: "AntigravityCostWindow")
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: PopoverView(store: store, antigravity: antigravity, status: status,
                                                                antigravityStatus: antigravityStatus, tokens: tokens, antigravityTokens: antigravityTokens,
                                                                monitor: monitor,
                                                                onShowSessions: { [weak self] in self?.showSessions() },
                                                                onShowCost: { [weak self] in self?.costWindow.show() },
                                                                onShowAntigravityCost: { [weak self] in self?.antigravityCostWindow.show() },
                                                                onQuit: { NSApp.terminate(nil) }))
        // Content grows when the status banner or rows arrive after the popover is open;
        // publishing the fitting size lets NSPopover resize instead of clipping the top.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeStore()
        // The tab picker and the menu's tint switch write UserDefaults; the menu bar follows both.
        NotificationCenter.default.addObserver(self, selector: #selector(render),
                                               name: UserDefaults.didChangeNotification, object: nil)
        render()
    }

    private func observeStore() {
        // Re-render whenever the observable fields the title depends on change.
        observation = Task { [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.store.usage
                        _ = self.store.state
                        _ = self.antigravity.usage
                        _ = self.antigravity.state
                    } onChange: {
                        cont.resume()
                    }
                }
                self.render()
            }
        }
    }

    @objc private func render() {
        guard let button = item.button else { return }
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }
        // Claude tab: "8% / 32%" = 5-hour session / weekly all models.
        // Antigravity tab: "8% / 52%" = Gemini 5-hour / Gemini weekly. Claude and GPT limits
        // live in the popover only.
        // Leading space pads the gap between the icon and the numbers.
        let tab = UsageTab.current
        let metric = Preferences.menuBarMetric
        let text: String
        let tint: UsageColor.Icon?
        let stale: Bool
        switch tab {
        case .claude:
            text = " \(pct(store.sessionPercent)) / \(pct(store.weeklyPercent))"
            tint = UsageColor.icon(session: store.sessionPercent, weekly: store.weeklyPercent, metric: metric)
            stale = store.isStale || tint == nil
        case .antigravity:
            text = " \(pct(antigravity.geminiSessionPercent)) / \(pct(antigravity.geminiWeeklyPercent))"
            tint = UsageColor.icon(session: antigravity.geminiSessionPercent, weekly: antigravity.geminiWeeklyPercent,
                                   metric: metric)
            stale = antigravity.isStale || tint == nil
        }
        let color: NSColor
        switch stale ? nil : tint {
        case nil: color = .secondaryLabelColor
        case .green: color = .systemGreen
        case .yellow: color = .systemYellow
        case .red: color = .systemRed
        case .lightRed: color = Self.lightRed
        case .darkRed: color = Self.darkRed
        }
        // Text stays the menu bar's label color; only the icon carries the usage color.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .font: font,
        ])
        button.image = tab == .claude ? ClaudeIcon.image(color: color) : AntigravityIcon.image(color: color)
        button.imagePosition = .imageLeading
        button.toolTip = tooltip(for: tab)
    }

    // Weekly-window reds, either side of systemRed so the three stay tellable apart.
    private static let lightRed = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.5, alpha: 1)
    private static let darkRed = NSColor(srgbRed: 0.62, green: 0.05, blue: 0.09, alpha: 1)

    private func tooltip(for tab: UsageTab) -> String {
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }
        switch tab {
        case .claude:
            let rows = (store.usage?.displayLimits ?? []).map { "\($0.title): \(pct($0.percent))" }
            return rows.isEmpty ? "Claude usage" : rows.joined(separator: "\n")
        case .antigravity:
            guard let usage = antigravity.usage, !usage.groups.isEmpty else { return "Antigravity usage" }
            return usage.groups.map { group in
                let buckets = group.buckets.map { "\($0.window == "5h" ? "5h" : "weekly") \(pct($0.percentUsed))" }
                return "\(group.title): " + buckets.joined(separator: ", ")
            }.joined(separator: "\n")
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            store.refreshIfStale()
            antigravity.refreshIfStale()
            status.refreshIfStale()
            antigravityStatus.refreshIfStale()
            tokens.refreshIfStale()
            antigravityTokens.refreshIfStale()
            // Accessory apps are rarely "active", so .transient alone does not always
            // dismiss on an outside click; activate and watch for clicks in other apps too.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        }
    }

    private func showSessions() {
        closePopover()
        sessionsWindow.show()
    }

    private func closePopover() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if popover.isShown { popover.performClose(nil) }
    }

    /// Built fresh on every right click so the check marks read the current switches.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())

        let notifications = menu.addItem(withTitle: "Notifications", action: #selector(toggleNotifications), keyEquivalent: "")
        notifications.target = self
        notifications.state = Preferences.notifications ? .on : .off
        notifications.toolTip = "Warns when a window passes \(Self.thresholdText(monitor.thresholds)), is used up, "
            + "resets after a warning, or is on a pace to run out before its reset."

        let login = menu.addItem(withTitle: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        login.target = self
        login.state = Preferences.startAtLogin ? .on : .off

        let tint = NSMenuItem(title: "Menu bar tint", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for metric in MenuBarMetric.allCases {
            let choice = choices.addItem(withTitle: metric.title, action: #selector(pickMetric(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = metric.rawValue
            choice.state = metric == Preferences.menuBarMetric ? .on : .off
        }
        tint.submenu = choices
        menu.addItem(tint)

        menu.addItem(.separator())
        menu.addItem(withTitle: UsagePage.title(for: UsageTab.current), action: #selector(openUsagePage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AI Usage Bar", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil   // so left click keeps going to the popover
    }

    /// "80% or 95%", "90%", or "no threshold" when config.json emptied the list.
    static func thresholdText(_ thresholds: [Double]) -> String {
        let parts = thresholds.map { "\(Int($0))%" }
        switch parts.count {
        case 0: return "no threshold"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " or " + parts.last!
        }
    }

    @objc private func toggleNotifications() {
        Preferences.notifications.toggle()
        if Preferences.notifications { monitor.notifier.requestAuthorization() }
    }

    @objc private func toggleStartAtLogin() {
        Preferences.startAtLogin.toggle()
        LoginItem.apply(Preferences.startAtLogin)
    }

    @objc private func pickMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = MenuBarMetric(rawValue: raw) else { return }
        Preferences.menuBarMetric = metric
    }

    @objc private func refreshNow() {
        Task {
            await store.refresh(reason: "menu")
            await antigravity.refresh(reason: "menu")
            await status.refresh()
            await antigravityStatus.refresh()
            await tokens.refresh(reason: "menu")
            await antigravityTokens.refresh(reason: "menu")
        }
    }

    @objc private func openUsagePage() { UsagePage.open(for: UsageTab.current) }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Claude's starburst mark as an alpha mask (64 px PNG, embedded so the app
/// stays a single binary), tinted in the usage color. Purely a glance
/// indicator: green means nowhere near a limit.
enum ClaudeIcon {
    /// The same mark as a template image, for controls that tint their own images (the
    /// popover's provider switch draws it in the label colour, inverted on the selected segment).
    static let template = TintedMark.template(mask)

    private static let maskPNG = Data(base64Encoded: "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")!
    private static let mask = NSImage(data: maskPNG)!

    static func image(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Antigravity's arch mark as an alpha mask (64 px PNG, derived from the app's icon),
/// tinted the same way as `ClaudeIcon`.
enum AntigravityIcon {
    static let template = TintedMark.template(mask)

    private static let maskPNG = Data(base64Encoded: "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")!
    private static let mask = NSImage(data: maskPNG)!

    static func image(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Draws a 64 px alpha mask at a control size. `template` leaves the tinting to AppKit.
enum TintedMark {
    static let templateSize = NSSize(width: 14, height: 14)

    static func template(_ mask: NSImage) -> NSImage {
        let img = NSImage(size: templateSize, flipped: false) { rect in
            mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSColor.black.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = true
        return img
    }
}

import AppKit
import SwiftUI

// MARK: - Entry

/// `AIUsageBar --render <dir> [--appearance light|dark]`: draws every surface the README shows
/// from synthetic numbers and writes 2x PNGs into `dir`. Nothing is read from the Keychain,
/// the transcripts or the network, and nothing is written to the app's caches or defaults,
/// so the pictures never carry a real plan, spend, folder or account. One process renders
/// one appearance: AppKit resolves colours against the appearance a view was first drawn
/// under, so switching mid-process leaves stale fills behind.
@MainActor
enum ScreenshotRenderer {
    struct Options: Equatable {
        var directory: URL
        var appearance: NSAppearance.Name

        var suffix: String { appearance == .darkAqua ? "dark" : "light" }
    }

    enum RenderError: LocalizedError {
        case usage
        case appearance(String)
        case encode(String)

        var errorDescription: String? {
            switch self {
            case .usage: return "usage: AIUsageBar --render <dir> [--appearance light|dark]"
            case .appearance(let name): return "unknown appearance \(name); use light or dark"
            case .encode(let name): return "could not encode \(name).png"
            }
        }
    }

    /// nil when `--render` is absent; throws when it is present but malformed.
    static func options(from arguments: [String]) throws -> Options? {
        guard let flag = arguments.firstIndex(of: "--render") else { return nil }
        guard flag + 1 < arguments.count else { throw RenderError.usage }
        var appearance = NSAppearance.Name.aqua
        if let a = arguments.firstIndex(of: "--appearance") {
            guard a + 1 < arguments.count else { throw RenderError.usage }
            switch arguments[a + 1] {
            case "light": appearance = .aqua
            case "dark": appearance = .darkAqua
            case let other: throw RenderError.appearance(other)
            }
        }
        return Options(directory: URL(fileURLWithPath: arguments[flag + 1]), appearance: appearance)
    }

    /// Pixels per point in the PNGs.
    static let scale: CGFloat = 2
    /// Window corners on macOS 26; the popover's are a touch tighter.
    static let windowRadius: CGFloat = 11
    static let popoverRadius: CGFloat = 10
    /// The reveal spring on the popover and the windows' first layout pass.
    static let settle: Duration = .milliseconds(800)

    static func run(_ options: Options) async throws {
        let appearance = NSAppearance(named: options.appearance)!
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)

        let fixture = ScreenshotFixture(now: Date())
        let stores = await Stores(fixture)
        var written: [String] = []
        func write(_ rep: NSBitmapImageRep, _ name: String) throws {
            let file = "\(name)-\(options.suffix)"
            guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.encode(file) }
            try png.write(to: options.directory.appendingPathComponent(file + ".png"), options: .atomic)
            written.append(file)
        }

        // The Antigravity tab draws the same surfaces with its own numbers, so the README shows
        // Claude Code only.
        let tab = UsageTab.claude
        installDefaults(tab: tab)
        try write(menuBar(stores, tab: tab, clock: fixture.clock, appearance: appearance), "menubar-\(tab.rawValue)")
        try write(try await popover(stores, appearance: appearance), "popover-\(tab.rawValue)")
        try write(try await window(AnyView(SessionsView(tokens: stores.tokens, onRefresh: {}, onOpened: {})),
                                   title: "Claude Code Sessions", size: NSSize(width: 660, height: 380),
                                   appearance: appearance), "sessions")
        try write(try await window(AnyView(CostView(tokens: stores.tokens, onRefresh: {})),
                                   title: "\(TokenProduct.claudeCode.name) Cost", size: NSSize(width: 520, height: 520),
                                   appearance: appearance), "cost-claude")
        for file in written { print(file + ".png") }
    }

    /// The defaults the views read, pinned for the run: the tab, every switch, blue accent
    /// instead of whatever the Mac is set to. The argument domain is volatile and searched
    /// first, so the app's real preferences are neither read nor touched.
    static func installDefaults(tab: UsageTab) {
        UserDefaults.standard.setVolatileDomain([
            UsageTab.key: tab.rawValue,
            "statusHidden": false,
            "antigravityStatusHidden": false,
            Preferences.Key.costRange: CostRange.month.rawValue,
            Preferences.Key.extraUsage: true,
            Preferences.Key.notifications: true,
            Preferences.Key.startAtLogin: false,
            Preferences.Key.menuBarMetric: MenuBarMetric.auto.rawValue,
            Preferences.Key.colorScale: ColorScale.defaultData,
            Preferences.Key.showRemaining: false,
            "AppleAccentColor": 4,
            "AppleHighlightColor": "0.698039 0.843137 1.000000 Blue",
        ], forName: UserDefaults.argumentDomain)
    }

    // MARK: - Stores

    /// The app's stores, fed the fixture instead of the Keychain, the network and the transcripts.
    @MainActor
    struct Stores {
        let usage: UsageStore
        let antigravity: AntigravityStore
        let status: StatusStore
        let antigravityStatus: StatusStore
        let tokens: TokenStore
        let antigravityTokens: AntigravityTokenStore
        let monitor: QuotaMonitor

        init(_ fixture: ScreenshotFixture) async {
            monitor = QuotaMonitor(notifier: SilentNotifier(), cacheURL: nil)
            usage = UsageStore(cacheURL: nil)
            usage.monitor = monitor
            antigravity = AntigravityStore(cacheURL: nil)
            antigravity.monitor = monitor
            // Earlier samples first, so the pace tracker has a slope to forecast from.
            for sample in fixture.claudeSamples { usage.adopt(sample.response, plan: fixture.plan, at: sample.at) }
            for sample in fixture.antigravitySamples { antigravity.adopt(sample.usage, at: sample.at) }
            status = StatusStore(client: FixtureStatusFeed(pageURL: StatusClient.pageURL, summary: fixture.claudeStatus))
            antigravityStatus = StatusStore(client: FixtureStatusFeed(pageURL: GoogleStatusClient.pageURL,
                                                                      summary: fixture.googleStatus),
                                            hiddenKey: "antigravityStatusHidden")
            await status.refresh()
            await antigravityStatus.refresh()
            tokens = TokenStore()
            tokens.adopt(records: fixture.claudeRecords, sessions: fixture.claudeSessions, live: fixture.claudeLive, at: fixture.now)
            antigravityTokens = AntigravityTokenStore()
            antigravityTokens.adopt(records: fixture.antigravityRecords, at: fixture.now)
        }
    }

    // MARK: - Surfaces

    /// The status item with a neighbour either side, on a menu-bar-coloured strip.
    static func menuBar(_ s: Stores, tab: UsageTab, clock: String, appearance: NSAppearance) -> NSBitmapImageRep {
        let title: MenuBarTitle
        switch tab {
        case .claude:
            title = MenuBarTitle(tab: tab, session: s.usage.sessionPercent, weekly: s.usage.weeklyPercent,
                                 isStale: s.usage.isStale, metric: .auto)
        case .antigravity:
            title = MenuBarTitle(tab: tab, session: s.antigravity.geminiSessionPercent,
                                 weekly: s.antigravity.geminiWeeklyPercent, isStale: s.antigravity.isStale, metric: .auto)
        }
        let height: CGFloat = 24
        let pad: CGFloat = 10
        let gap: CGFloat = 14
        let wifi = symbol("wifi", pointSize: 13)
        let battery = symbol("battery.75percent", pointSize: 13)
        let text = title.attributedText
        let clock = NSAttributedString(string: clock, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let icon = title.image
        let width = pad + wifi.size.width + gap + battery.size.width + gap
            + icon.size.width + text.size().width + gap + clock.size().width + pad
        let bounds = NSRect(x: 0, y: 0, width: ceil(width), height: height)
        return draw(bounds, appearance: appearance) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            (appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            path.fill()
            var x = pad
            func place(_ image: NSImage) {
                image.draw(in: NSRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                x += image.size.width
            }
            func place(_ string: NSAttributedString) {
                let size = string.size()
                string.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += size.width
            }
            place(wifi); x += gap
            place(battery); x += gap
            place(icon); place(text); x += gap
            place(clock)
        }
    }

    /// The popover's content over a solid rounded background. NSPopover's own frame is a
    /// vibrancy material that renders as garbage off screen (a white slab under dark-mode text),
    /// so the view is hosted in a plain borderless window instead and only its content is captured.
    static func popover(_ s: Stores, appearance: NSAppearance) async throws -> NSBitmapImageRep {
        let view = PopoverView(store: s.usage, antigravity: s.antigravity, status: s.status,
                               antigravityStatus: s.antigravityStatus, tokens: s.tokens,
                               antigravityTokens: s.antigravityTokens, monitor: s.monitor,
                               onShowSessions: {}, onShowCost: {}, onShowAntigravityCost: {}, onShowAppearance: {}, onQuit: {})
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        // Key, like the real popover: an inactive window draws the progress bars grey.
        let window = KeyableWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.appearance = appearance
        window.level = .floating
        // Under the menu bar's right end, where the status item's popover hangs.
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 340, y: screen.visibleFrame.maxY - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: settle)
        // The view is 300 pt wide and hugs its height; the window follows once SwiftUI has laid out.
        window.setContentSize(hosting.view.fittingSize)
        try await Task.sleep(for: settle)
        // The frame view paints the window colour under the content, resolved for the window's
        // own appearance; painting it here resolves against the Mac's.
        let rep = capture(window.contentView!.superview!, radius: popoverRadius, appearance: appearance,
                          background: nil, border: true)
        window.orderOut(nil)
        return rep
    }

    /// Borderless windows refuse key status by default.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// A titled window like `TokenWindowController` makes, without the frame autosave.
    static func window(_ view: AnyView, title: String, size: NSSize, appearance: NSAppearance) async throws -> NSBitmapImageRep {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(size)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: settle)
        // The theme frame: title bar, traffic lights and content in one view.
        let frame = window.contentView!.superview!
        let rep = capture(frame, radius: windowRadius, appearance: appearance, background: nil, border: false)
        window.orderOut(nil)
        return rep
    }

    // MARK: - Drawing

    /// Renders a view at `scale` through `cacheDisplay` (no Screen Recording grant needed),
    /// then composites it under a rounded clip with an optional solid background and hairline.
    static func capture(_ view: NSView, radius: CGFloat, appearance: NSAppearance,
                        background: NSColor?, border: Bool) -> NSBitmapImageRep
    {
        let bounds = view.bounds
        let raw = bitmap(bounds.size)
        view.cacheDisplay(in: bounds, to: raw)
        return draw(bounds, appearance: appearance) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            path.addClip()
            if let background {
                background.setFill()
                path.fill()
            }
            raw.draw(in: bounds)
            if border {
                let inset = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                inset.lineWidth = 1
                NSColor.separatorColor.setStroke()
                inset.stroke()
            }
        }
    }

    /// A transparent bitmap of `bounds` at `scale`, drawn into under `appearance` so dynamic
    /// colours resolve for the run's mode rather than the Mac's.
    static func draw(_ bounds: NSRect, appearance: NSAppearance, _ body: () -> Void) -> NSBitmapImageRep {
        let rep = bitmap(bounds.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance(body)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func bitmap(_ size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    /// An SF Symbol rasterised in the label colour, the way the menu bar's own items look.
    static func symbol(_ name: String, pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let template = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        let image = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Fixture doubles

/// Hands back one summary every time; the status cards read it like a live feed.
struct FixtureStatusFeed: StatusFeed {
    var pageURL: URL
    var summary: StatusSummary
    func fetch() async throws -> StatusSummary { summary }
}

/// The monitor still tracks pace off the fixture samples; it just has nowhere to post.
final class SilentNotifier: Notifier {
    func requestAuthorization() {}
    func post(_ notification: QuotaNotification) {}
}

// MARK: - Fixture

/// Every number in the screenshots, relative to `now` so reset times and the day chart read
/// naturally whenever they are rendered. Deterministic: the same `now` gives the same picture.
struct ScreenshotFixture {
    var now: Date
    /// Folders the sessions "ran in", under the renderer's home; the Sessions window shows `~/...`.
    var home: String = NSHomeDirectory()

    let plan = "max"
    let tier = "Google AI Pro"

    static let projects = ["aurora-web", "ledger-api", "notes-cli", "design-system", "dotfiles"]

    /// The menu bar clock, so the strip agrees with the popover's "Updated" time.
    var clock: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE MMM d  h:mm a"
        return f.string(from: now)
    }

    private var calendar: Calendar { .current }
    private var todayStart: Date { calendar.startOfDay(for: now) }
    private func day(_ daysAgo: Int) -> Date { calendar.date(byAdding: .day, value: -daysAgo, to: todayStart)! }

    // MARK: Claude usage

    /// Three polls: three hours ago, 45 minutes ago and now, rising so both windows forecast.
    /// The rows land one per colour band (green, yellow, red) so the screenshots show
    /// the scale.
    var claudeSamples: [(at: Date, response: UsageResponse)] {
        [(now.addingTimeInterval(-3 * 3600), claudeUsage(session: 18, weekly: 75, opus: 86)),
         (now.addingTimeInterval(-45 * 60), claudeUsage(session: 29, weekly: 77, opus: 86.4)),
         (now, claudeUsage(session: 34, weekly: 78, opus: 87))]
    }

    var claudeUsage: UsageResponse { claudeSamples.last!.response }

    private func claudeUsage(session: Double, weekly: Double, opus: Double) -> UsageResponse {
        let sessionReset = now.addingTimeInterval(2 * 3600 + 10 * 60)
        let weeklyReset = now.addingTimeInterval(3 * 86400 + 5 * 3600)
        func limit(_ kind: String, _ group: String, _ percent: Double, _ reset: Date, model: String? = nil) -> UsageResponse.Limit {
            var limit = UsageResponse.Limit(kind: kind, group: group, percent: percent, resetsAt: reset, isActive: true)
            limit.severity = percent >= 95 ? "critical" : percent >= 80 ? "warning" : "normal"
            if let model {
                limit.scope = .init(model: .init(id: "claude-\(model.lowercased())-5", displayName: model))
            }
            return limit
        }
        return UsageResponse(limits: [
            limit("session", "session", session, sessionReset),
            limit("weekly_all", "weekly", weekly, weeklyReset),
            limit("weekly_scoped", "weekly", opus, weeklyReset, model: "Opus"),
        ], extraUsage: .init(isEnabled: true, utilization: 24.8, usedCredits: 1240, monthlyLimit: 5000,
                             currency: "USD", decimalPlaces: 2))
    }

    // MARK: Antigravity usage

    var antigravitySamples: [(at: Date, usage: AntigravityUsage)] {
        [(now.addingTimeInterval(-3 * 3600), antigravityUsage(gemini5h: 0.97, geminiWeekly: 0.695, otherWeekly: 0.35)),
         (now.addingTimeInterval(-45 * 60), antigravityUsage(gemini5h: 0.91, geminiWeekly: 0.692, otherWeekly: 0.335)),
         (now, antigravityUsage(gemini5h: 0.88, geminiWeekly: 0.69, otherWeekly: 0.33))]
    }

    var antigravityUsage: AntigravityUsage { antigravitySamples.last!.usage }

    private func antigravityUsage(gemini5h: Double, geminiWeekly: Double, otherWeekly: Double) -> AntigravityUsage {
        let fiveHourReset = now.addingTimeInterval(1 * 3600 + 50 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 2 * 3600)
        func bucket(_ id: String, window: String, remaining: Double) -> AntigravityQuotaSummary.Bucket {
            let weekly = window == "weekly"
            return .init(bucketId: id,
                         displayName: weekly ? "Weekly Limit Remaining" : "Five Hour Limit Remaining",
                         window: window,
                         resetTime: weekly ? weeklyReset : fiveHourReset,
                         description: weekly && remaining < 1
                             ? "You have used some of your weekly limit, it will fully refresh in 4 days, 2 hours." : nil,
                         remainingFraction: remaining)
        }
        let summary = AntigravityQuotaSummary(groups: [
            .init(displayName: "Gemini Models", description: "Models within this group: Gemini Flash, Gemini Pro",
                  buckets: [bucket("gemini-weekly", window: "weekly", remaining: geminiWeekly),
                            bucket("gemini-5h", window: "5h", remaining: gemini5h)]),
            .init(displayName: "Claude and GPT models", description: "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                  buckets: [bucket("3p-weekly", window: "weekly", remaining: otherWeekly),
                            bucket("3p-5h", window: "5h", remaining: 1)]),
        ], description: nil)
        return AntigravityUsage(summary: summary, tier: tier, host: AntigravityClient.dailyHost, aiCredits: true)
    }

    // MARK: Status

    /// status.claude.com's components as they stand, all operational.
    var claudeStatus: StatusSummary {
        let names = ["claude.ai", "Claude Console (platform.claude.com)", "Claude API (api.anthropic.com)",
                     "Claude Code", "Claude Cowork", "Claude for Government"]
        return StatusSummary(status: .init(indicator: "none", description: "All Systems Operational"),
                             components: names.enumerated().map { index, name in
                                 .init(id: "component-\(index)", name: name, status: "operational", position: index, group: false)
                             },
                             incidents: [], scheduledMaintenances: [])
    }

    var googleStatus: StatusSummary { GoogleStatusClient.summary([]) }

    // MARK: Tokens

    /// Session ids for today's rows: two open, two closed earlier today.
    private static let todayIds = ["6c1f0a8e-4b3d-4f2a-9e71-2d5c8a1b0f43", "a94d7c21-58e0-4c6b-b3f9-0e7d2a6c51b8",
                                   "f27b3e9d-1c4a-4d8e-a5b6-7c9e0d2f4a13", "0b5e8d3a-9f21-47c6-8e4d-a1c2b3d4e5f6"]

    var claudeSessions: [SessionMeta] {
        var sessions = todaySessions
        // One or two sessions a day before today, spread over the projects.
        var rng = Seeded(7)
        for daysAgo in 1..<CostReport.dayCount {
            for n in 0..<Self.sessionsPerDay(daysAgo) {
                let project = Self.projects[rng.next(Self.projects.count)]
                let started = day(daysAgo).addingTimeInterval(TimeInterval(9 * 3600 + rng.next(8 * 3600)))
                sessions.append(SessionMeta(sessionId: Self.pastId(daysAgo: daysAgo, n: n),
                                            title: Self.titles[rng.next(Self.titles.count)],
                                            color: Self.colors[rng.next(Self.colors.count)],
                                            cwd: folder(project), gitBranch: "main", slug: nil,
                                            firstSeen: started, lastSeen: started.addingTimeInterval(TimeInterval(1800 + rng.next(3 * 3600)))))
            }
        }
        return sessions
    }

    private var todaySessions: [SessionMeta] {
        let ids = Self.todayIds
        let earliest = todayStart.addingTimeInterval(60)
        func at(_ secondsAgo: TimeInterval) -> Date { max(earliest, now.addingTimeInterval(-secondsAgo)) }
        return [
            SessionMeta(sessionId: ids[0], title: "Fix pagination on the invoices list", lastPrompt: nil, color: "blue",
                        cwd: folder("aurora-web"), gitBranch: "fix/invoice-paging", slug: "invoice-paging",
                        firstSeen: at(100 * 60), lastSeen: at(2 * 60)),
            SessionMeta(sessionId: ids[1], title: "Add OAuth refresh to the API client", lastPrompt: nil, color: "green",
                        cwd: folder("ledger-api"), gitBranch: "feat/oauth-refresh", slug: "oauth-refresh",
                        firstSeen: at(3 * 3600), lastSeen: at(25 * 60)),
            SessionMeta(sessionId: ids[2], title: "Rename the config flags", lastPrompt: nil, color: "orange",
                        cwd: folder("notes-cli"), gitBranch: "main", slug: "config-flags",
                        firstSeen: at(4 * 3600), lastSeen: at(50 * 60)),
            SessionMeta(sessionId: ids[3], title: "Tidy the zsh prompt", lastPrompt: nil, color: "purple",
                        cwd: folder("dotfiles"), gitBranch: "main", slug: "zsh-prompt",
                        firstSeen: at(5 * 3600), lastSeen: at(2 * 3600)),
        ]
    }

    var claudeLive: [LiveSession] {
        let ids = Self.todayIds
        func live(_ id: String, pid: Int32, busy: Bool, ago: TimeInterval, project: String) -> LiveSession {
            LiveSession(pid: pid, sessionId: id, cwd: folder(project),
                        startedAt: now.addingTimeInterval(-ago).timeIntervalSince1970 * 1000, kind: "interactive",
                        status: busy ? "busy" : "idle", name: nil, nameSource: nil, version: "2.1.277",
                        updatedAt: now.timeIntervalSince1970 * 1000)
        }
        return [live(ids[0], pid: 41231, busy: true, ago: 100 * 60, project: "aurora-web"),
                live(ids[1], pid: 41877, busy: false, ago: 3 * 3600, project: "ledger-api")]
    }

    /// Thirty days of Claude Code answers: lighter at weekends, Opus most of the time.
    var claudeRecords: [TokenRecord] {
        var rng = Seeded(11)
        var records: [TokenRecord] = []
        for daysAgo in (0..<CostReport.dayCount).reversed() {
            let weekend = calendar.isDateInWeekend(day(daysAgo))
            let count = weekend ? 6 + rng.next(8) : 18 + rng.next(20)
            for i in 0..<count {
                let roll = rng.next(10)
                let model = roll < 6 ? "claude-opus-5" : roll < 9 ? "claude-sonnet-5" : "claude-haiku-4-5-20251001"
                let session = daysAgo == 0 ? Self.todayIds[rng.next(Self.todayIds.count)]
                    : Self.pastId(daysAgo: daysAgo, n: rng.next(Self.sessionsPerDay(daysAgo)))
                records.append(TokenRecord(timestamp: stamp(daysAgo: daysAgo, index: i, of: count, rng: &rng),
                                           model: model,
                                           input: 800 + rng.next(3000), output: 200 + rng.next(2200),
                                           cacheWrite5m: 4000 + rng.next(30000),
                                           cacheWrite1h: rng.next(7) == 0 ? 8000 + rng.next(12000) : 0,
                                           cacheRead: 30000 + rng.next(350000),
                                           sessionId: session))
            }
        }
        return records
    }

    /// Thirty days of Antigravity generations: Pro and Flash, no cache writes (it reports none).
    var antigravityRecords: [TokenRecord] {
        var rng = Seeded(23)
        var records: [TokenRecord] = []
        for daysAgo in (0..<CostReport.dayCount).reversed() {
            let count = calendar.isDateInWeekend(day(daysAgo)) ? 2 + rng.next(6) : 8 + rng.next(22)
            for i in 0..<count {
                let pro = rng.next(100) < 55
                records.append(TokenRecord(timestamp: stamp(daysAgo: daysAgo, index: i, of: count, rng: &rng),
                                           model: pro ? "gemini-3.1-pro" : "gemini-3.8-flash",
                                           input: 3000 + rng.next(17000), output: 400 + rng.next(2600),
                                           cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: rng.next(100000),
                                           sessionId: nil))
            }
        }
        return records
    }

    // MARK: helpers

    private static let colors = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"]
    private static let titles = ["Migrate the build to Swift 6", "Write the release notes", "Trace the flaky login test",
                                 "Split the settings screen", "Add a dark mode audit", "Speed up the CSV import",
                                 "Refactor the router", "Document the CLI flags", "Fix the timezone bug", "Draft the API changelog"]

    private func folder(_ project: String) -> String { home + "/Code/" + project }

    /// One or two sessions a day before today, so every record has a folder to land in.
    private static func sessionsPerDay(_ daysAgo: Int) -> Int { daysAgo % 3 == 0 ? 1 : 2 }

    /// Past sessions get a stable synthetic id from their day and slot.
    private static func pastId(daysAgo: Int, n: Int) -> String {
        String(format: "%08x-%04x-4%03x-8%03x-%012x", 0x5a3c_1e00 + daysAgo, 0x2b00 + n, daysAgo * 7 + n, daysAgo * 3 + n,
               0x9e1d_0000_0000 + daysAgo * 977 + n)
    }

    /// Spread `count` answers across the working day, and across today up to `now`.
    private func stamp(daysAgo: Int, index: Int, of count: Int, rng: inout Seeded) -> Date {
        let start = day(daysAgo).addingTimeInterval(9 * 3600)
        let span: TimeInterval = daysAgo == 0 ? max(600, now.timeIntervalSince(start)) : 10 * 3600
        let t = start.addingTimeInterval(span * Double(index) / Double(count) + TimeInterval(rng.next(300)))
        return min(t, now)
    }
}

/// A tiny linear congruential generator, so the fixture is the same on every run.
struct Seeded {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    /// 0 ..< bound
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }
}

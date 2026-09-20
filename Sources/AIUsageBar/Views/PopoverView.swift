import SwiftUI

struct PopoverView: View {
    @Bindable var store: UsageStore
    var antigravity: AntigravityStore
    var status: StatusStore
    var antigravityStatus: StatusStore
    var tokens: TokenStore
    var antigravityTokens: AntigravityTokenStore
    var monitor: QuotaMonitor
    var onShowSessions: () -> Void
    var onShowCost: () -> Void
    var onShowAntigravityCost: () -> Void
    var onShowSettings: () -> Void
    var onQuit: () -> Void

    @AppStorage(UsageTab.key) private var tab: UsageTab = .claude
    // Extra usage gates a whole row below, and pace gates a line and a tick on every row; both
    // are read here for that, not for a control on the popover itself (the gear opens Settings
    // for that now).
    @AppStorage(Preferences.Key.extraUsage) private var extraUsage = true
    @AppStorage(Preferences.Key.showPace) private var showPace = true

    @State private var now = Date()
    @State private var revealed = false

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.transaction { $0.animation = nil }
            ProviderPicker(tab: $tab)
                .transaction { $0.animation = nil }
            Divider()
            // Each tab lives on its own side: the left tab slides in and out through the
            // leading edge, the right one through the trailing edge, so switching reads as a carousel.
            content
                .id(tab)
                .transition(.move(edge: tab == .claude ? .leading : .trailing).combined(with: .opacity))
            Divider()
            footer
        }
        .padding(Chrome.inset)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .animation(.spring(duration: 0.32, bounce: 0.12), value: tab)
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed ? 1 : 0.97, anchor: .top)
        .offset(y: revealed ? 0 : -6)
        .onAppear {
            revealed = false
            withAnimation(.spring(duration: 0.28, bounce: 0.15)) { revealed = true }
        }
        .onDisappear { revealed = false }
        .onReceive(tick) { now = $0 }
        // Outermost, so the background is not part of the reveal animation (opacity, scale,
        // offset above) and the popover's body matches the windows' opaque chrome.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .claude:
            VStack(alignment: .leading, spacing: 14) {
                rows
                Divider()
                costSection(tokens,
                            week: TokenWindow.weekStart(resetsAt: store.usage?.weeklyResetsAt, now: now),
                            onShow: onShowCost)
                sessionsButton
                Divider()
                StatusView(status: status, now: now)
            }
        case .antigravity:
            VStack(alignment: .leading, spacing: 14) {
                AntigravityTab(store: antigravity, monitor: monitor, now: now)
                Divider()
                costSection(antigravityTokens,
                            week: TokenWindow.weekStart(resetsAt: antigravityWeeklyReset, now: now),
                            onShow: onShowAntigravityCost)
                Divider()
                StatusView(status: antigravityStatus, now: now)
            }
        }
    }

    /// The Gemini group's weekly reset, so the Antigravity week lines up with its own limit.
    private var antigravityWeeklyReset: Date? {
        antigravity.usage?.gemini?.buckets.first { $0.window == "weekly" }?.resetsAt
    }

    private var header: some View {
        SurfaceHeader(title: tab == .claude ? "Claude Usage" : "Antigravity Usage", subtitle: subtitle) {
            if let plan = badge {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            usagePageButton
            settingsButton
        }
    }

    private var badge: String? {
        switch tab {
        case .claude: return store.subscriptionType?.capitalized
        case .antigravity: return antigravity.usage?.tier
        }
    }

    private var subtitle: String {
        let (state, updated) = tab == .claude ? (store.state, store.lastUpdated)
                                              : (antigravity.state, antigravity.lastUpdated)
        switch state {
        case .loading: return "Loading…"
        case .ok: return updated.map { "Updated \(UsageStore.timeFormatter.string(from: $0))" } ?? "Updated"
        case .stale(let why): return "Stale: \(why)"
        case .error(let why): return why
        }
    }

    @ViewBuilder private var rows: some View {
        let limits = store.usage?.displayLimits ?? []
        if limits.isEmpty {
            Text(emptyText).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 12) {
                ForEach(limits) { limit in
                    let reading = QuotaReading.claude(limit)
                    LimitRow(title: limit.title,
                             percent: limit.percent,
                             detail: ResetText.describe(limit.resetsAt, window: limit.kind == "session" ? .fiveHour : .other, now: now),
                             pace: PaceLine.shown(reading.flatMap { monitor.paceLine(for: $0.id, window: $0.window, now: now) },
                                                  enabled: showPace),
                             dimmed: store.isStale)
                }
                // Always drawn while the switch is on: an account without extra usage gets an
                // empty bar and a note rather than a row that comes and goes.
                if extraUsage {
                    let extra = store.usage?.extraUsage
                    let active = extra?.isActive ?? false
                    LimitRow(title: "Extra usage",
                             percent: active ? extra?.percent : nil,
                             detail: active ? extra?.detailText : "Not enabled on this account",
                             dimmed: store.isStale)
                }
            }
        }
    }

    private var emptyText: String {
        if case .error(let why) = store.state { return why }
        return "No usage data yet."
    }

    /// Today, this week and the last 30 days from one ledger's local data, under a header that
    /// opens its cost window. The week aligns to the product's weekly reset when its usage
    /// endpoint has told us when that is.
    private func costSection(_ ledger: any TokenLedger, week: (start: Date, aligned: Bool),
                             onShow: @escaping () -> Void) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            costButton(onShow: onShow)
            if ledger.lastScanned == nil {
                Text(ledger.error ?? ledger.product.scanning).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    TokenRow(title: "Today",
                             totals: ledger.totals(since: TokenWindow.todayStart(now: now)),
                             detail: "Since midnight",
                             dimmed: ledger.error != nil)
                    TokenRow(title: "This week",
                             totals: ledger.totals(since: week.start),
                             detail: week.aligned
                                 ? "Since \(week.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                                 : "Rolling 7 days",
                             dimmed: ledger.error != nil)
                    TokenRow(title: "Last \(CostReport.dayCount) days",
                             totals: ledger.totals(since: TokenStore.costWindowStart(now: now)),
                             detail: "\(CostReport.dayCount) calendar days, today included",
                             dimmed: ledger.error != nil)
                }
            }
        }
    }

    /// Header line of the cost section; opens the cost window with the daily chart.
    private func costButton(onShow: @escaping () -> Void) -> some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Text("Cost").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cost")
        .help("Open a window with a bar per day for the last 7, 30 or 90 days and the split by model")
    }

    /// One line that opens the sessions window; the counts come from Claude Code's session registry.
    private var sessionsButton: some View {
        Button(action: onShowSessions) {
            HStack(spacing: 6) {
                Text("Sessions").font(.headline)
                Spacer()
                Text(sessionsSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sessions")
        .help("Open a window listing every Claude Code session with its tokens and estimated cost")
    }

    private var sessionsSummary: String {
        guard tokens.lastScanned != nil else { return "–" }
        let open = "\(tokens.openCount) open"
        return tokens.busyCount > 0 ? "\(open) · \(tokens.busyCount) busy" : open
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task {
                    await store.refresh(reason: "manual")
                    await antigravity.refresh(reason: "manual")
                    await status.refresh()
                    await antigravityStatus.refresh()
                    await tokens.refresh(reason: "manual")
                    await antigravityTokens.refresh(reason: "manual")
                }
            }
            Spacer()
            Button("Quit", action: onQuit)
        }
        .controlSize(.small)
    }

    /// The tab's web page ("Usage on claude.ai", "Plan on Google One"), the same link the
    /// right-click menu ends with; it sat in the gear's dropdown before that became a window.
    private var usagePageButton: some View {
        Button { UsagePage.open(for: tab) } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(UsagePage.title(for: tab))
    }

    /// Opens the Settings window. The gear used to hold a dropdown of switches; those now live
    /// in Settings, so the popover carries only the door to it.
    private var settingsButton: some View {
        Button(action: onShowSettings) {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open Settings: notifications, start at login, extra usage credits, "
              + "show remaining, pace forecast, menu bar tint, menu bar text and colours.")
    }
}

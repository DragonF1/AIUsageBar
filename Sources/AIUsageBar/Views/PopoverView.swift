import SwiftUI

struct PopoverView: View {
    @Bindable var store: UsageStore
    var antigravity: AntigravityStore
    var status: StatusStore
    var tokens: TokenStore
    var antigravityTokens: AntigravityTokenStore
    var monitor: QuotaMonitor
    var onShowSessions: () -> Void
    var onShowCost: () -> Void
    var onShowAntigravityCost: () -> Void
    var onQuit: () -> Void

    @AppStorage(UsageTab.key) private var tab: UsageTab = .claude
    // The same switches the right-click menu shows, on the popover so nobody has to know about right-click.
    @AppStorage(Preferences.Key.notifications) private var notifications = true
    @AppStorage(Preferences.Key.startAtLogin) private var startAtLogin = true
    @AppStorage(Preferences.Key.menuBarMetric) private var metric: MenuBarMetric = .auto

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
        .padding(16)
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
        .onChange(of: notifications) { _, on in
            if on { monitor.notifier.requestAuthorization() }
        }
        .onChange(of: startAtLogin) { _, on in LoginItem.apply(on) }
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
            }
        }
    }

    /// The Gemini group's weekly reset, so the Antigravity week lines up with its own limit.
    private var antigravityWeeklyReset: Date? {
        antigravity.usage?.gemini?.buckets.first { $0.window == "weekly" }?.resetsAt
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab == .claude ? "Claude Usage" : "Antigravity Usage").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let plan = badge {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            settingsMenu
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
                             pace: reading.flatMap { monitor.paceLine(for: $0.id, window: $0.window, now: now) },
                             dimmed: store.isStale)
                }
                if let extra = store.usage?.extraUsage, extra.isEnabled == true {
                    LimitRow(title: "Extra usage",
                             percent: extra.utilization,
                             detail: extraDetail(extra),
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
        .help("Open a window with a bar per day for the last 7, 30 or 90 days and the split by model and project")
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

    private func extraDetail(_ e: UsageResponse.ExtraUsage) -> String? {
        guard let used = e.usedCredits, let limit = e.monthlyLimit else { return nil }
        let places = e.decimalPlaces ?? 2
        let scale = pow(10.0, Double(places))
        let cur = e.currency ?? ""
        return String(format: "%@%.2f of %@%.2f this month", cur, used / scale, cur, limit / scale)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task {
                    await store.refresh(reason: "manual")
                    await antigravity.refresh(reason: "manual")
                    await status.refresh()
                    await tokens.refresh(reason: "manual")
                    await antigravityTokens.refresh(reason: "manual")
                }
            }
            Spacer()
            Button("Quit", action: onQuit)
        }
        .controlSize(.small)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Notifications", isOn: $notifications)
            Toggle("Start at login", isOn: $startAtLogin)
            Picker("Menu bar tint", selection: $metric) {
                ForEach(MenuBarMetric.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notifications warn at \(StatusItemController.thresholdText(monitor.thresholds)), when a window is used up, "
              + "runs out at the current pace, or resets after a warning.")
    }
}

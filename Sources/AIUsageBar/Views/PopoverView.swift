import SwiftUI

struct PopoverView: View {
    @Bindable var store: UsageStore
    var antigravity: AntigravityStore
    var status: StatusStore
    var tokens: TokenStore
    var onShowSessions: () -> Void
    var onQuit: () -> Void

    @AppStorage(UsageTab.key) private var tab: UsageTab = .claude

    @State private var now = Date()
    @State private var revealed = false

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.transaction { $0.animation = nil }
            Picker("Provider", selection: $tab) {
                ForEach(UsageTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .claude:
            VStack(alignment: .leading, spacing: 14) {
                rows
                Divider()
                tokenRows
                sessionsButton
                Divider()
                StatusView(status: status, now: now)
            }
        case .antigravity:
            AntigravityTab(store: antigravity, now: now)
        }
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
                    LimitRow(title: limit.title,
                             percent: limit.percent,
                             detail: ResetText.describe(limit.resetsAt, window: limit.kind == "session" ? .fiveHour : .other, now: now),
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

    /// Today and this week from Claude Code's local transcripts; the week aligns to the API's
    /// weekly reset when the usage endpoint has told us when that is.
    @ViewBuilder private var tokenRows: some View {
        if tokens.lastScanned == nil {
            Text(tokens.error ?? "Scanning Claude Code transcripts…").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let week = TokenWindow.weekStart(resetsAt: store.usage?.weeklyResetsAt, now: now)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                TokenRow(title: "Daily tokens",
                         totals: tokens.totals(since: TokenWindow.todayStart(now: now)),
                         dimmed: tokens.error != nil)
                TokenRow(title: "Weekly tokens",
                         totals: tokens.totals(since: week.start),
                         detail: week.aligned
                             ? "Since \(week.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                             : "Rolling 7 days",
                         dimmed: tokens.error != nil)
            }
        }
    }

    /// One line that opens the sessions window; the counts come from Claude Code's session registry.
    private var sessionsButton: some View {
        Button(action: onShowSessions) {
            HStack(spacing: 6) {
                Text("Sessions").font(.subheadline.weight(.medium))
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
                }
            }
            Spacer()
            Button("Quit", action: onQuit)
        }
        .controlSize(.small)
    }
}

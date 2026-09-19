import SwiftUI

/// The sessions window: every Claude Code session that is open now, then the ones that answered
/// today but whose process is gone, each with its tokens and estimated cost over the retained days.
/// A row's button (or a double-click) raises an open session's Terminal window or resumes a
/// closed one in a new window through the launcher; on success the sessions window closes.
struct SessionsView: View {
    var tokens: TokenStore
    var launcher = SessionLauncher()
    var onRefresh: () -> Void
    var onOpened: () -> Void = {}

    @State private var now = Date()
    @State private var opening: String?
    @State private var notice: String?
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var rows: [SessionRow] {
        tokens.sessionRows(closedSince: TokenWindow.todayStart(now: now))
    }

    var body: some View {
        let rows = rows
        let open = rows.filter(\.isOpen)
        let closed = rows.filter { !$0.isOpen }
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                Spacer()
                Text(tokens.lastScanned == nil ? "Scanning Claude Code transcripts…" : "No Claude Code sessions today.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        if !open.isEmpty {
                            Section { ForEach(open) { rowView($0) } } header: {
                                sectionHeader("Open", count: open.count)
                            }
                        }
                        if !closed.isEmpty {
                            Section { ForEach(closed) { rowView($0) } } header: {
                                sectionHeader("Closed today", count: closed.count)
                            }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 660, minHeight: 240, idealHeight: 380)
        .onReceive(tick) { now = $0 }
        .onAppear { now = Date() }
    }

    private func rowView(_ row: SessionRow) -> some View {
        SessionRowView(row: row, now: now, opening: opening == row.id) { open(row) }
    }

    private func open(_ row: SessionRow) {
        guard opening == nil else { return }
        opening = row.id
        notice = nil
        Task {
            do {
                if row.isOpen { try await launcher.focus(row) } else { try await launcher.resume(row) }
                opening = nil
                onOpened()
                // The launcher's Terminal window registers its session a moment after opening.
                try? await Task.sleep(for: .seconds(3))
                onRefresh()
            } catch {
                opening = nil
                notice = "\(row.isOpen ? "Could not show" : "Could not resume") “\(row.title)”: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code Sessions").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", action: onRefresh).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var summary: String {
        var parts = ["\(tokens.openCount) open"]
        if tokens.busyCount > 0 { parts.append("\(tokens.busyCount) busy") }
        if let scanned = tokens.lastScanned {
            parts.append("updated \(UsageStore.timeFormatter.string(from: scanned))")
        }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
    }

    private var footer: some View {
        Text(notice ?? tokens.error ?? "Tokens and cost are each session's total over the retained \(CostRange.retentionDays) days at list prices. Resume reopens a closed session in a new Terminal window.")
            .font(.caption2).foregroundStyle(notice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Two lines: colour dot, title and numbers; then where it runs and how long it has been going.
struct SessionRowView: View {
    let row: SessionRow
    let now: Date
    var opening = false
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dot).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if row.isOpen { statePill }
                    Text(TokenText.compact(row.totals.tokens))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 52, alignment: .trailing)
                    Text(TokenText.cost(row.totals))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 84, alignment: .trailing)
                    openButton
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .opacity(row.isOpen ? 1 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .help(tooltip)
        Divider().padding(.leading, 35)
    }

    /// "Show" raises the open session's Terminal window; "Resume" is `claude --resume` in a new one.
    private var openButton: some View {
        Button(row.isOpen ? "Show" : "Resume", action: onOpen)
            .controlSize(.small)
            .frame(width: 66)
            .disabled(opening)
            .help(row.isOpen ? "Bring this session's Terminal window to the front"
                             : "Reopen this session in a new Terminal window, like /resume")
    }

    private var statePill: some View {
        Text(row.isBusy ? "Busy" : "Idle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(row.isBusy ? Color.orange : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill((row.isBusy ? Color.orange : Color.secondary).opacity(0.15)))
    }

    private var dot: Color {
        guard row.isOpen || row.meta?.color != nil else { return .secondary.opacity(0.4) }
        return SessionColor.color(named: row.meta?.color)
    }

    private var detail: String {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append(SessionText.folder(cwd)) }
        // Claude Code reports "HEAD" outside a checkout; that is not a branch worth a slot.
        if let branch = row.meta?.gitBranch, !branch.isEmpty, branch != "HEAD" { parts.append(branch) }
        if let started = row.started { parts.append(SessionText.duration(from: started, to: now)) }
        if row.lastActivity != .distantPast {
            parts.append(row.isOpen ? "last answer \(SessionText.ago(row.lastActivity, now: now))"
                                    : "ended \(SessionText.ago(row.lastActivity, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    private var tooltip: String {
        var lines = ["Session \(row.id)"]
        if let pid = row.live?.pid { lines.append("PID \(pid)") }
        if let cwd = row.cwd { lines.append(cwd) }
        if let prompt = row.meta?.lastPrompt, !prompt.isEmpty { lines.append("Last prompt: \(prompt)") }
        lines.append(TokenText.breakdown(row.totals))
        return lines.joined(separator: "\n")
    }
}

/// The launcher's `/color` names as they appear in the transcript's `agent-color` line.
enum SessionColor {
    static func color(named name: String?) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "cyan": return .cyan
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .secondary
        }
    }
}

enum SessionText {
    /// "~/Coding/proj" for a path under the home directory, the last two components otherwise.
    static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// "3m", "2h 14m", "1d 3h".
    static func duration(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "just now", "5m ago", "2h ago", "3d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

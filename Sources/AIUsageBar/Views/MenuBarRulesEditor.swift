import SwiftUI

/// The rules list, the "Otherwise:" fallback field, the token legend and "Add rule", all of
/// `MenuBarFormatSection`'s body below its title and description. Kept as its own view so
/// the rules array's edits (add, remove, reorder, keystrokes) and the fallback field's keystrokes
/// can each debounce on their own, the same way `ColorScaleSettingsView` debounces its own edits.
/// The menu bar itself is the preview: every edit lands there 150ms later.
struct MenuBarRulesEditor: View {
    var usage: UsageStore
    var antigravity: AntigravityStore

    @State private var rules: [MenuBarRule] = Preferences.menuBarRules
    @State private var fallback: String = Preferences.menuBarFormat
    @State private var pendingRulesSave: Task<Void, Never>?
    @State private var pendingFallbackSave: Task<Void, Never>?

    /// A rule's threshold shown as a kind rather than its case, so a picker can switch between
    /// them without the field underneath changing type mid-edit.
    private enum ThresholdKind: String, CaseIterable {
        case percent, band

        var title: String {
            switch self {
            case .percent: return "percent"
            case .band: return "colour band"
            }
        }
    }

    /// A row's "which limit": the active tab (tab-relative, today's behaviour) or one specific
    /// limit family by scope. The scope alone cannot label itself once that limit stops being
    /// reported, so the row looks the name up separately, from the live union or from the rule's
    /// own stored fields.
    private enum MenuBarScopeChoice: Hashable {
        case activeTab
        case limit(String)
    }

    /// Every limit either store currently reports, Claude's first then Antigravity's, read live
    /// so the picker never shows a name that stopped applying.
    private var liveReadings: [QuotaReading] {
        (usage.usage?.readings(extraUsage: Preferences.extraUsage) ?? []) + (antigravity.usage?.readings ?? [])
    }

    /// One entry per distinct scope among `liveReadings`, in first-seen order (Claude's scopes
    /// before Antigravity's, since `liveReadings` is ordered that way): the scope picker's live
    /// choices, each labelled from the first reading that carries it.
    private var liveScopes: [(scope: String, product: String, scopeName: String)] {
        var seen = Set<String>()
        var scopes: [(scope: String, product: String, scopeName: String)] = []
        for reading in liveReadings where !seen.contains(reading.scope) {
            seen.insert(reading.scope)
            scopes.append((reading.scope, reading.product, reading.scopeName))
        }
        return scopes
    }

    private func productShort(_ product: String) -> String {
        product == "Claude Code" ? "Claude" : "Antigravity"
    }

    /// The window choices to offer for a row's window picker: every case for the active tab (no
    /// scope) or for a scope this build is not currently reporting (so a stale rule stays fully
    /// editable), otherwise only the windows that scope's own live readings cover (`.fiveHour`
    /// maps to `.session`, `.weekly` to `.weekly`), in `MenuBarWindow.allCases` order. A scope
    /// whose only reading is `.monthly` (extra usage) covers none of those two, so this comes
    /// back empty and the row hides the window picker rather than show one with nothing in it.
    private func offeredWindows(for scope: String?) -> [MenuBarWindow] {
        guard let scope else { return MenuBarWindow.allCases }
        let scopedReadings = liveReadings.filter { $0.scope == scope }
        guard !scopedReadings.isEmpty else { return MenuBarWindow.allCases }
        let windows = Set(scopedReadings.compactMap { reading -> MenuBarWindow? in
            switch reading.window {
            case .fiveHour: return .session
            case .weekly: return .weekly
            case .monthly: return nil
            }
        })
        return MenuBarWindow.allCases.filter { windows.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !rules.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($rules) { $rule in
                            row($rule)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack(spacing: 6) {
                Text("Otherwise:").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $fallback)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: fallback) { _, newValue in commitFallback(newValue) }
            }

            Text(MenuBarTemplate.tokens.joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Button("Add rule") { addRule() }
        }
        .onChange(of: rules) { _, _ in commitRules() }
        .onDisappear(perform: flush)
    }

    // MARK: - Row

    private func row(_ rule: Binding<MenuBarRule>) -> some View {
        let index = index(of: rule.wrappedValue)
        let scope = rule.wrappedValue.condition.limit?.scope
        let windows = offeredWindows(for: scope)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: scopeBinding(rule)) {
                    Text("Active tab").tag(MenuBarScopeChoice.activeTab)
                    Divider()
                    ForEach(liveScopes, id: \.scope) { entry in
                        Text("\(productShort(entry.product)): \(entry.scopeName)").tag(MenuBarScopeChoice.limit(entry.scope))
                    }
                    if let limit = rule.wrappedValue.condition.limit, !liveScopes.contains(where: { $0.scope == limit.scope }) {
                        Text("\(productShort(limit.product)): \(limit.name) (not reported)").tag(MenuBarScopeChoice.limit(limit.scope))
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()

                // Hidden for a scope with a single, window-less reading (extra usage): there is
                // nothing for this picker to choose between.
                if !windows.isEmpty {
                    Picker("", selection: rule.condition.window) {
                        ForEach(windows, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }

                Picker("", selection: rule.condition.comparison) {
                    ForEach(MenuBarComparison.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            // Which limit and which window are now two separate pickers (the scope picker can
            // read "Antigravity: Claude and GPT" while the window picker says "5-hour" or
            // "Weekly" on its own), plus the comparator; with the threshold kind and a band name
            // after them the condition line would still outgrow the settings window, so the
            // threshold controls open the template line instead, followed by the reorder/remove
            // buttons.
            HStack(spacing: 6) {
                Picker("", selection: kindBinding(rule)) {
                    ForEach(ThresholdKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()

                switch rule.wrappedValue.condition.threshold {
                case .percent:
                    TextField("", value: percentBinding(rule), format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                case .band:
                    Picker("", selection: bandBinding(rule)) {
                        ForEach(UsageColor.Level.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }

                TextField("Template", text: rule.format)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                Button { if let index { moveUp(index) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == nil || index == 0)
                    .accessibilityLabel("Move rule up")
                Button { if let index { moveDown(index) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == nil || index == rules.count - 1)
                    .accessibilityLabel("Move rule down")
                Button { if let index { remove(index) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove rule")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func index(of rule: MenuBarRule) -> Int? {
        rules.firstIndex { $0.id == rule.id }
    }

    /// Get reads `condition.limit` first: a limit rule's `window` stays meaningful (it still
    /// picks the 5-hour or weekly reading, now from that scope instead of from the tab), so it is
    /// never cleared here. Set to `.activeTab` clears `limit` and leaves `window` untouched, so
    /// switching back to a scope later restores whatever window was last chosen; set to a scope
    /// fills `limit` from the first live reading with it and, when the current window is not
    /// among the ones that scope offers, snaps `window` to the first one it does offer, so the
    /// row never lands on a window the new scope has nothing to show for.
    private func scopeBinding(_ rule: Binding<MenuBarRule>) -> Binding<MenuBarScopeChoice> {
        Binding(
            get: {
                if let limit = rule.wrappedValue.condition.limit { return .limit(limit.scope) }
                return .activeTab
            },
            set: { newValue in
                switch newValue {
                case .activeTab:
                    rule.wrappedValue.condition.limit = nil
                case .limit(let scope):
                    guard let entry = liveScopes.first(where: { $0.scope == scope }) else { return }
                    rule.wrappedValue.condition.limit = MenuBarLimitRef(scope: entry.scope, product: entry.product, name: entry.scopeName)
                    let offered = offeredWindows(for: scope)
                    if !offered.isEmpty, !offered.contains(rule.wrappedValue.condition.window) {
                        rule.wrappedValue.condition.window = offered[0]
                    }
                }
            })
    }

    private func kindBinding(_ rule: Binding<MenuBarRule>) -> Binding<ThresholdKind> {
        Binding(
            get: {
                switch rule.wrappedValue.condition.threshold {
                case .percent: return .percent
                case .band: return .band
                }
            },
            set: { newKind in
                switch newKind {
                case .percent: rule.wrappedValue.condition.threshold = Self.defaultPercent
                case .band: rule.wrappedValue.condition.threshold = Self.defaultBand
                }
            })
    }

    /// What a fresh rule, or a rule whose kind just switched, starts at. The percent field
    /// clamps to 0...100 on the way in so a typo cannot make a rule always or never match.
    private static let defaultPercentValue = 80
    private static let defaultBandValue = UsageColor.Level.high
    private static let defaultPercent = MenuBarThreshold.percent(Double(defaultPercentValue))
    private static let defaultBand = MenuBarThreshold.band(defaultBandValue)

    private func percentBinding(_ rule: Binding<MenuBarRule>) -> Binding<Int> {
        Binding(
            get: {
                if case .percent(let n) = rule.wrappedValue.condition.threshold { return Int(n.rounded()) }
                return Self.defaultPercentValue
            },
            set: { newValue in
                rule.wrappedValue.condition.threshold = .percent(Double(min(100, max(0, newValue))))
            })
    }

    private func bandBinding(_ rule: Binding<MenuBarRule>) -> Binding<UsageColor.Level> {
        Binding(
            get: {
                if case .band(let level) = rule.wrappedValue.condition.threshold { return level }
                return Self.defaultBandValue
            },
            set: { newValue in rule.wrappedValue.condition.threshold = .band(newValue) })
    }

    // MARK: - List edits

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        rules.swapAt(index, index - 1)
    }

    private func moveDown(_ index: Int) {
        guard index < rules.count - 1 else { return }
        rules.swapAt(index, index + 1)
    }

    private func remove(_ index: Int) {
        rules.remove(at: index)
    }

    private func addRule() {
        rules.append(MenuBarRule(condition: MenuBarCondition(window: .session, comparison: .atLeast, threshold: Self.defaultPercent),
                                 format: ""))
    }

    // MARK: - Persistence

    /// Same beat as the colour scale editor: publish to the view at once, persist 150ms later
    /// so adding, removing, reordering or typing does not wake the menu bar's redraw per edit.
    private func commitRules() {
        pendingRulesSave?.cancel()
        let snapshot = rules
        pendingRulesSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            Preferences.menuBarRules = snapshot
            pendingRulesSave = nil
        }
    }

    private func commitFallback(_ new: String) {
        pendingFallbackSave?.cancel()
        pendingFallbackSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            Preferences.menuBarFormat = new
            pendingFallbackSave = nil
        }
    }

    /// Switching panes tears this view down; an edit still inside its 150ms wait is written
    /// now rather than lost with the task.
    private func flush() {
        if let pending = pendingRulesSave {
            pending.cancel()
            pendingRulesSave = nil
            Preferences.menuBarRules = rules
        }
        if let pending = pendingFallbackSave {
            pending.cancel()
            pendingFallbackSave = nil
            Preferences.menuBarFormat = fallback
        }
    }
}

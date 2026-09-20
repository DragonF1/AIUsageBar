import SwiftUI

/// The rules list, the "Otherwise:" fallback field, the token legend and "Add rule", all of
/// `MenuBarFormatSection`'s body below its title and description. Kept as its own view so
/// the rules array's edits (add, remove, reorder, keystrokes) and the fallback field's keystrokes
/// can each debounce on their own, the same way `ColorScaleSettingsView` debounces its own edits.
/// The menu bar itself is the preview: every edit lands there 150ms later.
struct MenuBarRulesEditor: View {
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: rule.condition.window) {
                    ForEach(MenuBarWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()

                Picker("", selection: rule.condition.comparison) {
                    ForEach(MenuBarComparison.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()

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
            }
            // The condition line above is already five controls wide ("Weekly", "at or over",
            // "colour band" and a band name can all be showing at once); the reorder/remove
            // buttons live here instead, trailing the template field, so the window does not
            // have to grow past what the settings window's width allows.
            HStack(spacing: 6) {
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

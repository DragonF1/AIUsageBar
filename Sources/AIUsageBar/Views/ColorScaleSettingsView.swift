import AppKit
import SwiftUI

/// The colour scale editor, one section of the "Appearance…" window: edits the four band
/// colours and the three cutoffs between them, applying live (through `Preferences.colorScale`)
/// to the popover's bars and the menu bar icon. Unpadded and unsized: `AppearanceSettingsView`
/// supplies the window's outer padding and width.
struct ColorScaleSettingsView: View {
    @State private var scale: ColorScale = Preferences.colorScale
    /// The pending write; a colour panel drag commits many times a second, and every write
    /// wakes the menu bar's redraw, so the store only sees the value once the hand rests.
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose where each band starts and which colour it uses. Changes apply immediately to the usage bars and the menu bar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(UsageColor.Level.allCases, id: \.self) { level in
                    row(for: level)
                }
            }

            previewStrip

            HStack {
                Spacer()
                Button("Reset to defaults") { commit(.default) }
                    .disabled(scale == .default)
            }
        }
    }

    private func row(for level: UsageColor.Level) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(level.title).font(.body.weight(.medium))
                Text(rangeLabel(for: level)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let cutoff = cutoffBinding(for: level) {
                TextField("", value: cutoff, format: .number)
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: cutoff, in: 1...100)
                    .labelsHidden()
            }
            ColorPicker("", selection: colorBinding(for: level), supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// "Under 75%", "75% to 84%", "85% to 94%", "95% and above".
    private func rangeLabel(for level: UsageColor.Level) -> String {
        let medium = whole(scale.mediumCutoff)
        let high = whole(scale.highCutoff)
        let critical = whole(scale.criticalCutoff)
        switch level {
        case .low: return "Under \(medium)%"
        case .medium: return "\(medium)% to \(high - 1)%"
        case .high: return "\(high)% to \(critical - 1)%"
        case .critical: return "\(critical)% and above"
        }
    }

    private func whole(_ cutoff: Double) -> Int { Int(cutoff.rounded()) }

    private var previewStrip: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                segment(width: geometry.size.width * (scale.mediumCutoff / 100), color: scale.color(for: .low))
                segment(width: geometry.size.width * ((scale.highCutoff - scale.mediumCutoff) / 100), color: scale.color(for: .medium))
                segment(width: geometry.size.width * ((scale.criticalCutoff - scale.highCutoff) / 100), color: scale.color(for: .high))
                segment(width: geometry.size.width * ((100 - scale.criticalCutoff) / 100), color: scale.color(for: .critical))
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width))
    }

    private func cutoffBinding(for level: UsageColor.Level) -> Binding<Int>? {
        switch level {
        case .low: return nil
        case .medium: return mediumCutoffBinding
        case .high: return highCutoffBinding
        case .critical: return criticalCutoffBinding
        }
    }

    private var mediumCutoffBinding: Binding<Int> {
        Binding(get: { whole(scale.mediumCutoff) },
                set: { newValue in
                    var next = scale
                    next.mediumCutoff = Double(newValue)
                    commit(next)
                })
    }

    private var highCutoffBinding: Binding<Int> {
        Binding(get: { whole(scale.highCutoff) },
                set: { newValue in
                    var next = scale
                    next.highCutoff = Double(newValue)
                    commit(next)
                })
    }

    private var criticalCutoffBinding: Binding<Int> {
        Binding(get: { whole(scale.criticalCutoff) },
                set: { newValue in
                    var next = scale
                    next.criticalCutoff = Double(newValue)
                    commit(next)
                })
    }

    /// Reads back whatever colour the picker resolved to; when that colour cannot convert to
    /// sRGB (rare: a pattern or catalog colour), the band is left as it was rather than crash.
    private func colorBinding(for level: UsageColor.Level) -> Binding<Color> {
        Binding(get: { scale.color(for: level) },
                set: { newColor in
                    var next = scale
                    if let rgba = RGBA(NSColor(newColor)) {
                        next[level] = .custom(rgba)
                    }
                    commit(next)
                })
    }

    /// Every mutation goes through here: normalise, publish to the view at once, persist a
    /// beat later so a drag through the colour panel lands as one write.
    private func commit(_ new: ColorScale) {
        let normalized = new.normalized()
        scale = normalized
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            Preferences.colorScale = normalized
        }
    }
}

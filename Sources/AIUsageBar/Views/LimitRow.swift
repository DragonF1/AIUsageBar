import SwiftUI

struct LimitRow: View {
    let title: String
    let percent: Double?
    let detail: String?
    var pace: PaceLine? = nil
    var dimmed = false

    @AppStorage(Preferences.Key.colorScale, store: Preferences.defaults) private var colorScaleData: Data = ColorScale.defaultData
    @AppStorage(Preferences.Key.showRemaining, store: Preferences.defaults) private var showRemaining = false

    private var clamped: Double { min(100, max(0, percent ?? 0)) }

    /// The bar's fill. Used mode fills left to right with what was spent; remaining mode is a
    /// battery instead, so it fills with what is left and empties toward the cap. No data is
    /// an empty bar in both modes: a missing number is not a full battery.
    private var fill: Double {
        guard percent != nil else { return 0 }
        return showRemaining ? 100 - clamped : clamped
    }

    /// Always the used percent's band, in both modes: a nearly-empty battery should read red
    /// the same way a nearly-full used bar does.
    private var tint: Color {
        guard let percent else { return .secondary }
        let scale = ColorScale.decode(colorScaleData)
        return scale.color(for: scale.level(for: percent))
    }

    /// Where the pace forecast is headed, against the used percent: nil when there is no
    /// forecast or it has not moved past where the bar already is.
    private var tickPercent: Double? { pace?.tickPercent(aheadOf: clamped) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(PercentText.labelled(percent, remaining: showRemaining))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            ProgressView(value: fill, total: 100)
                .tint(tint)
                .overlay { ghostTick }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let pace {
                Text(pace.text).font(.caption).foregroundStyle(pace.urgent ? Color.orange : Color.secondary)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    /// A thin marker over the bar previewing where the pace forecast lands: a preview of the
    /// bar's own future, not a second colour. Battery mode mirrors it to the same side as the fill.
    @ViewBuilder private var ghostTick: some View {
        if let tickPercent {
            GeometryReader { geometry in
                let position = showRemaining ? 100 - tickPercent : tickPercent
                let x = geometry.size.width * position / 100 - 1
                Rectangle()
                    .fill(tint.opacity(0.45))
                    .frame(width: 2)
                    .offset(x: min(max(0, x), max(0, geometry.size.width - 2)))
            }
        }
    }
}

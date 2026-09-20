import SwiftUI

struct LimitRow: View {
    let title: String
    let percent: Double?
    let detail: String?
    var pace: PaceLine? = nil
    var dimmed = false

    private var clamped: Double { min(100, max(0, percent ?? 0)) }

    private var tint: Color {
        guard let percent else { return .secondary }
        switch UsageColor.rowIcon(percent) {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .darkRed: return Color(nsColor: UsageColor.darkRed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            ProgressView(value: clamped, total: 100)
                .tint(tint)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let pace {
                Text(pace.text).font(.caption).foregroundStyle(pace.urgent ? Color.orange : Color.secondary)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }
}

import SwiftUI

struct LimitRow: View {
    let title: String
    let percent: Double?
    let detail: String?
    var dimmed = false

    private var clamped: Double { min(100, max(0, percent ?? 0)) }

    private var tint: Color {
        guard let percent else { return .secondary }
        switch UsageColor.level(for: percent) {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
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
        }
        .opacity(dimmed ? 0.55 : 1)
    }
}

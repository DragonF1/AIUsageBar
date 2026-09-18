import SwiftUI

/// One line per window: title, compact token count, estimated cost. Kept to a single line so the
/// two token rows add little height under the usage bars; the tooltip carries the bucket breakdown
/// and the window boundary.
struct TokenRow: View {
    let title: String
    let totals: TokenTotals
    /// Window boundary, shown in the tooltip: "Since Thu 6:00 AM" / "Rolling 7 days".
    var detail: String? = nil
    var dimmed = false

    private var tooltip: String {
        TokenText.breakdown(totals) + (detail.map { "\n" + $0 } ?? "")
    }

    var body: some View {
        GridRow {
            // Flexible, so the title column takes the slack and the numbers sit against the right edge.
            Text(title).font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(TokenText.compact(totals.tokens))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .gridColumnAlignment(.trailing)
            Text(TokenText.cost(totals))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
        .help(tooltip)
        .opacity(dimmed ? 0.55 : 1)
    }
}

import Charts
import SwiftUI

/// The cost window: today and the last 7, 30 or 90 days from one ledger (Claude Code's
/// transcripts or Antigravity's conversations), a bar per day, and the same days split by
/// model. Hovering a bar puts that day's numbers under the chart. Every figure is the
/// list-price estimate the popover's cost rows use.
struct CostView: View {
    var tokens: any TokenLedger
    var onRefresh: () -> Void

    @AppStorage(Preferences.Key.costRange) private var range: CostRange = .month
    @State private var now = Date()
    @State private var hovered: Date?
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var report: CostReport { tokens.costReport(now: now, range: range) }

    var body: some View {
        let report = report
        VStack(spacing: 0) {
            header
            Divider()
            if tokens.lastScanned == nil {
                Spacer()
                Text(tokens.error ?? tokens.product.scanning).font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        stats(report)
                        chart(report)
                        models(report)
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 520)
        .onReceive(tick) { now = $0 }
        .onAppear { now = Date() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tokens.product.name) Cost").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(CostRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How many calendar days the numbers, the chart and the splits cover, today included")
            Button("Refresh", action: onRefresh)
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var summary: String {
        var parts = ["Last \(range.days) days"]
        if let scanned = tokens.lastScanned {
            parts.append("updated \(UsageStore.timeFormatter.string(from: scanned))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - stats

    private func stats(_ report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    stat("Today", TokenText.cost(report.today), help: TokenText.breakdown(report.today))
                    stat("Last \(range.days) days", TokenText.cost(report.total), help: TokenText.breakdown(report.total))
                }
                GridRow {
                    stat("Today, tokens", TokenText.compact(report.today.tokens))
                    stat("Last \(range.days) days, tokens", TokenText.compact(report.total.tokens))
                }
            }
            mix(report.total)
        }
    }

    private func stat(_ title: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }

    /// The window's tokens by kind, so the cache share is visible without hovering.
    private func mix(_ total: TokenTotals) -> some View {
        HStack(spacing: 12) {
            mixStat("Input", total.input, of: total.tokens)
            mixStat("Output", total.output, of: total.tokens)
            mixStat("Cache write", total.cacheWrite, of: total.tokens)
            mixStat("Cache read", total.cacheRead, of: total.tokens)
        }
    }

    private func mixStat(_ title: String, _ count: Int, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(TokenText.compact(count)).font(.subheadline.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.shareText(count, of: total, in: range))
    }

    /// "37% of the last 30 days' tokens", or a plain "No tokens yet" while the window is empty.
    static func shareText(_ count: Int, of total: Int, in range: CostRange) -> String {
        guard total > 0 else { return "No tokens in the last \(range.days) days" }
        return "\(Int((Double(count) / Double(total) * 100).rounded()))% of the last \(range.days) days' tokens"
    }

    // MARK: - chart

    private func chart(_ report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart(report.days) { day in
                BarMark(x: .value("Day", day.start, unit: .day),
                        y: .value("Cost", day.totals.cost))
                    .foregroundStyle(isHovered(day.start) ? Color.accentColor : Color.accentColor.opacity(0.55))
                    .cornerRadius(2)
            }
            .chartXSelection(value: $hovered)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range.axisStride)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let usd = value.as(Double.self) { Text(Self.axisDollars(usd)) }
                    }
                }
            }
            .frame(height: 150)
            Text(caption(report)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func isHovered(_ start: Date) -> Bool {
        guard let hovered else { return true }
        return Calendar.current.isDate(hovered, inSameDayAs: start)
    }

    /// The hovered day's numbers, or the busiest day when the pointer is off the chart.
    private func caption(_ report: CostReport) -> String {
        if let hovered, let day = report.days.first(where: { Calendar.current.isDate(hovered, inSameDayAs: $0.start) }) {
            return "\(Self.dayFormat(day.start)): \(TokenText.cost(day.totals)) · \(TokenText.compact(day.totals.tokens)) tokens"
        }
        guard let peak = report.days.max(by: { $0.totals.cost < $1.totals.cost }), peak.totals.tokens > 0 else {
            return "No \(tokens.product.name) responses in the last \(range.days) days."
        }
        return "Busiest day \(Self.dayFormat(peak.start)): \(TokenText.cost(peak.totals)) · \(TokenText.compact(peak.totals.tokens)) tokens"
    }

    private static func dayFormat(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "$0", "$12", "$1.5k", and "$0.50" only when the ticks land under a dollar apart, so a
    /// quiet month does not read "$0 $0 $1 $1".
    static func axisDollars(_ usd: Double) -> String {
        if usd >= 1000 { return "$" + TokenText.compact(Int(usd)) }
        if usd >= 10 || usd == usd.rounded() { return String(format: "$%.0f", usd) }
        return String(format: "$%.2f", usd)
    }

    // MARK: - models

    @ViewBuilder private func models(_ report: CostReport) -> some View {
        if !report.models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("BY MODEL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(report.models) { share in
                        TokenRow(title: TokenText.modelName(share.model),
                                 totals: share.totals,
                                 detail: share.model)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text(tokens.error ?? tokens.product.footer)
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

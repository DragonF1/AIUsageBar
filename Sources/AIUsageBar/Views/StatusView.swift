import SwiftUI

/// Anthropic status banner, modeled on the claude.ai in-app status card.
struct StatusView: View {
    let status: StatusStore
    let now: Date
    @AppStorage("statusHidden") private var hidden = false

    var body: some View {
        if let summary = status.summary {
            card(summary)
        } else if status.failed {
            Text("Status page unreachable").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card(_ summary: StatusSummary) -> some View {
        let indicator = summary.status?.indicator
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(indicatorColor(indicator)).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.status?.description ?? "Status").font(.subheadline.weight(.medium))
                    let affected = summary.affectedNames
                    if !affected.isEmpty {
                        Text("Affects: \(affected)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { hidden.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text(hidden ? "Show" : "Hide")
                        Image(systemName: "chevron.up").rotationEffect(.degrees(hidden ? 180 : 0))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !hidden {
                componentList(summary.productComponents)
                ForEach(summary.activeIncidents) { incident in
                    incidentCard(incident)
                }
                HStack {
                    checked
                    Spacer()
                    Link(destination: StatusClient.pageURL) {
                        HStack(spacing: 2) { Text("Open status page"); Image(systemName: "arrow.right") }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(indicatorColor(indicator).opacity(0.12)))
    }

    /// One line per product, mirroring the list on status.claude.com.
    private func componentList(_ components: [StatusSummary.Component]) -> some View {
        VStack(spacing: 4) {
            ForEach(components) { c in
                HStack(spacing: 6) {
                    Circle().fill(componentColor(c.status)).frame(width: 6, height: 6)
                    Text(c.name ?? "").font(.caption).lineLimit(1)
                    Spacer()
                    Text(c.statusLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(c.status == "operational" ? Color.secondary : componentColor(c.status))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    private func componentColor(_ status: String?) -> Color {
        switch status {
        case "operational": return .green
        case "degraded_performance": return .yellow
        case "partial_outage": return .orange
        case "major_outage": return .red
        case "under_maintenance": return .blue
        default: return .gray
        }
    }

    private func incidentCard(_ i: StatusSummary.Incident) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(i.name ?? "Incident").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Text((i.status ?? "").uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(indicatorColor(i.impact)))
                    .foregroundStyle(.white)
                if let ago = RelativeText.ago(i.updatedAt, now: now) {
                    Text("Updated \(ago)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let body = i.latestBody, !body.isEmpty {
                Text(body).font(.caption).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    private var checked: some View {
        Text(RelativeText.ago(status.checkedAt, now: now).map { "Checked \($0)" } ?? "")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func indicatorColor(_ indicator: String?) -> Color {
        switch indicator {
        case "critical": return .red
        case "major": return .orange
        case "minor": return .yellow
        case "maintenance": return .blue
        default: return .green
        }
    }
}

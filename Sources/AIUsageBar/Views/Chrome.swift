import SwiftUI

/// Shared layout pieces so the popover, Sessions, Cost and Settings read as one product instead
/// of four hand-rolled headers and footers.
enum Chrome {
    /// The horizontal inset every surface pads its content by.
    static let inset: CGFloat = 16
}

/// The title row at the top of every surface: a headline title over a secondary caption
/// subtitle, and whatever controls that surface needs at the trailing edge. Used by the
/// popover, Sessions, Cost and Settings. Unpadded: the caller supplies its own padding (the
/// popover's is already inside its outer padding; the windows pad the row themselves).
struct SurfaceHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing().controlSize(.small)
        }
    }
}

/// A small-caps label above a group of rows, with an optional count, used for Sessions' "Open" /
/// "Closed today" sections and Cost's "By model" list. Unpadded: the caller supplies its own.
struct SectionHeader: View {
    var title: String
    var count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack {
            // A fixed locale so a title with an "i" never picks up a dotted capital under a
            // Turkish system locale.
            Text(title.uppercased(with: Locale(identifier: "en_US_POSIX")))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

/// The caption strip at the bottom of Sessions and Cost: a divider, then a note that reads red
/// when it is reporting an error instead of the usual footnote.
struct SurfaceFooter: View {
    var text: String
    var isError = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text(text).font(.caption2).foregroundStyle(isError ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Chrome.inset).padding(.vertical, 8)
        }
    }
}

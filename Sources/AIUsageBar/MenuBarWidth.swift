import AppKit

/// Keeps the status item the same width whichever tab is showing, so switching between Claude
/// and Antigravity never shifts every other menu bar icon sideways.
///
/// A pinned `NSStatusItem.length` was the obvious fix, but the status bar's button cell centres
/// its image and title inside whatever width it is given no matter what `alignment` says
/// (measured: identical image and title rects with `.left`, `.right` and the default), so the
/// narrower tab's icon would jump inward by half the slack instead. The item therefore stays
/// `variableLength` and the narrower tab's title is padded out to the wider tab's width with one
/// trailing space whose kern makes up the exact difference. AppKit then sizes the button as if
/// the wider text were showing and the icon keeps its place. Measured live on macOS 26:
/// "8% / 32%" padded this way to "100% / 100%" produced the same 126pt button as the long title,
/// image at the same x, whereas a text attachment of the same width was not honoured.
enum MenuBarWidth {
    /// How many points to add after the shown tab's text so its button comes out as wide as the
    /// other tab's would. Whole points: AppKit rounds a title's width up before laying it out,
    /// so both tabs land on the same integer width. Zero when the shown tab is already the wider
    /// one or the same width. The image widths are included in case the two product marks differ.
    static func trailingPadding(currentTextWidth: CGFloat, currentImageWidth: CGFloat,
                                otherTextWidth: CGFloat, otherImageWidth: CGFloat) -> CGFloat {
        let current = ceil(currentTextWidth) + currentImageWidth
        let other = ceil(otherTextWidth) + otherImageWidth
        return max(0, other - current)
    }

    /// `title` with a trailing space kerned so the string measures exactly `padding` points
    /// wider; `title` itself when `padding` is zero or less.
    static func pad(_ title: NSAttributedString, by padding: CGFloat, font: NSFont) -> NSAttributedString {
        guard padding > 0 else { return title }
        let spaceWidth = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        let padded = NSMutableAttributedString(attributedString: title)
        padded.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: padding - spaceWidth]))
        return padded
    }
}

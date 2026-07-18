import AppKit

/// Geometry for the outline transcript, shared by the store (row padding
/// + typeset widths), the view controller (per-row width queries), the
/// cell (draw origin) and the outline subclass (native disclosure-button
/// frame).
///
/// The outline is a **full-width, frame-based** documentView — the
/// native contract for `NSTableView`-family document views (same shape
/// as the old `NativeTranscript2` table and TelegramSwift's chat table).
/// The centered 460–780 content column exists only *inside* each row:
/// every horizontal number below derives from `BlockStyle`'s
/// centered-column constants plus the two outline-specific steps, so the
/// typeset width, the cell's draw origin, and the chevron position can
/// never disagree. Layouts themselves stay column-agnostic — they only
/// ever see a `maxWidth` and a caller-supplied origin.
enum TranscriptOutlineMetrics {
    /// Horizontal shift per outline level inside the centered column.
    nonisolated static let indentStep: CGFloat = 16

    /// Horizontal slot reserved on header rows for the native disclosure
    /// button plus the gap to the title: the triangle sits at the row's
    /// content x (aligned with markdown's text edge one level up), the
    /// title starts `chevronSlot` after it.
    nonisolated static let chevronSlot: CGFloat = 24

    /// The centered content column's left edge inside a full-width row.
    /// Same function the old renderer's cells and selection used.
    nonisolated static func columnX(forRowWidth rowWidth: CGFloat) -> CGFloat {
        BlockStyle.cellOriginX(forRowWidth: rowWidth)
    }

    /// Left edge of a node's content inside the row: column edge +
    /// standard block padding + per-level indent, plus the chevron slot
    /// on header rows (their title starts after the native triangle).
    nonisolated static func contentX(
        forRowWidth rowWidth: CGFloat, level: Int, hasChevronSlot: Bool
    ) -> CGFloat {
        columnX(forRowWidth: rowWidth) + BlockStyle.blockHorizontalPadding
            + CGFloat(max(0, level)) * indentStep
            + (hasChevronSlot ? chevronSlot : 0)
    }

    /// Width a node's layout is typeset at — the centered column net of
    /// the same insets `contentX` applies on the left and the standard
    /// block padding on the right. The single place row widths are
    /// computed; `heightOfRowByItem` and `viewFor` both go through it so
    /// a row is typeset at exactly one width.
    nonisolated static func layoutWidth(
        forRowWidth rowWidth: CGFloat, level: Int, hasChevronSlot: Bool
    ) -> CGFloat {
        let clamped = BlockStyle.clampedLayoutWidth(forRowWidth: rowWidth)
        let inset =
            2 * BlockStyle.blockHorizontalPadding
            + CGFloat(max(0, level)) * indentStep
            + (hasChevronSlot ? chevronSlot : 0)
        return max(1, clamped - inset)
    }

    // MARK: - Vertical rhythm (L1 / L2 / L3)

    /// L1 — tool group header row. Top matches the hard-edged block tier
    /// (`BlockStyle.blockPadding`'s 8 for `toolGroup`); bottom contributes
    /// half of the canonical 4pt header gap, the first tool header's top
    /// contributes the other half.
    nonisolated static let groupHeaderPadding: (top: CGFloat, bottom: CGFloat) = (
        top: 8, bottom: BlockStyle.toolHeaderChildSpacing / 2
    )

    /// L2 — tool header row. 2+2 against its neighbours so header↔header
    /// and header↔body gaps both read `toolHeaderChildSpacing` (4pt).
    nonisolated static let toolHeaderPadding: (top: CGFloat, bottom: CGFloat) = (
        top: BlockStyle.toolHeaderChildSpacing / 2,
        bottom: BlockStyle.toolHeaderChildSpacing / 2
    )

    /// L3 — tool body row. Same 2+2: 4pt under its header, 4pt above the
    /// next tool header.
    nonisolated static let toolBodyPadding: (top: CGFloat, bottom: CGFloat) = (
        top: BlockStyle.toolHeaderChildSpacing / 2,
        bottom: BlockStyle.toolHeaderChildSpacing / 2
    )
}

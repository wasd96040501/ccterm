import AppKit

/// Geometry for the flat history transcript, shared by the store (typeset
/// width + row padding), the view controller (per-row width query +
/// selection origin) and the cell (draw origin) — the single chokepoint
/// so the typeset width and the cell's draw origin can never disagree.
///
/// The table is a **full-width, frame-based** documentView (the native
/// `NSTableView` contract). The centered 460–780 content column exists
/// only *inside* each row: every horizontal number below derives from
/// `BlockStyle`'s centered-column constants, matching the streaming
/// `NativeTranscript2` renderer's centering exactly. Layouts themselves
/// stay column-agnostic — they only ever see a `maxWidth` and a
/// caller-supplied origin.
enum TranscriptMetrics {
    /// The centered content column's left edge inside a full-width row.
    /// Same function the streaming renderer's cells and selection use.
    nonisolated static func columnX(forRowWidth rowWidth: CGFloat) -> CGFloat {
        BlockStyle.cellOriginX(forRowWidth: rowWidth)
    }

    /// Left edge of a row's content inside the row: column edge + standard
    /// block padding. Drives the cell's draw origin and the selection
    /// algorithm's document→layout-local conversion.
    nonisolated static func contentX(forRowWidth rowWidth: CGFloat) -> CGFloat {
        columnX(forRowWidth: rowWidth) + BlockStyle.blockHorizontalPadding
    }

    /// Width a row's layout is typeset at — the centered column net of the
    /// standard block padding on both sides. The single place row widths
    /// are computed; `heightOfRow` and `viewFor` both go through it so a
    /// row is typeset at exactly one width.
    nonisolated static func layoutWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        max(1, BlockStyle.clampedLayoutWidth(forRowWidth: rowWidth) - 2 * BlockStyle.blockHorizontalPadding)
    }

    /// Top / bottom padding for a tool-group header row. Matches
    /// `BlockStyle`'s hard-edged block tier (8/8, same as image / table /
    /// codeBlock / toolGroup) so the header reads as a self-contained
    /// block in the flat rhythm.
    nonisolated static let groupHeaderPadding: (top: CGFloat, bottom: CGFloat) = (top: 8, bottom: 8)
}

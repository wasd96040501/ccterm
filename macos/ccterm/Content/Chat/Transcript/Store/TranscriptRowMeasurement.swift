import AppKit

/// What the table layer needs to know about a row without knowing which
/// kind it is: how tall it draws, how wide it actually typeset, and how
/// to project a selection into it.
///
/// Deliberately *not* a way to draw the row. Drawing goes through the
/// row's own view (`MarkdownParagraphView`, `MarkdownCodeBlockView`, …),
/// which holds the real measure; this value only carries the few numbers
/// `heightOfRow` and the selection coordinator ask for, so neither of
/// them needs a type-erased layout.
struct TranscriptRowMeasurement {
    /// Height of the drawn content at the measured width, excluding the
    /// row's own vertical padding.
    let height: CGFloat
    /// Width the content actually typeset to — never wider than the slot
    /// it was measured against.
    let measuredWidth: CGFloat
    /// Selection geometry for the row, or `nil` when the kind carries no
    /// selectable text (image, thematic break, group header).
    let selectionAdapter: SelectionAdapter?
}

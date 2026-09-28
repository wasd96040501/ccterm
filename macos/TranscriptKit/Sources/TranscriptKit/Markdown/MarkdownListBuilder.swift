import AppKit

/// A bulleted, numbered or task list, built: its markers rendered, the widest one
/// taken as the column, and a `BlockStack` of `ListRow`s handed back.
///
/// **Not a `Block`.** Everything a list does is settled before any width is
/// known — render the markers, take the widest, and that is the column every item
/// indents past. So it is a factory that hands back a `BlockStack` of rows, the
/// same way `MarkdownBlockBuilder` hands back blocks: there is no measure-time
/// behaviour left for it to own, and a type whose `measure` only forwards is a
/// layer that costs a hop and explains nothing. What *is* left at measure time —
/// the marker in its column, the content beside it — is `ListRow`'s.
///
/// That the negotiation is width-independent is the whole reason. A stack cannot
/// make `10.` and `9.` line up — the marker column is an agreement *between*
/// siblings — but the agreement is over typeset markers, and typesetting a marker
/// never depended on how wide the list is.
enum MarkdownListBuilder {

    /// What a marker *says*. An input to `marker(_:font:color:)` and never
    /// stored: by the time a list is assembled, its markers are typeset text and
    /// drawn shapes.
    enum Kind {
        case bullet
        case ordinal(Int)
        case task(checked: Bool)
    }

    struct Item {
        let marker: ListRow.Marker
        let content: Block

        init(marker: ListRow.Marker, content: Block) {
            self.marker = marker
            self.content = content
        }
    }

    /// Renders one marker. `font` matches the surrounding body face — a marker
    /// set at a different size sits on a different baseline from the line it
    /// belongs to — and the checkbox takes GitHub's share of it: 13pt against the
    /// 16pt body `.markdown-body` sets, so `13/16` of whatever body size is in
    /// play here.
    ///
    /// **A ratio, where GitHub's is a constant.** A browser draws
    /// `input[type=checkbox]` at 13px whether the surrounding text is 12px or
    /// 24px — measured, not assumed — because a form control belongs to the
    /// operating system rather than to the document, and the OS does not care
    /// what font a page picked. That reasoning holds for a control a reader can
    /// click, and stops holding here: this is a glyph in a rendered document, and
    /// a glyph that stayed 13pt while the text around it grew would read as a
    /// mistake. So the port takes GitHub's *proportion* and drops its pixel
    /// count, and the two agree exactly at the size GitHub actually renders.
    static func marker(_ kind: Kind, font: NSFont, color: NSColor) -> ListRow.Marker {
        switch kind {
        case .task(let checked):
            return .checkbox(
                Checkbox(
                    size: font.pointSize * 13 / 16, checked: checked,
                    fill: Checkbox.defaultFill, mark: Checkbox.defaultMark, border: color))

        case .bullet:
            return .text(text("•", font: font, color: color))

        case .ordinal(let n):
            return .text(text("\(n).", font: font, color: color))
        }
    }

    private static func text(_ string: String, font: NSFont, color: NSColor) -> TypesetText {
        ShapedText(string, attributes: [.font: font, .foregroundColor: color])
            .typeset(width: .greatestFiniteMagnitude)
    }

    /// The list, as a stack of rows sharing one marker column.
    ///
    /// `spacing` is tighter than the gap between two document blocks: the items
    /// of one list are one thought. The same number applies at every nesting
    /// depth and between the blocks *inside* one item, so a list has a single
    /// rhythm no matter how it is shaped.
    ///
    /// `gap` separates the marker column from the content. Half the body point
    /// size, so it tracks the text rather than staying fixed while the text
    /// grows.
    static func make(items: [Item], spacing: CGFloat, gap: CGFloat) -> BlockStack {
        // The negotiation, all of it: take the widest marker.
        let column = items.map(\.marker.width).max() ?? 0
        return BlockStack(
            items.map {
                ListRow(marker: $0.marker, markerColumn: column, gap: gap, content: $0.content)
            },
            spacing: spacing)
    }
}

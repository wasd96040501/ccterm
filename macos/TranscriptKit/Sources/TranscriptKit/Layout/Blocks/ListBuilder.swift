import AppKit

/// A bulleted, numbered or task list: a marker column beside a stack of item
/// contents.
///
/// **Not a `Block`.** Everything a list does is settled before any width is
/// known — render the markers, take the widest, and that is the column every item
/// indents past. So it is a factory that hands back a `BlockStack` of rows, the
/// same way `MarkdownBlockBuilder` hands back blocks: there is no measure-time
/// behaviour left for it to own, and a type whose `measure` only forwards is a
/// layer that costs a hop and explains nothing.
///
/// That the negotiation is width-independent is the whole reason. A stack cannot
/// make `10.` and `9.` line up — the marker column is an agreement *between*
/// siblings — but the agreement is over typeset markers, and typesetting a marker
/// never depended on how wide the list is.
///
/// **Markers are drawn, not indexed.** A bullet, an ordinal and a task checkbox
/// occupy zero positions in the selection index space, so dragging across a list
/// copies the items' text and none of the furniture — what a reader expects, and
/// what a browser does.
///
/// An item's content is any `Block`, so an item holds paragraphs, code blocks,
/// quotes, or another list, without this type knowing which. Nesting is not a
/// mechanism of its own: a sub-list is simply one more block inside its parent
/// item's content.
enum ListBuilder {

    /// What a marker *says*. An input to `marker(_:font:color:)` and never
    /// stored: by the time a list is assembled, its markers are typeset text and
    /// drawn shapes.
    enum Kind {
        case bullet
        case ordinal(Int)
        case task(checked: Bool)
    }

    /// What a marker *is*, once rendered.
    enum Marker {
        case text(TypesetText)
        case checkbox(Checkbox)

        var width: CGFloat {
            switch self {
            case .text(let text): return text.size.width
            case .checkbox(let box): return box.size
            }
        }
    }

    struct Item {
        let marker: Marker
        let content: Block

        init(marker: Marker, content: Block) {
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
    static func marker(_ kind: Kind, font: NSFont, color: NSColor) -> Marker {
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
            items.map { Row(marker: $0.marker, markerColumn: column, gap: gap, content: $0.content) },
            spacing: spacing)
    }

    /// One item: its marker in the settled column, its content in the remainder.
    private struct Row: Block {

        let marker: Marker
        let markerColumn: CGFloat
        let gap: CGFloat
        let content: Block

        func measure(_ width: CGFloat) -> MeasuredBlock {
            let indent = markerColumn + gap
            let inner = content.measure(max(1, width - indent))
            return Measured(
                marker: marker,
                // Right-aligned in the column, so `9.` and `10.` share a decimal
                // point rather than a left edge.
                markerRightX: markerColumn,
                content: inner,
                indent: indent,
                // The content's first line box, which is what the marker aligns
                // to. Read off the content rather than assumed, because how much
                // room a block gives itself is its own business and not something
                // it reports — and read *here* rather than at paint time, because
                // it depends on the width and on nothing else.
                firstLine: inner.rects(from: 0, to: min(1, inner.length)).first
                    ?? CGRect(x: 0, y: 0, width: 0, height: inner.size.height),
                size: CGSize(width: width, height: inner.size.height))
        }

        struct Measured: MeasuredBlock, @unchecked Sendable {

            let marker: Marker
            let markerRightX: CGFloat
            let content: MeasuredBlock
            let indent: CGFloat
            let firstLine: CGRect
            let size: CGSize

            /// The marker is `.content`: it is furniture, but it is furniture this
            /// block is *saying*, not a surface behind what it says. Nothing of
            /// the content's ever reaches the marker column, so nothing composites
            /// against it either way.
            func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
                switch marker {
                case .text(let text):
                    // Same point size as the body, so sharing a top means
                    // sharing a baseline.
                    list.append(
                        .text(
                            text,
                            at: CGPoint(
                                x: origin.x + markerRightX - text.size.width,
                                y: origin.y + firstLine.minY)))

                case .checkbox(let box):
                    // A drawn shape has no baseline, so it centres on the line
                    // instead — which is what a browser does with a `::marker`
                    // it draws rather than typesets.
                    list.append(
                        contentsOf: box.items(
                            in: CGRect(
                                x: origin.x + markerRightX - box.size,
                                y: origin.y + firstLine.midY - box.size / 2,
                                width: box.size, height: box.size)))
                }

                content.paint(
                    at: CGPoint(x: origin.x + indent, y: origin.y), dirty: dirty, into: &list)
            }

            // MARK: - Selection — the content's only; a marker holds no positions

            var length: Int { content.length }

            func index(at point: CGPoint) -> Int {
                content.index(at: CGPoint(x: point.x - indent, y: point.y))
            }

            func rects(from: Int, to: Int) -> [CGRect] {
                content.rects(from: from, to: to).map { $0.offsetBy(dx: indent, dy: 0) }
            }

            func text(from: Int, to: Int) -> String { content.text(from: from, to: to) }

            /// The marker column holds nothing pointable — a bullet is furniture —
            /// so a point in it lands left of the content's origin and finds
            /// nothing, without this having to say so.
            func characterIndex(at point: CGPoint) -> Int? {
                content.characterIndex(at: CGPoint(x: point.x - indent, y: point.y))
            }

            // No offset on these three: a marker holds no positions, so the
            // content's index space is the whole of this one.
            func link(at index: Int) -> InlineLink? { content.link(at: index) }
            func wordRange(at index: Int) -> Range<Int> { content.wordRange(at: index) }
            func paragraphRange(at index: Int) -> Range<Int> { content.paragraphRange(at: index) }
        }
    }
}

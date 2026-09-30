import AppKit

/// One list item: its marker in a column the list settled, its content in the
/// remainder.
///
/// The drawing half of a list. Which marker an item gets and how wide the column
/// is are settled before any width is known — `MarkdownListBuilder`'s job — so by
/// the time a row exists both are facts it is handed, and a list is simply a
/// `BlockStack` of these.
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
struct ListRow: Block, @unchecked Sendable {

    /// What a marker *is*, once rendered: typeset text or a drawn checkbox.
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

    let marker: Marker
    let markerColumn: CGFloat
    let gap: CGFloat
    let content: Block

    init(marker: Marker, markerColumn: CGFloat, gap: CGFloat, content: Block) {
        self.marker = marker
        self.markerColumn = markerColumn
        self.gap = gap
        self.content = content
    }

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

    struct Measured: MeasuredContainerBlock, @unchecked Sendable {

        let marker: Marker
        let markerRightX: CGFloat
        let content: MeasuredBlock
        let indent: CGFloat
        let firstLine: CGRect
        let size: CGSize

        var contentOrigin: CGPoint { CGPoint(x: indent, y: 0) }

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
    }
}

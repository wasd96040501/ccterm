import AppKit

/// Draws one markdown list — ordered / unordered / task, arbitrarily
/// nested. Markers and checkboxes are self-drawn; nested lists are laid
/// out recursively inside the measure.
final class MarkdownListView: MarkdownBlockView {
    private var list: ListLayout?

    func configure(_ measure: ListLayout, width: CGFloat) {
        list = measure
        contentWidth = width
        contentDidChange()
    }

    override var contentHeight: CGFloat { list?.totalHeight ?? 0 }
    override var measuredWidth: CGFloat { list?.measuredWidth ?? 0 }
    override var selectionAdapter: SelectionAdapter? { list?.selectionAdapter }

    override var interactiveHits: [InteractiveHit] {
        // Nested items already flattened their link rects into
        // list-local coords during `make`, so they need no transform.
        (list?.links ?? []).map {
            InteractiveHit(rect: $0.rect, action: .openURL($0.url))
        }
    }

    override func drawContent(in ctx: CGContext, origin: CGPoint) {
        list?.draw(in: ctx, origin: origin)
    }
}

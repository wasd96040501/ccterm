import AppKit

/// Type-erased dispatch over the per-kind layout primitives. Holds whichever
/// `XxxLayout` value the block kind required, and exposes the three things
/// downstream code asks for:
///
/// - `totalHeight` (consumed by `NSTableView.heightOfRow`)
/// - `measuredWidth` (used by the layout cache to detect width changes)
/// - `draw(in:origin:)` (invoked by the cell's `draw(_:)`)
///
/// Add a new layout primitive: add the case here, extend the three methods.
/// The cell view is enum-agnostic — it just calls `layout.draw`.
enum RowLayout: Sendable {
    case text(TextLayout)
    case image(ImageLayout)

    var totalHeight: CGFloat {
        switch self {
        case .text(let l): return l.totalHeight
        case .image(let l): return l.totalHeight
        }
    }

    var measuredWidth: CGFloat {
        switch self {
        case .text(let l): return l.measuredWidth
        case .image(let l): return l.measuredWidth
        }
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .text(let l): l.draw(in: ctx, origin: origin)
        case .image(let l): l.draw(in: ctx, origin: origin)
        }
    }
}

import AppKit

/// Type-erased dispatch over the per-kind layout primitives. Holds whichever
/// `XxxLayout` value the block kind required, and exposes the three things
/// downstream code asks for:
///
/// - `totalHeight`(consumed by `NSTableView.heightOfRow`)
/// - `measuredWidth`(used by the diff to detect width changes)
/// - `draw(in:origin:)`(invoked by the cell's `draw(_:)`)
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

/// One row's prepared state — `Block` (data) + `RowLayout` (geometry at a
/// specific width). Immutable; diff-friendly.
struct RowItem: Equatable, Sendable {
    let id: UUID
    let block: Block
    let layout: RowLayout

    /// Width-aware identity. Same id + same block + same measured width →
    /// the layout result is reusable (no recompute).
    static func == (lhs: RowItem, rhs: RowItem) -> Bool {
        lhs.id == rhs.id && lhs.block == rhs.block
            && lhs.layout.measuredWidth == rhs.layout.measuredWidth
    }
}

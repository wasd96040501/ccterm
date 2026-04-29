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
enum RowLayout: @unchecked Sendable {
    case text(TextLayout)
    case image(ImageLayout)
    case list(ListLayout)
    case table(TableLayout)

    var totalHeight: CGFloat {
        switch self {
        case .text(let l): return l.totalHeight
        case .image(let l): return l.totalHeight
        case .list(let l): return l.totalHeight
        case .table(let l): return l.totalHeight
        }
    }

    var measuredWidth: CGFloat {
        switch self {
        case .text(let l): return l.measuredWidth
        case .image(let l): return l.measuredWidth
        case .list(let l): return l.measuredWidth
        case .table(let l): return l.measuredWidth
        }
    }

    func draw(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .text(let l): l.draw(in: ctx, origin: origin)
        case .image(let l): l.draw(in: ctx, origin: origin)
        case .list(let l): l.draw(in: ctx, origin: origin)
        case .table(let l): l.draw(in: ctx, origin: origin)
        }
    }

    /// Link hit zones in layout-local coords. Cell-side hit-testing
    /// offsets these by the cell's draw origin. List / table layouts
    /// have already flattened their inner cell links into list-/table-
    /// local coords during `make`, so they roll up here without further
    /// transformation.
    var links: [TextLayout.LinkHit] {
        switch self {
        case .text(let l): return l.links
        case .image: return []
        case .list(let l): return l.links
        case .table(let l): return l.links
        }
    }

    /// Underlying `TextLayout` for kinds with a single contiguous text
    /// flow (paragraph / heading). `nil` for image, list, and table —
    /// list and table contain multiple sub-layouts and selection across
    /// them isn't supported through the single-`TextLayout` selection
    /// path. Cell highlight draw and drag hit-test both consume this
    /// accessor and silently skip rows that return `nil`.
    var textLayout: TextLayout? {
        switch self {
        case .text(let l): return l
        case .image, .list, .table: return nil
        }
    }
}

import AppKit

/// `NSTableRowView` placeholder — keeps `NSTableView.makeView` keyed on
/// a stable class identity for row recycling, with no behavior override.
///
/// The visual centering of row content is **not** done here. It lives
/// in `BlockCellView.layoutOrigin`, which offsets the layout's draw
/// origin by `BlockStyle.cellOriginX(forRowWidth: bounds.width)`.
///
/// Why centering in the draw origin instead of `cell.frame`:
/// NSTableView's view-based mode owns cell-view positioning (cell
/// fills its column, the column spans the row). Reaching back through
/// `row.layout()` to overwrite `cell.frame` raced against that owner —
/// any frame-set we didn't catch on the same tick (column resize, tile
/// pass, autoresize during animation) left a transient row-wide
/// `bounds.width` at draw time, baked a row-wide bitmap into the cell
/// layer, and stuck under default `contentsGravity = .resize` once
/// frame later shrank. Routing centering through the cell's draw
/// origin eliminates the race: NSTableView keeps its expected cell
/// geometry, the cell shifts its own paint origin to land content at
/// the centered position. `bounds.width` is always the row's width;
/// the layout's internal `maxWidth` (clamped via
/// `BlockStyle.clampedLayoutWidth`) stays the same as before.
final class CenteredRowView: NSTableRowView {}

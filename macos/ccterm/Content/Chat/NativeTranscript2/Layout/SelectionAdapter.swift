import AppKit

/// Concrete, typed selection position. Each layout produces only its own
/// case and consumes only its own case via the `SelectionAdapter` it
/// hands out — the cases exist as a tagged union so heterogeneous
/// layouts can store / move positions through a single dictionary
/// without `Any` / `AnyHashable` / existential erasure.
///
/// **Discipline:** `Transcript2SelectionCoordinator` and `BlockCellView`
/// never `switch` on this enum. They round-trip values through the
/// adapter that produced them. `if case` inside a layout's adapter
/// closures is acceptable (and is the layout's own self-check that the
/// position came from the right source).
enum LayoutPosition: Equatable, Hashable {
    case text(char: Int)
    case cell(row: Int, col: Int, char: Int)
}

/// Two `LayoutPosition`s describing one block's current selection. Order
/// is unconstrained — `SelectionAdapter.rects` / `string` normalize as
/// needed.
struct SelectionRange: Equatable {
    let start: LayoutPosition
    let end: LayoutPosition
}

/// Layout's selection-facing API. A struct of typed function values
/// captured over the (immutable) layout instance — no protocol, no
/// `any`, no associatedtype.
///
/// `Transcript2SelectionCoordinator` and `BlockCellView` interact with
/// the layout exclusively through this adapter, so the layout's internal
/// selection topology (1-D char index for text, 2-D `(row, col, char)`
/// for table) stays encapsulated behind `LayoutPosition` and never leaks
/// into the coordinator's algorithm.
struct SelectionAdapter {
    /// Anchor / cursor pair representing "the entire layout selected."
    /// Used by Cmd+A and as the row-edge endpoints in multi-row drag
    /// (top-row → end-of-layout, start-of-layout → bottom-row, middle
    /// rows full-select).
    let fullRange: SelectionRange

    /// Layout-local point → opaque position. Out-of-bounds points clamp
    /// to the nearest edge so the caller always gets a defined landing.
    let hitTest: (CGPoint) -> LayoutPosition

    /// Layout-local highlight rects spanning the (`a`, `b`) pair. Order
    /// of arguments doesn't matter — the adapter normalizes internally.
    let rects: (_ a: LayoutPosition, _ b: LayoutPosition) -> [CGRect]

    /// Plain-text representation of the selection, with U+2028 inline
    /// line-separators normalized to `\n` for paste targets that don't
    /// render them. Per-block joiner (`\n\n` between blocks) is the
    /// caller's responsibility.
    let string: (_ a: LayoutPosition, _ b: LayoutPosition) -> String

    /// Word-boundary expansion at a click point — drives double-click
    /// word selection and byWord drag snap. Returns `nil` at positions
    /// where the layout has no word concept (empty layout, etc.).
    let wordBoundary: (LayoutPosition) -> SelectionRange?
}

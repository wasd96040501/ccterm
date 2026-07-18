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
    case listItem(paragraph: Int, char: Int)
    /// Diff body position. `childIndex` identifies which expanded
    /// child body inside a `toolGroup` row owns the position; `char`
    /// is a 0-based index into that body's *content-only* text
    /// (gutter and sign columns are skipped). Selection can only be
    /// drawn between two `.diff` positions sharing the same
    /// `childIndex`; the adapter returns empty rects / empty string
    /// otherwise. Mixed-body drags are not modelled — a drag that
    /// starts in body A and lands in body B clamps to A.
    case diff(childIndex: Int, char: Int)
    /// Text-card body position. `childIndex` identifies the expanded
    /// child body inside a `toolGroup` row whose body is a stack of
    /// `TextCardSection` rounded cards (bash / grep / glob / webFetch
    /// / webSearch / askUserQuestion / agent — every non-diff,
    /// non-header-only kind today). `sectionIndex` identifies which
    /// card inside that body; `char` is the UTF-16 index into the
    /// section's `TextLayout`'s attributed string. Selection is only
    /// drawn between two `.textCard` positions sharing the same
    /// `childIndex` *and* `sectionIndex` — cross-section drags clamp
    /// to the start section, mirroring how cross-body drags clamp on
    /// the diff side. A child with a single section (most cases)
    /// behaves like a single contiguous selectable body.
    case textCard(childIndex: Int, sectionIndex: Int, char: Int)
}

/// Two `LayoutPosition`s describing one block's current selection. Order
/// is unconstrained — `SelectionAdapter.rects` / `string` normalize as
/// needed.
struct SelectionRange: Equatable {
    let start: LayoutPosition
    let end: LayoutPosition
}

/// One contiguous chunk of plain text the layout exposes to the search
/// scanner. A layout may publish multiple regions (a `toolGroup` row
/// publishes one per searchable child); matches are confined to a single
/// region — cross-region matches are not modelled, which mirrors how
/// selection's `string()` is region-local.
///
/// **Contract.** `position(0)` returns the start `LayoutPosition` of
/// this region, `position(text.utf16.count)` the end. The scanner only
/// calls `position` at offsets it discovered via `NSString.range(of:)`,
/// which are UTF-16 unit indices — so the closure must interpret its
/// argument as a UTF-16 offset (same units used by every other
/// `LayoutPosition.char` in this file).
///
/// **Why a closure, not `[LayoutPosition]`:** the conversion is
/// deterministic (`char → LayoutPosition` is a 1:1 map for `.text`,
/// `.diff`, `.textCard`), so materialising a per-character position
/// array would be O(N) work + O(N) memory per layout for no gain.
struct SearchableRegion {
    let text: String
    let position: (Int) -> LayoutPosition
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

    /// Range covering "the unit at this position" — drives triple-click
    /// whole-unit selection. Distinct from `fullRange` because a layout's
    /// top-level full range and its triple-click target diverge for
    /// composite layouts: a table's `fullRange` is the whole table
    /// (Cmd+A target), but `unitRange` at a click point is just that one
    /// cell. For text, the two coincide (block == unit). For list, the
    /// unit is the paragraph the position lives in.
    let unitRange: (LayoutPosition) -> SelectionRange

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

    /// Searchable plain-text regions in this layout, paired with a
    /// closure that maps a UTF-16 char offset within the region back
    /// to a `LayoutPosition`. The search coordinator scans each
    /// region's `text`, then projects hit ranges through `position`
    /// into endpoints the existing `rects` / `string` closures
    /// understand. Default is empty for layouts that don't (yet)
    /// participate in search — keep selection-only by setting nothing.
    let searchableRegions: () -> [SearchableRegion]

    /// Memberwise init keeps `searchableRegions` opt-in: layouts that
    /// haven't been wired for search omit it and get an empty default,
    /// so adding the field doesn't force every existing adapter site
    /// to touch the constructor.
    init(
        fullRange: SelectionRange,
        unitRange: @escaping (LayoutPosition) -> SelectionRange,
        hitTest: @escaping (CGPoint) -> LayoutPosition,
        rects: @escaping (LayoutPosition, LayoutPosition) -> [CGRect],
        string: @escaping (LayoutPosition, LayoutPosition) -> String,
        wordBoundary: @escaping (LayoutPosition) -> SelectionRange?,
        searchableRegions: @escaping () -> [SearchableRegion] = { [] }
    ) {
        self.fullRange = fullRange
        self.unitRange = unitRange
        self.hitTest = hitTest
        self.rects = rects
        self.string = string
        self.wordBoundary = wordBoundary
        self.searchableRegions = searchableRegions
    }
}

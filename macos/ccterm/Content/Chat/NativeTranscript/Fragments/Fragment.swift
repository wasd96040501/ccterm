import AppKit
import CoreText

/// Declarative paintable unit of a ``TranscriptRow``.
///
/// Rows implementing ``FragmentRow`` vend a `[Fragment]` from
/// `fragments(width:)`; the base ``TranscriptRow`` handles draw / height /
/// selection / hit-test / highlight-writeback generically from this list.
///
/// The enum is the **only** data the paint loop traverses — per performance
/// rule #3 in the plan, nothing else is walked in the hot path.
enum Fragment {
    case rect(RectFragment)
    case text(TextFragment)
    case line(LineFragment)
    case table(TableFragment)
    case list(ListFragment)
    case custom(CustomFragment)

    /// Row-local bounding box. Used for row height accumulation
    /// (`max(frame.maxY)`) and coarse hit-test filtering.
    var frame: CGRect {
        switch self {
        case .rect(let f):   return f.frame
        case .text(let f):   return f.frame
        case .line(let f):   return f.frame
        case .table(let f):  return f.frame
        case .list(let f):   return f.frame
        case .custom(let f): return f.frame
        }
    }
}

// MARK: - Rect

struct RectFragment {
    let frame: CGRect
    let style: Style

    enum Style {
        /// Solid fill with a uniform corner radius (0 = square corners).
        case fill(NSColor, cornerRadius: CGFloat = 0)
        /// Solid fill with independent per-corner radii (e.g. header strip
        /// with rounded top / square bottom).
        case fillPerCorner(NSColor, topLeft: CGFloat, topRight: CGFloat,
                           bottomLeft: CGFloat, bottomRight: CGFloat)
        /// Hollow stroke with optional dash pattern.
        case stroke(NSColor, lineWidth: CGFloat,
                    dash: [CGFloat] = [], cornerRadius: CGFloat = 0)
    }
}

// MARK: - Text (multi-line, width-aware)

/// A pre-typeset ``TranscriptTextLayout`` painted at `origin`. Carries
/// optional keys to opt into text-selection and syntax-highlight writeback,
/// both handled generically by the base ``TranscriptRow``.
struct TextFragment {
    let layout: TranscriptTextLayout
    let origin: CGPoint

    /// Non-nil → participates in text selection. The key is opaque to the
    /// base: painter looks up the selection range via `row.range(for: key)`,
    /// and the region's `setSelection` closure writes back via
    /// `store.setRange(_:for: key)`. Callers choose the key shape (Int,
    /// String, custom Hashable struct) as appropriate for their row type.
    let selectionKey: AnyHashable?

    /// Non-nil → participates in highlight-writeback. Owning row maps
    /// highlight tokens back to fragments by this key in `applyTokens`.
    let highlightKey: AnyHashable?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.measuredWidth, 1),
               height: max(layout.totalHeight, 1))
    }

    init(layout: TranscriptTextLayout, origin: CGPoint,
         selectionKey: AnyHashable? = nil, highlightKey: AnyHashable? = nil) {
        self.layout = layout
        self.origin = origin
        self.selectionKey = selectionKey
        self.highlightKey = highlightKey
    }
}

// MARK: - Line (single pre-typeset CTLine)

/// Single pre-typeset ``CTLine``. Used for gutter text, sign columns,
/// language labels, short headers — anywhere width-agnostic single-line
/// typesetting is enough. Cheaper than a full ``TranscriptTextLayout`` for
/// one-line content.
struct LineFragment {
    let line: CTLine
    /// Top-left of the line's bounding box in row coordinates.
    let origin: CGPoint
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    /// Baseline y in row coordinates (= `origin.y + ascent`).
    /// `CGContext.textPosition.y` = this value.
    var baselineY: CGFloat { origin.y + ascent }

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y, width: width, height: ascent + descent)
    }

    /// Construct from an ``NSAttributedString`` line. Typesets once, then the
    /// resulting CTLine is cached by the caller inside the fragment value.
    static func make(attributed: NSAttributedString, origin: CGPoint) -> LineFragment {
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return LineFragment(
            line: line, origin: origin,
            ascent: ascent, descent: descent, width: width)
    }
}

// MARK: - Table / List

struct TableFragment {
    let layout: TranscriptTableLayout
    let origin: CGPoint
    /// Base key for cell selection. Each cell's store key is derived as
    /// `TableCellKey(base:, row:, col:)`. `nil` → table is non-selectable.
    let selectionKeyBase: AnyHashable?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.measuredWidth, 1),
               height: max(layout.totalHeight, 1))
    }
}

struct ListFragment {
    let layout: TranscriptListLayout
    let origin: CGPoint
    /// Base key for per-text selection. Each text's store key is derived as
    /// `ListTextKey(base:, textIdx:)`. `nil` → list is non-selectable.
    let selectionKeyBase: AnyHashable?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.measuredWidth, 1),
               height: max(layout.totalHeight, 1))
    }
}

/// Composite key for a cell inside a `TableFragment`. Painter and fragment
/// self-report both derive the same key shape from the table's
/// `selectionKeyBase`, so selection round-trips.
struct TableCellKey: Hashable {
    let base: AnyHashable
    let row: Int
    let col: Int
}

/// Composite key for a text inside a `ListFragment`.
struct ListTextKey: Hashable {
    let base: AnyHashable
    let textIdx: Int
}

// MARK: - Custom (escape hatch: CG drawing + click)

/// Escape hatch for one-off visuals (icons, animated chrome). `draw` is a
/// free function — no `self` capture (performance rule #2). `hit` is a
/// plain value describing what the row/controller should do when the frame
/// is clicked; the fragment itself never holds a callback.
struct CustomFragment {
    let frame: CGRect
    /// `bounds` = the fragment's frame. Caller has already scoped the CG
    /// state (saveGState). Implementation must be a static or free function
    /// — no `self` capture.
    let draw: (CGContext, CGRect) -> Void
    /// What action to fire when this fragment is clicked. `nil` → the frame
    /// is not interactive.
    let hit: HitAction?
}

// MARK: - Hit action

/// Value-type description of a click outcome. Returned by
/// `TranscriptRow.hit(at:)` so the caller (controller / selection
/// coordinator) can dispatch without peeking into row-specific state.
enum HitAction {
    /// Code block header was clicked — copy `code` to pasteboard; the
    /// owning row is expected to flash a transient checkmark at
    /// `segmentTag`.
    case copyCode(code: String, segmentTag: Int)
    /// Expand/collapse toggle (user bubble today; diff / tool blocks
    /// eventually).
    case toggleExpand(tag: AnyHashable)
}

// MARK: - Selectable regions (per-case dispatch)
//
// 关键约定：每种 fragment 自报选中单元 + 自己从 store **读**选中 range。这样
// FragmentPainter 完全 primitive——它只会 `fragment.selectionRange(from: row)`
// / `fragment.selectionMatrix(from: row)`，从不知道 `TableCellKey` / `ListTextKey`
// 的 schema。key 形状只活在这里。

extension Fragment {
    /// Produce the fragment's contribution to the row's selectable regions.
    func selectableRegions(
        rowStableId: AnyHashable,
        fragmentOrdinal: Int,
        store: SelectionStore
    ) -> [SelectableTextRegion] {
        switch self {
        case .rect, .line, .custom:
            return []

        case .text(let f):
            return f.selectableRegions(
                rowStableId: rowStableId,
                fragmentOrdinal: fragmentOrdinal,
                store: store)

        case .table(let f):
            return f.selectableRegions(
                rowStableId: rowStableId,
                fragmentOrdinal: fragmentOrdinal,
                store: store)

        case .list(let f):
            return f.selectableRegions(
                rowStableId: rowStableId,
                fragmentOrdinal: fragmentOrdinal,
                store: store)
        }
    }
}

extension TextFragment {
    func selectableRegions(
        rowStableId: AnyHashable,
        fragmentOrdinal: Int,
        store: SelectionStore
    ) -> [SelectableTextRegion] {
        guard let key = selectionKey, !layout.lines.isEmpty else { return [] }
        return [SelectableTextRegion(
            rowStableId: rowStableId,
            ordering: Ordering(fragmentOrdinal: fragmentOrdinal, subIndex: 0),
            mode: .flow,
            frameInRow: frame,
            layout: layout,
            setSelection: { [weak store] range in
                store?.setRange(range, for: key)
            })]
    }

    /// Paint-time read. Painter calls this—没有 `TextCellKey` 这类散装 schema
    /// 泄漏到 painter，key 只在 TextFragment 内部兑现。
    func selectionRange(from store: SelectionStore) -> NSRange? {
        guard let key = selectionKey,
              let r = store.range(for: key),
              r.location != NSNotFound, r.length > 0 else { return nil }
        return r
    }
}

extension TableFragment {
    func selectableRegions(
        rowStableId: AnyHashable,
        fragmentOrdinal: Int,
        store: SelectionStore
    ) -> [SelectableTextRegion] {
        guard let base = selectionKeyBase else { return [] }
        var out: [SelectableTextRegion] = []
        let cellFrames = layout.cellContentFrames
        var sub = 0
        for (r, rowFrames) in cellFrames.enumerated() {
            for (c, cellFrame) in rowFrames.enumerated() {
                let cellLayout = layout.cells[r][c]
                guard !cellLayout.lines.isEmpty else {
                    sub += 1
                    continue
                }
                let cellKey = TableCellKey(base: base, row: r, col: c)
                out.append(SelectableTextRegion(
                    rowStableId: rowStableId,
                    ordering: Ordering(fragmentOrdinal: fragmentOrdinal, subIndex: sub),
                    mode: .cell,
                    frameInRow: CGRect(
                        x: origin.x + cellFrame.origin.x,
                        y: origin.y + cellFrame.origin.y,
                        width: cellFrame.width,
                        height: cellFrame.height),
                    layout: cellLayout,
                    setSelection: { [weak store] range in
                        store?.setRange(range, for: cellKey)
                    }))
                sub += 1
            }
        }
        return out
    }

    /// Paint-time read. Returns a per-cell matrix to feed
    /// `TranscriptTableLayout.draw(selections:)`. `nil` → table is
    /// non-selectable or fully cleared.
    func selectionMatrix(from store: SelectionStore) -> [[NSRange]]? {
        guard let base = selectionKeyBase else { return nil }
        let rows = layout.cells.count
        guard rows > 0 else { return nil }
        let cols = layout.cells.first?.count ?? 0
        var any = false
        let matrix: [[NSRange]] = (0..<rows).map { r in
            (0..<cols).map { c in
                if let range = store.range(for: TableCellKey(base: base, row: r, col: c)),
                   range.location != NSNotFound, range.length > 0 {
                    any = true
                    return range
                }
                return NSRange(location: NSNotFound, length: 0)
            }
        }
        return any ? matrix : nil
    }
}

extension ListFragment {
    func selectableRegions(
        rowStableId: AnyHashable,
        fragmentOrdinal: Int,
        store: SelectionStore
    ) -> [SelectableTextRegion] {
        guard let base = selectionKeyBase else { return [] }
        var out: [SelectableTextRegion] = []
        for (textIdx, textLayout, originInList) in layout.flattenedTexts() {
            guard !textLayout.lines.isEmpty else { continue }
            let textKey = ListTextKey(base: base, textIdx: textIdx)
            out.append(SelectableTextRegion(
                rowStableId: rowStableId,
                ordering: Ordering(fragmentOrdinal: fragmentOrdinal, subIndex: textIdx),
                mode: .flow,
                frameInRow: CGRect(
                    x: origin.x + originInList.x,
                    y: origin.y + originInList.y,
                    width: max(textLayout.measuredWidth, 1),
                    height: max(textLayout.totalHeight, 1)),
                layout: textLayout,
                setSelection: { [weak store] range in
                    store?.setRange(range, for: textKey)
                }))
        }
        return out
    }

    /// Paint-time read. Closure for `TranscriptListLayout.draw(selectionResolver:)`.
    func selectionResolver(from store: SelectionStore) -> (Int) -> NSRange? {
        guard let base = selectionKeyBase else {
            return { _ in nil }
        }
        return { [weak store] idx in
            guard let r = store?.range(for: ListTextKey(base: base, textIdx: idx)),
                  r.location != NSNotFound, r.length > 0 else { return nil }
            return r
        }
    }
}

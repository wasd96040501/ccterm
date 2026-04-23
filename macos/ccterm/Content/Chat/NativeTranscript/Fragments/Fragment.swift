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
/// optional tags to opt into text-selection and syntax-highlight writeback,
/// both handled generically by the base ``TranscriptRow``.
struct TextFragment {
    let layout: TranscriptTextLayout
    let origin: CGPoint

    /// Non-nil → participates in text selection. The integer value is the
    /// region's sort key across the row (see ``SelectableTextRegion.regionIndex``).
    let selectionTag: Int?

    /// Non-nil → participates in highlight-writeback. The value is the tag
    /// the prepared item used in its ``HighlightContributingPrepared``
    /// requests; the base row routes tokens back to the matching fragment's
    /// owning prebuilt data.
    let highlightTag: Int?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.measuredWidth, 1),
               height: max(layout.totalHeight, 1))
    }

    init(layout: TranscriptTextLayout, origin: CGPoint,
         selectionTag: Int? = nil, highlightTag: Int? = nil) {
        self.layout = layout
        self.origin = origin
        self.selectionTag = selectionTag
        self.highlightTag = highlightTag
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
    /// Base sort key; per-cell regions are derived as
    /// `selectionTag * 1_000_000 + row * 1_000 + col`.
    /// `nil` → table is non-selectable.
    let selectionTag: Int?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.totalWidth, 1),
               height: max(layout.totalHeight, 1))
    }
}

struct ListFragment {
    let layout: TranscriptListLayout
    let origin: CGPoint
    /// Base sort key; per-text regions are derived as
    /// `selectionTag * 1_000_000 + textIdx`.
    /// `nil` → list is non-selectable.
    let selectionTag: Int?

    var frame: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: max(layout.measuredWidth, 1),
               height: max(layout.totalHeight, 1))
    }
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

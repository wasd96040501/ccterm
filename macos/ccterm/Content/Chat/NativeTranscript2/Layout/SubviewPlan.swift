import AppKit

/// Plan describing the AppKit-side adornments a row's cell should host
/// **on top of** its own CGContext draw — animated chevron glyphs and
/// layer-backed body subviews. Same "struct of values + closures" recipe
/// as `SelectionAdapter`: each layout that needs adornments builds a
/// `SubviewPlan` (today only `ToolGroupLayout`); the cell consumes the
/// plan through a generic reconciler that doesn't know which layout
/// produced it.
///
/// Why values, not protocol: the cell's reconcile loop is layout-
/// agnostic, and chevrons / entry subviews are the only two adornment
/// kinds we need. A protocol layer would push "what kinds of adornment
/// exist" out of the type and into runtime dispatch; the closed
/// `chevrons` / `entries` tuple keeps it visible and exhaustive without
/// erasing the layout type.
///
/// Coordinates: all `center` / `frame` are already in **cell-local**
/// coords. The layout offsets by the cell's `layoutOrigin` when it
/// builds the plan, so the cell does no coordinate math at reconcile
/// time.
struct SubviewPlan: @unchecked Sendable {
    /// Spinning glyphs attached to foldable headers. Order is not
    /// load-bearing; the reconciler keys by `id`.
    let chevrons: [Chevron]

    /// Layer-backed subviews, one per `bandRect`-shaped strip the
    /// layout wants animated independently of the row-height
    /// transition. Order is not load-bearing; the reconciler keys
    /// by `id` so AppKit's `view.animator().frame` interpolation
    /// reuses the same view across re-layouts.
    let entries: [Entry]

    /// Shimmer-overlay strips painted above the cell bitmap. Today
    /// only `ToolGroupLayout` emits these — one per running header
    /// (group or child) — and the reconciler stages a sweeping
    /// `CAGradientLayer` per id so the highlight band keeps cycling
    /// across `layout` swaps. Empty by default.
    let shimmers: [Shimmer]

    /// Trailing "running" indicator overlay. Emitted by
    /// `LoadingPillLayout` and rendered as a single `NSImageView`
    /// hosting the SF Symbol `ellipsis` driven by a
    /// `.variableColor.iterative.hideInactiveLayers` symbol effect —
    /// macOS 14+ ships the tuned three-dot sequence we need without
    /// hand-rolled keyframes. Reconciled as a single subview that
    /// survives `reloadData(forRowIndexes:)`, so the symbol-effect
    /// loop never restarts across re-layouts. `nil` when no pill is
    /// present.
    let loadingDots: LoadingDots?

    /// Live turn-token-usage counter drawn beside the running dots.
    /// Emitted by `LoadingPillLayout` when the turn has counted any
    /// tokens. Rendered in a dedicated `LoadingPillUsageView` (not the
    /// cell bitmap) so the digits can roll up — odometer style — as
    /// `setTurnUsage` reloads the pill row each tick. `nil` before any
    /// tokens accrue (and on non-pill rows).
    let usage: UsageCounter?

    static let empty = SubviewPlan(
        chevrons: [], entries: [], shimmers: [], loadingDots: nil, usage: nil)

    /// One spinning glyph attached to a foldable header. The cell
    /// owns a `CAShapeLayer` keyed by `id`, snaps `transform.rotation.z`
    /// to match `expanded`, and applies `strokeColor` / `opacity`
    /// straight from the spec. Chevron path / line width are cell-owned
    /// (chevron is cell decoration, not layout business) — only
    /// geometry + resolved tint lives in the plan.
    ///
    /// `strokeColor` and `alpha` are pre-resolved by the layout to
    /// reflect every per-header input (hover state, `ToolStatus`,
    /// theme). Keeping the resolution on the layout side lets the
    /// cell reconciler stay agnostic of status enums — adding a new
    /// status visual rule only touches `ToolGroupLayout`.
    struct Chevron: @unchecked Sendable {
        let id: UUID
        /// Chevron centre in cell-local coords.
        let center: CGPoint
        /// `true` → chevron points down (rotation = π/2); `false` →
        /// points right (rotation = 0).
        let expanded: Bool
        /// Stroke colour, already factoring in hover state and the
        /// header's `ToolStatus`. Dynamic `NSColor`s are fine here —
        /// `.cgColor` resolves against the cell's effective appearance.
        let strokeColor: NSColor
        /// Opacity, already factoring in hover state and `ToolStatus`.
        let alpha: CGFloat
    }

    /// One Apple-style shimmer surface painted **on top of** a
    /// running header's title (the cell bitmap always paints the
    /// static base title at the secondary tier; this overlay only
    /// adds the brightening sweep). Two layers cooperate:
    ///
    /// 1. A `CALayer` whose `contents` is a CGImage of the title
    ///    pre-rendered in the bright `.labelColor` palette using the
    ///    same `CTLine` typesetting the cell bitmap uses for the
    ///    base. The cell reconciler renders + caches the image
    ///    keyed by (title, font, appearance, scale, sub-pixel
    ///    offsets, aligned size).
    /// 2. A `CAGradientLayer` set as the `.mask` of layer 1 — colours
    ///    are fixed at `[α=0, α=1, α=0]` so the overlay is invisible
    ///    outside the moving stripe and fully opaque at the peak.
    ///    The mask's `locations` keyframe slides the peak from
    ///    off-screen-left to off-screen-right on a
    ///    `repeatCount = .infinity` loop.
    ///
    /// **Compositing model** (see `BlockStyle.toolHeaderShimmer*`):
    /// the secondary base text stays at full alpha in the cell
    /// bitmap. The overlay glyphs land at the same sub-pixel screen
    /// positions as the base (the reconciler injects an `xOffset`
    /// derived from the residual between `textRect.minX` and the
    /// pixel-aligned layer frame), so where the stripe peak crosses
    /// a glyph the labelColor pixels composite "over" the secondary
    /// pixels — labelColor wins, glyph edges stay sharp because the
    /// base never drops below full alpha.
    ///
    /// `textRect` is the title's bounding box in **cell-local** coords
    /// (origin = top-left, sized to glyph asc/descent). The
    /// reconciler pixel-aligns it against the host backing scale
    /// before assigning to the overlay layer's frame so CALayer
    /// never resamples the bitmap. `title` / `font` carry the
    /// content + typography needed to render that bitmap; the
    /// layout already produced the truncated display string at
    /// make-time, so the reconciler doesn't re-truncate.
    struct Shimmer: @unchecked Sendable {
        let id: UUID
        let textRect: CGRect
        let title: String
        let font: NSFont
        /// `true` when the cell's `hoveredAction` matches this header.
        /// The reconciler hides the overlay (`text.opacity = 0`) in
        /// that case because the cell-bitmap base title is already
        /// drawn at hover-tier `.labelColor` (via
        /// `titleColor(for:hovered:)`) — overlay would paint
        /// redundant pixels. The mask `locations` animation keeps
        /// cycling against the invisible layer so un-hovering picks
        /// up mid-cycle without a phase reset.
        let hovered: Bool
    }

    /// Trailing "running" indicator spec. The cell hosts a single
    /// `NSImageView` showing SF Symbol `ellipsis` with a variable-
    /// color symbol effect; `frame` is cell-local placement and
    /// `tintColor` is the resolved symbol fill.
    struct LoadingDots: @unchecked Sendable {
        let frame: CGRect
        let tintColor: NSColor
    }

    /// Live turn-token-usage spec. The cell hosts a single
    /// `LoadingPillUsageView` that renders `↑in ↓out` and rolls each
    /// number toward its new target. `frame` is cell-local placement;
    /// `inputTokens` / `outputTokens` are the raw (cache-excluded) turn
    /// totals — the view abbreviates and tweens them. `font` / `color`
    /// match the chrome tier the layout reserved width for.
    struct UsageCounter: @unchecked Sendable {
        let frame: CGRect
        let inputTokens: Int
        let outputTokens: Int
        let font: NSFont
        let color: NSColor
    }

    /// One layer-backed body subview. The cell hosts a
    /// `ToolGroupEntryView` keyed by `id`; reuse across layout swaps
    /// is what lets `view.animator().frame` slide entries during a
    /// fold transition.
    struct Entry: @unchecked Sendable {
        let id: UUID
        /// Subview frame in cell-local coords. Equals the layout's
        /// entry `bandRect` offset by `layoutOrigin`.
        let frame: CGRect
        /// View paints itself by invoking this closure from its own
        /// `draw(_:)`. `selectionColor` and the two search-highlight
        /// colours are supplied at draw time because they depend on
        /// `window.isKeyWindow`, a runtime cell-state, not a
        /// layout-build property. Search highlights composite over the
        /// selection band (same order as `BlockCellView.draw`): they
        /// MUST flow through this subview for the same reason selection
        /// does — the body subview is opaque-composited over the cell
        /// bitmap, so a highlight painted on the cell never reaches the
        /// screen (see `RowLayout.subviewPlan`'s note).
        ///
        /// `dirtyRect` is the AppKit-supplied draw region intersected
        /// with the view's `visibleRect`, expressed in **view-local**
        /// coords (origin = top-left of the entry view). Layouts that
        /// iterate per-row content (diff bodies, today) must skip rows
        /// whose painted rect doesn't intersect it — without this, an
        /// entry view whose total height exceeds the CALayer / IOSurface
        /// max-texture cap (≈ 16384 px on Apple Silicon, hit at ~700
        /// diff lines @ Retina) falls back to tile-on-demand drawing
        /// during scroll, calling `draw(_:)` with a tile-sized dirty
        /// rect on every scroll tick. A non-clipping body then repaints
        /// all rows on every tile, costing 50 ms per call regardless of
        /// dirty size, which caps the visible frame rate at ~17 fps.
        ///
        /// The closure captures the layout's immutable data and is safe
        /// to invoke from the view's draw path on the main thread.
        let draw:
            (
                _ ctx: CGContext, _ selectionColor: NSColor,
                _ searchActiveColor: NSColor, _ searchInactiveColor: NSColor,
                _ dirtyRect: CGRect
            ) -> Void
    }
}

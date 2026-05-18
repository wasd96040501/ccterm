import AppKit

/// One interactive hot zone in layout-local coords. Drives both cursor
/// swap (`resetCursorRects` registers `.pointingHand` over `rect`) and
/// click dispatch (`mouseDown` matches the point against `rect` and
/// runs `action`). Cell offsets `rect` by its draw origin before either
/// use; layouts emit hits in their own coordinate space.
struct InteractiveHit: Sendable {
    let rect: CGRect
    let action: HitAction
}

/// What clicking an `InteractiveHit` does. Three cases for three
/// independent behaviors — kept as a closed enum so the cell's
/// dispatch stays an exhaustive switch. Adding a fourth interaction
/// (e.g., "expand inline") = add a case here and a switch arm in
/// `BlockCellView.mouseDown`.
enum HitAction: Sendable, Equatable {
    /// `.link`-attributed run. Cell opens via `NSWorkspace.shared.open`.
    case openURL(URL)
    /// User-bubble chevron. Cell forwards to
    /// `Transcript2Coordinator.requestUserBubbleSheet(id:)` (the
    /// block id lives on the cell, not the layout).
    case openUserBubbleSheet
    /// Code-block copy button. Cell writes the payload to the
    /// general pasteboard and triggers its transient checkmark
    /// feedback.
    case copyText(String)
    /// Foldable header (toolGroup group or item header). Cell forwards
    /// to `Transcript2Coordinator.toggleFold(id:)`. The id may be the
    /// host block's own id (group header) or a nested child id
    /// (item header) — the coordinator scans the host blocks and
    /// their toolGroup children to find which row owns the toggle.
    case toggleFold(UUID)
}

/// Type-erased dispatch over the per-kind layout primitives. Holds whichever
/// `XxxLayout` value the block kind required, and exposes the things
/// downstream code asks for:
///
/// - `totalHeight` (consumed by `NSTableView.heightOfRow`)
/// - `measuredWidth` (used by the layout cache to detect width changes)
/// - `draw(in:origin:)` (invoked by the cell's `draw(_:)`)
/// - `selectionAdapter` / `iBeamRect` / `interactiveHits` (consumed
///   by the cell for selection + cursor rects + click dispatch)
///
/// Add a new layout primitive: add the case here, extend each method.
/// The cell view is enum-agnostic — it doesn't switch on cases, only
/// calls these uniform APIs.
enum RowLayout: @unchecked Sendable {
    case text(TextLayout)
    case image(ImageLayout)
    case list(ListLayout)
    case table(TableLayout)
    case codeBlock(CodeBlockLayout)
    case blockquote(BlockquoteLayout)
    case thematicBreak(ThematicBreakLayout)
    case userBubble(UserBubbleLayout)
    case toolGroup(ToolGroupLayout)
    case loadingPill(LoadingPillLayout)

    var totalHeight: CGFloat {
        switch self {
        case .text(let l): return l.totalHeight
        case .image(let l): return l.totalHeight
        case .list(let l): return l.totalHeight
        case .table(let l): return l.totalHeight
        case .codeBlock(let l): return l.totalHeight
        case .blockquote(let l): return l.totalHeight
        case .thematicBreak(let l): return l.totalHeight
        case .userBubble(let l): return l.totalHeight
        case .toolGroup(let l): return l.totalHeight
        case .loadingPill(let l): return l.totalHeight
        }
    }

    var measuredWidth: CGFloat {
        switch self {
        case .text(let l): return l.measuredWidth
        case .image(let l): return l.measuredWidth
        case .list(let l): return l.measuredWidth
        case .table(let l): return l.measuredWidth
        case .codeBlock(let l): return l.measuredWidth
        case .blockquote(let l): return l.measuredWidth
        case .thematicBreak(let l): return l.measuredWidth
        case .userBubble(let l): return l.measuredWidth
        case .toolGroup(let l): return l.measuredWidth
        case .loadingPill(let l): return l.measuredWidth
        }
    }

    /// Layout-local y where a gutter glyph should be vertically centered
    /// so it baseline-aligns with the first line of content. Defined as
    /// the midpoint of the first text line's band (`baseline + (descent
    /// - ascent) / 2`); for layouts without text first-line semantics
    /// (image, thematic break, tool group header, loading pill) we
    /// return `totalHeight / 2` — those layouts don't emit gutters
    /// anyway, the value is only reached when the cell asks defensively.
    var firstLineCenterY: CGFloat {
        switch self {
        case .text(let l):
            guard let baseline = l.lineOrigins.first?.y,
                let m = l.lineMetrics.first
            else { return l.totalHeight / 2 }
            return baseline + (m.descent - m.ascent) / 2
        case .userBubble(let l):
            guard let baseline = l.lineOrigins.first?.y,
                let m = l.lineMetrics.first
            else { return l.bubbleRect.midY }
            // `textOriginInRow.y` is already in layout-local coords;
            // `lineOrigins[0].y` is text-local. Sum + line-band midY.
            return l.textOriginInRow.y + baseline
                + (m.descent - m.ascent) / 2
        case .blockquote(let l):
            guard let baseline = l.text.lineOrigins.first?.y,
                let m = l.text.lineMetrics.first
            else { return l.totalHeight / 2 }
            return l.textOriginInLayout.y + baseline
                + (m.descent - m.ascent) / 2
        case .codeBlock(let l):
            // Align gutter to the **header band** rather than the first
            // code line — the gutter sits in the row margin and reads
            // as "this is a code block, copy it"; aligning to the
            // chrome strip puts it at the same y as the in-header
            // language label / copy glyph and reads as a sibling
            // affordance.
            return l.headerRect.midY
        case .list(let l):
            // Per-item `markerCenterY` is documented as "midY of the
            // first content line"; the first item carries the global
            // first line.
            return l.items.first?.markerCenterY ?? l.totalHeight / 2
        case .table(let l):
            // First row is the header. Center on its band — the first
            // cell's text is vertically padded by `tableCellVerticalPadding`
            // but a header-row midY aligns visually well enough for a
            // gutter glyph (the table cells stack uniformly).
            return (l.rowHeights.first ?? l.totalHeight) / 2
        case .image(let l): return l.totalHeight / 2
        case .thematicBreak(let l): return l.totalHeight / 2
        case .toolGroup(let l): return l.totalHeight / 2
        case .loadingPill(let l): return l.totalHeight / 2
        }
    }

    /// Opaque chrome that must paint *before* the cell's selection band
    /// so the highlight composites on top, under the glyphs. Default is
    /// a no-op — only codeblock and toolGroup item bodies have an
    /// opaque card background that would otherwise hide the selection
    /// rect drawn by the cell.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        switch self {
        case .codeBlock(let l): l.drawBackplate(in: ctx, origin: origin)
        case .toolGroup(let l): l.drawBackplate(in: ctx, origin: origin)
        default: break
        }
    }

    /// `hoveredAction` is `nil` when no `interactiveHits` rect is
    /// currently under the cursor. Layouts that care about hover (today:
    /// `toolGroup`'s headers, which brighten title in hover state) read
    /// this and decide per-sub-region whether to draw in hover state.
    /// Layouts that don't care (everything else) ignore the parameter.
    ///
    /// Chevron glyphs are *not* drawn by `draw` — the cell positions a
    /// `CAShapeLayer` per chevron from each header's `chevronCenter`
    /// and animates `transform.rotation.z` via `CABasicAnimation`.
    /// `ToolGroupLayout.draw` only emits header titles into the CGContext.
    func draw(in ctx: CGContext, origin: CGPoint, hoveredAction: HitAction?) {
        switch self {
        case .text(let l): l.draw(in: ctx, origin: origin)
        case .image(let l): l.draw(in: ctx, origin: origin)
        case .list(let l): l.draw(in: ctx, origin: origin)
        case .table(let l): l.draw(in: ctx, origin: origin)
        case .codeBlock(let l): l.draw(in: ctx, origin: origin)
        case .blockquote(let l): l.draw(in: ctx, origin: origin)
        case .thematicBreak(let l): l.draw(in: ctx, origin: origin)
        case .userBubble(let l): l.draw(in: ctx, origin: origin)
        case .toolGroup(let l):
            l.draw(in: ctx, origin: origin, hoveredAction: hoveredAction)
        case .loadingPill(let l): l.draw(in: ctx, origin: origin)
        }
    }

    /// Region that should show the I-beam cursor on hover, in
    /// layout-local coords. `nil` means "the whole cell `bounds`" —
    /// matches `NSTextView`'s behavior of I-beam over the full frame
    /// for ordinary text blocks. Right-aligned / non-full-width
    /// layouts (currently: user bubble) override to confine the
    /// I-beam to their actual content rect, so empty gutter space
    /// outside the bubble keeps the default arrow.
    var iBeamRect: CGRect? {
        switch self {
        case .userBubble(let l): return l.bubbleRect
        // toolGroup falls through to default (`nil`) — its
        // `selectionAdapter` is also `nil`, so the I-beam path is
        // skipped entirely. Header hits register `pointingHand`
        // through `interactiveHits`.
        default: return nil
        }
    }

    /// Interactive hot zones in layout-local coords — links + cell-
    /// internal controls (user bubble chevron, code-block copy
    /// button), unified as `(rect, action)`. The cell iterates this
    /// list once for `resetCursorRects` (every entry → pointing-
    /// hand) and once for `mouseDown` (first hit wins; switch on
    /// `action`). List / table / blockquote layouts have already
    /// flattened their inner-cell links into container-local coords
    /// during `make`, so they roll up here without further transform.
    var interactiveHits: [InteractiveHit] {
        var hits: [InteractiveHit] = []
        let links: [TextLayout.LinkHit]
        switch self {
        case .text(let l): links = l.links
        case .list(let l): links = l.links
        case .table(let l): links = l.links
        case .codeBlock(let l): links = l.links
        case .blockquote(let l): links = l.links
        case .toolGroup(let l): links = l.links
        case .image, .thematicBreak, .userBubble, .loadingPill: links = []
        }
        hits.append(
            contentsOf: links.map {
                InteractiveHit(rect: $0.rect, action: .openURL($0.url))
            })
        switch self {
        case .userBubble(let l):
            if let r = l.chevronHitRect {
                hits.append(InteractiveHit(rect: r, action: .openUserBubbleSheet))
            }
        case .codeBlock(let l):
            if let r = l.copyHitRect {
                hits.append(InteractiveHit(rect: r, action: .copyText(l.code)))
            }
        case .toolGroup(let l):
            hits.append(contentsOf: l.interactiveHits)
        default:
            break
        }
        return hits
    }

    /// Selection-facing API for this row, or `nil` for non-selectable
    /// kinds (image, thematic break). The selection coordinator and cell
    /// view consume only this — the underlying `TextLayout` /
    /// `TableLayout` / `ListLayout` type is encapsulated, so adding a new
    /// selectable kind needs no changes outside the new layout's own
    /// file.
    var selectionAdapter: SelectionAdapter? {
        switch self {
        case .text(let l): return l.selectionAdapter
        case .table(let l): return l.selectionAdapter
        case .list(let l): return l.selectionAdapter
        case .codeBlock(let l): return l.selectionAdapter
        case .blockquote(let l): return l.selectionAdapter
        case .image: return nil
        case .thematicBreak: return nil
        case .userBubble(let l): return l.selectionAdapter
        case .toolGroup(let l): return l.selectionAdapter
        case .loadingPill: return nil
        }
    }

    /// Adornments this row wants the cell to host on top of its own
    /// CGContext draw — animated chevron glyphs (`CAShapeLayer`) and
    /// layer-backed body subviews (`ToolGroupEntryView`). See
    /// `SubviewPlan` for the recipe. Default is an empty plan; only
    /// `toolGroup` opts in today.
    ///
    /// The cell rebuilds the plan whenever `layout`, `hoveredAction`,
    /// `selection`, or `padTop` (= `layoutOrigin`) changes, then runs
    /// a generic reconcile pass against it. Selection rect duplication
    /// across cell main bitmap and entry subviews is harmless — the
    /// `bandRect`-sized subviews necessarily cover every selection
    /// rect the layout emits (selection is constrained to expanded
    /// body content), so the cell-bitmap copy is composited under
    /// the subview and never reaches the screen.
    func subviewPlan(
        origin: CGPoint,
        hoveredAction: HitAction?,
        selection: SelectionRange?
    ) -> SubviewPlan {
        switch self {
        case .toolGroup(let l):
            return l.subviewPlan(
                origin: origin,
                hoveredAction: hoveredAction,
                selection: selection)
        case .loadingPill(let l):
            // The indicator hosts a single `NSImageView` running an
            // SF Symbol `.variableColor` effect. The reconciler
            // creates / reuses the view per cell; the symbol effect
            // loop survives `reloadData(forRowIndexes:)` because the
            // view itself is reused, not the spec.
            return SubviewPlan(
                chevrons: [], entries: [], shimmers: [],
                loadingDots: SubviewPlan.LoadingDots(
                    frame: l.symbolFrame.offsetBy(
                        dx: origin.x, dy: origin.y),
                    tintColor: BlockStyle.loadingPillDotColor))
        default:
            return .empty
        }
    }
}

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
        case .image, .thematicBreak, .userBubble: links = []
        }
        hits.append(contentsOf: links.map {
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
        }
    }

    /// `true` when this row is a `.toolGroup`. The cell uses this to
    /// route selection painting into per-entry subviews (where the
    /// expanded body cards live) instead of the cell's main bitmap —
    /// otherwise the cell-drawn highlight would land *behind* the
    /// subview rather than under the body glyphs.
    var isToolGroup: Bool {
        if case .toolGroup = self { return true }
        return false
    }
}

import AppKit
import CoreText

/// Immutable row layout for `Block.Kind.toolGroup`.
///
/// One row contains everything: group header, every item header, every
/// expanded item's hunks body. Three independently-foldable layers
/// share `Transcript2Coordinator.foldStates` — the group itself is
/// keyed by the host `Block.id`, each item by its `ToolGroupBlock.Item.id`.
///
/// ### Visual stack
///
/// ```
/// ┌──────────────────────────────────────────────────┐ row top
/// │ Edited 3 files                              ▸ │ ← group header
/// └──────────────────────────────────────────────────┘
///                                                       ↑ group folded → ends here
/// ┌──────────────────────────────────────────────────┐ group expanded:
/// │ Sources/Greeter.swift                       ▸ │ ← item header (folded item)
/// │ config/server.yaml                          ▾ │ ← item header (expanded item)
/// │ ╭──────────────────────────────────────────╮  │
/// │ │ 1  port: 8080                            │  │ ← DiffLayout body
/// │ │ 2  host: localhost                       │  │
/// │ │ …                                        │  │
/// │ ╰──────────────────────────────────────────╯  │
/// │ scripts/cleanup.sh                          ▸ │ ← item header (folded)
/// └──────────────────────────────────────────────────┘
/// ```
///
/// Group and item headers share one geometry — `BlockStyle.toolHeader*`.
/// Item-body cards are `DiffLayout` values pre-positioned at the
/// correct `(x, y)` so the draw pass just forwards into them.
///
/// `@unchecked Sendable`: holds `CTLine` references inside header
/// glyphs and inside each `DiffLayout`'s rows (same posture as
/// `TextLayout`).
struct ToolGroupLayout: @unchecked Sendable {
    let blockId: UUID
    let isExpanded: Bool

    // MARK: Group header
    let groupHeader: Header
    /// Per-item entry — header glyphs + optional expanded body.
    let items: [Entry]

    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    /// Pre-baked hit zones (group header + every item header), each
    /// firing `HitAction.toggleFold(id)` against the matching block /
    /// item id.
    let interactiveHits: [InteractiveHit]

    /// Diff has no inline links and no inline selection today.
    var links: [TextLayout.LinkHit] { [] }

    /// Selection unsupported for now.
    var selectionAdapter: SelectionAdapter? { nil }

    // MARK: - Inner types

    /// A single header band (group title or item file path).
    ///
    /// `title` is kept as a raw `String` (not just a `CTLine`) because
    /// hover toggles the foreground colour to `.labelColor`; CTLines
    /// bake colour into their runs, so we retypeset on draw rather
    /// than carrying two colour variants. Title width is already
    /// resolved at make-time, so the retypeset is bounded by what
    /// fits in the band.
    ///
    /// `foldId` is the UUID that this header's hit-action toggles —
    /// the group's host `Block.id` for the group header, the
    /// `Child.id` for a child header. The draw pass matches against
    /// the cell's `hoveredAction` to decide which header to paint in
    /// hover state.
    struct Header: @unchecked Sendable {
        let foldId: UUID
        /// Whole header rect in layout-local coords.
        let rect: CGRect
        /// Display text (already truncated to fit the band).
        let title: String
        /// Width budget reserved for the title (≤ band width − chevron
        /// allowance). Used at draw time to clamp the retypeset line
        /// when hover repaints kick in.
        let titleWidth: CGFloat
        /// Baseline origin for `CTLine.draw`.
        let titleOrigin: CGPoint
        /// Centre of the chevron glyph — drawn at runtime so rotation
        /// can track the fold flag without a rebuild.
        let chevronCenter: CGPoint
        /// `true` → chevron points down; `false` → chevron points right.
        let chevronExpanded: Bool
    }

    /// Per-child layout. The body is `nil` when the child is folded
    /// (or when its body layout happens to be empty); when present,
    /// it's already positioned at the right `(x, y)` for the draw
    /// pass to forward straight in.
    struct Entry: @unchecked Sendable {
        let childId: UUID
        let header: Header
        let body: ToolGroupChildLayout?
    }

    // MARK: - Factory

    nonisolated static func make(
        blockId: UUID,
        group: ToolGroupBlock,
        foldStates: [UUID: Bool],
        lineMaps: [UUID: [String: [SyntaxToken]]],
        maxWidth: CGFloat
    ) -> ToolGroupLayout {
        guard maxWidth > 0 else {
            return ToolGroupLayout(
                blockId: blockId, isExpanded: false,
                groupHeader: emptyHeader(foldId: blockId),
                items: [],
                totalHeight: 0, measuredWidth: 0,
                interactiveHits: [])
        }

        let groupExpanded = foldStates[blockId] ?? false

        // Group header sits flush at the row's top-left (the cell's
        // `layoutOrigin.y` already supplies the row top padding, so
        // layout-local y starts at 0).
        var y: CGFloat = 0
        let groupHeader = makeHeader(
            foldId: blockId,
            title: group.title,
            chevronExpanded: groupExpanded,
            y: y,
            maxWidth: maxWidth)
        y += BlockStyle.toolHeaderHeight

        var hits: [InteractiveHit] = []
        hits.append(InteractiveHit(
            rect: hitRect(over: groupHeader, maxWidth: maxWidth),
            action: .toggleFold(blockId)))

        var entries: [Entry] = []

        if groupExpanded {
            // `toolHeaderChildSpacing` (4pt) sits between every pair
            // of adjacent vertical elements: group header → first
            // child header, child header → its expanded body, body →
            // next child header, child header → next child header.
            // Matches the old `GroupComponent.groupChildSpacing`.
            for child in group.children {
                y += BlockStyle.toolHeaderChildSpacing
                let childExpanded = foldStates[child.id] ?? false
                let childHeader = makeHeader(
                    foldId: child.id,
                    title: child.headerLabel,
                    chevronExpanded: childExpanded,
                    y: y,
                    maxWidth: maxWidth)
                y += BlockStyle.toolHeaderHeight
                hits.append(InteractiveHit(
                    rect: hitRect(over: childHeader, maxWidth: maxWidth),
                    action: .toggleFold(child.id)))

                let body: ToolGroupChildLayout?
                if childExpanded {
                    let bodyY = y + BlockStyle.toolHeaderChildSpacing
                    let layout = ToolGroupChildLayout.make(
                        child: child,
                        lineMap: lineMaps[child.id],
                        originX: 0,
                        originY: bodyY,
                        maxWidth: maxWidth)
                    let h = layout.totalHeight
                    if h > 0 {
                        y = bodyY + h
                        body = layout
                    } else {
                        // Empty body — treat like folded for layout
                        // purposes so the next child doesn't gain an
                        // extra phantom gap below an invisible card.
                        body = nil
                    }
                } else {
                    body = nil
                }
                entries.append(Entry(childId: child.id,
                                     header: childHeader,
                                     body: body))
            }
        }

        return ToolGroupLayout(
            blockId: blockId,
            isExpanded: groupExpanded,
            groupHeader: groupHeader,
            items: entries,
            totalHeight: y,
            measuredWidth: maxWidth,
            interactiveHits: hits)
    }

    // MARK: - Header geometry

    nonisolated private static func makeHeader(
        foldId: UUID,
        title: String,
        chevronExpanded: Bool,
        y: CGFloat,
        maxWidth: CGFloat
    ) -> Header {
        let height = BlockStyle.toolHeaderHeight
        let font = BlockStyle.toolHeaderFont
        let chevron = BlockStyle.toolHeaderChevronSize
        let gap = BlockStyle.toolHeaderChevronGap
        let midY = y + height / 2

        let rect = CGRect(x: 0, y: y, width: maxWidth, height: height)

        // Title at `x = 0` (layout-local; the cell's `layoutOrigin.x`
        // already supplies the row's horizontal padding). Width
        // budget reserves `chevron + gap` on the right edge.
        let reserved = chevron + gap
        let titleBudget = max(0, maxWidth - reserved)

        let displayTitle: String
        let titleWidth: CGFloat
        if titleBudget > 0 {
            // Trim leading path components (`Sources/Foo/Bar.swift`
            // → `…/Bar.swift`) when the band can't fit the full
            // string. The basename — the part the eye scans for — is
            // preserved, matching `web/src/utils/displayPath.ts`'s
            // behavior on the React side.
            displayTitle = truncateHead(title, budget: titleBudget, font: font)
            titleWidth = min(textWidth(displayTitle, attrs: [.font: font]),
                             titleBudget)
        } else {
            displayTitle = ""
            titleWidth = 0
        }

        // Title baseline: same calculation as the old `GroupComponent`
        // — midY-anchored using `ascender + descender`. Works for any
        // toolHeader font.
        let titleBaseline = midY + (font.ascender + font.descender) / 2
        let titleOrigin = CGPoint(x: 0, y: titleBaseline)

        // Chevron sits immediately after the title (gestalt: attached
        // to the title it discloses).
        //
        // `visualCompensation = max(0, (capHeight - xHeight) / 2)` is
        // the same nudge the old `GroupComponent` applied so the
        // chevron's bounding-box centre lands on the title's *visual*
        // midline (the glyphs' x-height band) rather than the band's
        // geometric midline. Without it the chevron reads as floating
        // slightly above the title.
        let visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)
        let chevronX = min(titleWidth + gap + chevron / 2,
                           maxWidth - chevron / 2)
        let chevronCenter = CGPoint(
            x: chevronX,
            y: midY + visualCompensation)

        return Header(
            foldId: foldId,
            rect: rect,
            title: displayTitle,
            titleWidth: titleWidth,
            titleOrigin: titleOrigin,
            chevronCenter: chevronCenter,
            chevronExpanded: chevronExpanded)
    }

    /// Hit rect for a header — matches the old `GroupComponent`:
    /// `hitPadding` outset around `[title.minX, chevron.maxX]`, full
    /// header height. Spans only as wide as the title + chevron span
    /// so empty trailing space on long bands doesn't toggle fold.
    nonisolated private static func hitRect(
        over header: Header, maxWidth: CGFloat
    ) -> CGRect {
        let pad = BlockStyle.toolHeaderHitPadding
        let chevron = BlockStyle.toolHeaderChevronSize
        let titleMinX = header.rect.minX
        let chevronMaxX = header.chevronCenter.x + chevron / 2
        let minX = max(header.rect.minX, titleMinX - pad)
        let maxX = min(header.rect.maxX, chevronMaxX + pad)
        return CGRect(
            x: minX,
            y: header.rect.minY,
            width: max(0, maxX - minX),
            height: header.rect.height)
    }

    nonisolated private static func emptyHeader(foldId: UUID) -> Header {
        Header(foldId: foldId, rect: .zero, title: "", titleWidth: 0,
               titleOrigin: .zero, chevronCenter: .zero, chevronExpanded: false)
    }

    /// Trim leading path components until the remainder fits `budget`
    /// at `font`. Prepends `…/` once a trim happens.
    nonisolated private static func truncateHead(
        _ path: String, budget: CGFloat, font: NSFont
    ) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if textWidth(path, attrs: attrs) <= budget { return path }

        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return path }
        for drop in 1..<parts.count {
            let kept = parts[drop...].joined(separator: "/")
            let candidate = "…/" + kept
            if textWidth(candidate, attrs: attrs) <= budget {
                return candidate
            }
        }
        return "…/" + (parts.last.map(String.init) ?? path)
    }

    nonisolated private static func textWidth(
        _ s: String, attrs: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    // MARK: - Draw

    /// Background passes for every expanded item body — forwarded into
    /// `DiffLayout.drawBackplate`. Headers have no fill so there's
    /// nothing else to paint here.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {
        for entry in items {
            entry.body?.drawBackplate(in: ctx, origin: origin)
        }
    }

    func draw(in ctx: CGContext, origin: CGPoint, hoveredAction: HitAction?) {
        let hoveredId = Self.hoveredFoldId(in: hoveredAction)
        drawHeader(groupHeader, hovered: hoveredId == groupHeader.foldId,
                   in: ctx, origin: origin)
        for entry in items {
            drawHeader(entry.header,
                       hovered: hoveredId == entry.header.foldId,
                       in: ctx, origin: origin)
            entry.body?.draw(in: ctx, origin: origin)
        }
    }

    /// Extract the fold id from a hovered hit action, or `nil` if the
    /// cursor is over an unrelated hit (URL link, copy button, etc.).
    private static func hoveredFoldId(in action: HitAction?) -> UUID? {
        guard let action else { return nil }
        if case .toggleFold(let id) = action { return id }
        return nil
    }

    private func drawHeader(_ header: Header,
                            hovered: Bool,
                            in ctx: CGContext,
                            origin: CGPoint)
    {
        let titleColor: NSColor = hovered
            ? BlockStyle.toolHeaderHoverForeground
            : BlockStyle.toolHeaderForeground
        let chevronAlpha: CGFloat = hovered
            ? BlockStyle.toolHeaderChevronHoverAlpha
            : BlockStyle.toolHeaderChevronIdleAlpha

        // Retypeset on draw so the hover-driven `foregroundColor`
        // swap doesn't require a layout rebuild. Title text was
        // already truncated to fit at make-time, so this is a single
        // CTLine constructor over a known-bounded string.
        if !header.title.isEmpty {
            let attr = NSAttributedString(string: header.title, attributes: [
                .font: BlockStyle.toolHeaderFont,
                .foregroundColor: titleColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: origin.x + header.titleOrigin.x,
                y: origin.y + header.titleOrigin.y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        drawChevron(at: header.chevronCenter,
                    expanded: header.chevronExpanded,
                    color: titleColor,
                    alpha: chevronAlpha,
                    in: ctx, origin: origin)
    }

    /// Two-segment `>` stroke path, rotated to point right (folded)
    /// or down (expanded). Identical visual recipe to the old
    /// `GroupSideCar.chevronPath` — bounding box has `halfW = size *
    /// 0.22`, `halfH = size * 0.4`, drawn with `lineWidth = 1.4` and
    /// `round` line cap / join. Colour and alpha are the same tint
    /// the title uses (so hover lifts both in lockstep).
    private func drawChevron(at center: CGPoint,
                             expanded: Bool,
                             color: NSColor,
                             alpha: CGFloat,
                             in ctx: CGContext,
                             origin: CGPoint)
    {
        let size = BlockStyle.toolHeaderChevronSize
        let halfW = size * 0.22
        let halfH = size * 0.4
        let cx = origin.x + center.x
        let cy = origin.y + center.y

        ctx.saveGState()
        // Translate to chevron centre, then rotate. AppKit's flipped
        // coord system means `+y` points down; rotating `+π/2` flips
        // a right-pointing chevron to a down-pointing one (folded →
        // expanded), matching the old SideCar's rotation direction.
        ctx.translateBy(x: cx, y: cy)
        if expanded {
            ctx.rotate(by: .pi / 2)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -halfW, y: -halfH))
        path.addLine(to: CGPoint(x: halfW, y: 0))
        path.addLine(to: CGPoint(x: -halfW, y: halfH))

        ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(BlockStyle.toolHeaderChevronLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

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

    /// Selection-facing API. Selection is restricted to expanded
    /// `fileEdit` body content (gutter / sign columns are not
    /// selectable). Positions are `LayoutPosition.diff(childIndex:char:)`;
    /// the adapter routes per-body operations to the matching
    /// `DiffLayout` and returns empty when caller passes
    /// cross-body or non-`.diff` endpoints.
    var selectionAdapter: SelectionAdapter? {
        let bodies: [(childIndex: Int, diff: DiffLayout)] = items.enumerated()
            .compactMap { idx, entry in
                guard let body = entry.body else { return nil }
                switch body {
                case .fileEdit(let l):
                    let d = l.body
                    guard !d.containerRect.isEmpty else { return nil }
                    return (idx, d)
                }
            }
        guard !bodies.isEmpty else { return nil }

        func diff(for index: Int) -> DiffLayout? {
            bodies.first(where: { $0.childIndex == index })?.diff
        }

        // `fullRange` and `unitRange` both span just the *first* body
        // — Cmd+A and triple-click then pick whichever body the
        // caller passes in. Drag-selection across bodies isn't
        // modelled; the adapter's hitTest snaps the cursor into the
        // single body whose y band it lands in.
        let firstChildIndex = bodies[0].childIndex
        let firstDiff = bodies[0].diff
        let fullRange = SelectionRange(
            start: .diff(childIndex: firstChildIndex, char: 0),
            end: .diff(childIndex: firstChildIndex, char: firstDiff.contentLength))

        return SelectionAdapter(
            fullRange: fullRange,
            unitRange: { p in
                guard case .diff(let i, _) = p,
                      let d = diff(for: i)
                else { return fullRange }
                return SelectionRange(
                    start: .diff(childIndex: i, char: 0),
                    end: .diff(childIndex: i, char: d.contentLength))
            },
            hitTest: { point in
                // Snap to whichever body's y band contains the point
                // (or, when between bodies, the closest one). Empty
                // bodies aren't included in `bodies`, so the snap is
                // always to a real, selectable body.
                let preferred = bodies.first(where: {
                    point.y >= $0.diff.containerRect.minY
                        && point.y <= $0.diff.containerRect.maxY
                }) ?? bodies.min(by: {
                    let d0 = min(abs(point.y - $0.diff.containerRect.minY),
                                 abs(point.y - $0.diff.containerRect.maxY))
                    let d1 = min(abs(point.y - $1.diff.containerRect.minY),
                                 abs(point.y - $1.diff.containerRect.maxY))
                    return d0 < d1
                })!
                let char = preferred.diff.hitTest(point: point)
                return .diff(childIndex: preferred.childIndex, char: char)
            },
            rects: { a, b in
                guard case .diff(let ia, let ca) = a,
                      case .diff(let ib, let cb) = b,
                      ia == ib,
                      let d = diff(for: ia)
                else { return [] }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                return d.rects(loChar: lo, hiChar: hi)
            },
            string: { a, b in
                guard case .diff(let ia, let ca) = a,
                      case .diff(let ib, let cb) = b,
                      ia == ib,
                      let d = diff(for: ia)
                else { return "" }
                let lo = min(ca, cb)
                let hi = max(ca, cb)
                return d.string(loChar: lo, hiChar: hi)
            },
            wordBoundary: { p in
                guard case .diff(let i, let c) = p,
                      let d = diff(for: i),
                      let word = d.wordBoundary(at: c)
                else { return nil }
                return SelectionRange(
                    start: .diff(childIndex: i, char: word.location),
                    end: .diff(childIndex: i, char: word.location + word.length))
            })
    }

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
    ///
    /// `bandRect` is the entry's full vertical band in layout-local
    /// coords — top includes the `toolHeaderChildSpacing` leading
    /// gap, bottom is either the header's bottom (folded) or the body
    /// card's bottom (expanded). Adjacent entries' bands tile without
    /// gaps. The cell stages one layer-backed subview per entry sized
    /// to `bandRect` so AppKit's `NSAnimationContext` slides each
    /// entry's frame when an upstream sibling expands/collapses —
    /// inside a single row the row-height transition alone gives a
    /// pop, only per-entry frame animation produces the slide.
    struct Entry: @unchecked Sendable {
        let childId: UUID
        let header: Header
        let body: ToolGroupChildLayout?
        let bandRect: CGRect
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
                // Track the entry's band start *before* the leading
                // spacing so adjacent entries' bands tile without
                // gaps — the per-entry subview in the cell carries
                // the gap on its top edge, which keeps neighbour
                // sliding visually flush as one slides past the
                // other.
                let entryStartY = y
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
                let bandRect = CGRect(
                    x: 0, y: entryStartY,
                    width: maxWidth, height: y - entryStartY)
                entries.append(Entry(childId: child.id,
                                     header: childHeader,
                                     body: body,
                                     bandRect: bandRect))
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
    //
    // The cell paints the toolGroup row in two passes:
    //
    //   1. Cell's main bitmap renders the **group header** only.
    //      `drawBackplate` is a no-op (group header has no fill).
    //      `draw` paints the group header title; the chevron is a
    //      `CAShapeLayer` sublayer of the cell.
    //   2. Each entry's content (child header + optional body) is
    //      rendered into a per-entry layer-backed NSView subview
    //      (`ToolGroupEntryView`) sized to `entry.bandRect`. The
    //      subview invokes the per-entry `draw` closure carried by
    //      its `SubviewPlan.Entry` spec; that closure captures the
    //      entry's data and routes through `drawEntry(...)` below
    //      with view-local coords.
    //
    // The split exists so AppKit can slide each entry's subview
    // frame when an upstream sibling expands/collapses
    // (`NSAnimationContext` on `view.animator().frame = newFrame` is
    // the AppKit-blessed per-view animation primitive). Rendering
    // everything into the cell's single bitmap, as the previous
    // pass did, gives `CATransition.fade` at best — entries below
    // the toggling child pop into place rather than slide.

    /// No-op. Entry bodies own their backplate inside their own
    /// subview's draw pass; the group header has no fill.
    func drawBackplate(in ctx: CGContext, origin: CGPoint) {}

    /// Paints the group header title only. Child entries are
    /// rendered by their own subviews via the `draw` closures their
    /// `SubviewPlan.Entry` specs carry.
    func draw(in ctx: CGContext, origin: CGPoint, hoveredAction: HitAction?) {
        let hoveredId = Self.hoveredFoldId(in: hoveredAction)
        Self.drawHeader(groupHeader,
                        hovered: hoveredId == groupHeader.foldId,
                        in: ctx, origin: origin)
    }

    /// Render one `Entry` into `ctx` in **view-local** coords —
    /// `entry.bandRect.origin` maps to (0, 0) of the receiving
    /// subview, so we offset every internal call by `-bandRect.origin`.
    ///
    /// `selectionRects` is in layout-local coords (the toolGroup
    /// layout's frame); only rects that intersect `entry.bandRect`
    /// paint. Called from `subviewPlan`'s per-entry capture closure;
    /// `ToolGroupEntryView` itself is layout-agnostic and invokes the
    /// closure rather than reaching for this method directly.
    nonisolated private static func drawEntry(
        _ entry: Entry,
        hovered: Bool,
        selectionRects: [CGRect],
        selectionColor: NSColor,
        in ctx: CGContext
    ) {
        let dx = -entry.bandRect.minX
        let dy = -entry.bandRect.minY
        let originForBody = CGPoint(x: dx, y: dy)

        // 1. Body backplate (rounded container + line/gutter bg).
        entry.body?.drawBackplate(in: ctx, origin: originForBody)

        // 2. Selection band — under glyphs, above backplate.
        let bandRect = entry.bandRect
        let filtered = selectionRects.filter { bandRect.intersects($0) }
        if !filtered.isEmpty {
            ctx.setFillColor(selectionColor.cgColor)
            for r in filtered {
                ctx.fill(r.offsetBy(dx: dx, dy: dy).integral)
            }
        }

        // 3. Body glyphs.
        entry.body?.draw(in: ctx, origin: originForBody)

        // 4. Child header title.
        drawHeader(entry.header,
                   hovered: hovered,
                   in: ctx, origin: originForBody)
    }

    /// Extract the fold id from a hovered hit action, or `nil` if the
    /// cursor is over an unrelated hit (URL link, copy button, etc.).
    nonisolated private static func hoveredFoldId(in action: HitAction?) -> UUID? {
        guard let action else { return nil }
        if case .toggleFold(let id) = action { return id }
        return nil
    }

    // MARK: - Subview plan

    /// Build the cell-facing `SubviewPlan` describing every chevron
    /// glyph and every entry-body subview this row wants the cell to
    /// host. The cell consumes the plan through a generic reconciler;
    /// no knowledge of `ToolGroupLayout`'s internals leaks past this
    /// boundary.
    ///
    /// `origin` is the cell's `layoutOrigin` (row padding offset).
    /// `hoveredAction` / `selection` are the cell's current state —
    /// re-building the plan on every hover / selection transition is
    /// cheap (just value composition over the already-laid-out
    /// `items`), and lets the reconcile path stay a single code path.
    func subviewPlan(
        origin: CGPoint,
        hoveredAction: HitAction?,
        selection: SelectionRange?
    ) -> SubviewPlan {
        let hoveredId = Self.hoveredFoldId(in: hoveredAction)

        var chevrons: [SubviewPlan.Chevron] = []
        chevrons.reserveCapacity(1 + items.count)
        chevrons.append(SubviewPlan.Chevron(
            id: groupHeader.foldId,
            center: CGPoint(x: origin.x + groupHeader.chevronCenter.x,
                            y: origin.y + groupHeader.chevronCenter.y),
            expanded: groupHeader.chevronExpanded,
            hovered: hoveredId == groupHeader.foldId))

        // Selection rects in layout-local coords. Distributed to every
        // entry's draw closure; each entry filters against its own
        // `bandRect` at draw time (the list is short — ≤ N body rows
        // — so per-entry filtering is cheaper than partitioning up
        // front).
        let selectionRects: [CGRect] = {
            guard let selection, let adapter = selectionAdapter else { return [] }
            return adapter.rects(selection.start, selection.end)
        }()

        var entries: [SubviewPlan.Entry] = []
        entries.reserveCapacity(items.count)
        for entry in items {
            chevrons.append(SubviewPlan.Chevron(
                id: entry.header.foldId,
                center: CGPoint(x: origin.x + entry.header.chevronCenter.x,
                                y: origin.y + entry.header.chevronCenter.y),
                expanded: entry.header.chevronExpanded,
                hovered: hoveredId == entry.header.foldId))

            let frame = CGRect(
                x: origin.x + entry.bandRect.minX,
                y: origin.y + entry.bandRect.minY,
                width: entry.bandRect.width,
                height: entry.bandRect.height)

            let capturedEntry = entry
            let capturedHovered = hoveredId == entry.header.foldId
            let capturedRects = selectionRects
            entries.append(SubviewPlan.Entry(
                id: entry.childId,
                frame: frame,
                draw: { ctx, selectionColor in
                    Self.drawEntry(capturedEntry,
                                   hovered: capturedHovered,
                                   selectionRects: capturedRects,
                                   selectionColor: selectionColor,
                                   in: ctx)
                }))
        }

        return SubviewPlan(chevrons: chevrons, entries: entries)
    }

    /// Draw a header's title — the chevron glyph is rendered by the
    /// cell as a per-foldId `CAShapeLayer` driven from the
    /// `SubviewPlan.Chevron` specs this layout emits (see
    /// `BlockCellView+SubviewPlan.swift`), so this path is title-only.
    nonisolated private static func drawHeader(
        _ header: Header,
        hovered: Bool,
        in ctx: CGContext,
        origin: CGPoint
    ) {
        let titleColor: NSColor = hovered
            ? BlockStyle.toolHeaderHoverForeground
            : BlockStyle.toolHeaderForeground

        // Retypeset on draw so the hover-driven `foregroundColor`
        // swap doesn't require a layout rebuild. Title text was
        // already truncated to fit at make-time, so this is a single
        // CTLine constructor over a known-bounded string.
        guard !header.title.isEmpty else { return }
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

}

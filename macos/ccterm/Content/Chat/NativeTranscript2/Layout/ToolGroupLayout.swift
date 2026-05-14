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

    /// Selection-facing API. Two kinds of selectable region live
    /// inside the row:
    ///
    /// - `fileEdit` bodies → `LayoutPosition.diff(childIndex:char:)`,
    ///   routed into the entry's `DiffLayout`.
    /// - text-card bodies (bash / grep / glob / webFetch / webSearch /
    ///   askUserQuestion / agent) → `LayoutPosition.textCard(childIndex:`
    ///   `sectionIndex:char:)`, routed into the matching
    ///   `TextCardSection`'s `TextLayout`.
    ///
    /// `Region` is the internal union the adapter walks once at
    /// build time; downstream closures look regions up by the
    /// `(childIndex, sectionIndex?)` keys carried by `LayoutPosition`.
    /// Mixed-region drags (across two bodies, or across two sections
    /// inside one body) collapse to empty rects / empty string —
    /// matching the diff-only adapter's prior cross-body clamp.
    var selectionAdapter: SelectionAdapter? {
        let regions = Self.buildRegions(items: items)
        guard !regions.isEmpty else { return nil }

        // Cmd+A / triple-click target. Spans the first region only —
        // the caller's hit-tested position then narrows `unitRange`
        // to the right region. Mirrors the diff-only adapter's
        // first-body fullRange (Cmd+A lands wherever the user's last
        // click was, which is the region we'd want anyway).
        let fullRange = regions[0].fullRange

        return SelectionAdapter(
            fullRange: fullRange,
            unitRange: { p in
                Self.region(for: p, in: regions)?.fullRange ?? fullRange
            },
            hitTest: { point in
                // Snap to whichever region's y band contains the
                // point (or, when between regions, the closest one).
                // Empty bodies are filtered out at region-build time,
                // so the snap always lands on a real selectable
                // surface.
                let target = regions.first(where: {
                    point.y >= $0.bandRect.minY
                        && point.y <= $0.bandRect.maxY
                }) ?? regions.min(by: {
                    let d0 = min(abs(point.y - $0.bandRect.minY),
                                 abs(point.y - $0.bandRect.maxY))
                    let d1 = min(abs(point.y - $1.bandRect.minY),
                                 abs(point.y - $1.bandRect.maxY))
                    return d0 < d1
                })!
                return target.hitTest(point)
            },
            rects: { a, b in
                guard let region = Self.region(for: a, in: regions),
                      region.matches(b)
                else { return [] }
                return region.rects(a, b)
            },
            string: { a, b in
                guard let region = Self.region(for: a, in: regions),
                      region.matches(b)
                else { return "" }
                return region.string(a, b)
            },
            wordBoundary: { p in
                Self.region(for: p, in: regions)?.wordBoundary(p)
            })
    }

    /// One selectable surface inside the row — either a `DiffLayout`
    /// body or a single `TextCardSection` card. All closures are
    /// pre-bound to the underlying primitive at build time so the
    /// `selectionAdapter` switch lives in one place
    /// (`buildRegions`) rather than scattered across every helper.
    private struct Region {
        let bandRect: CGRect
        let fullRange: SelectionRange
        let matches: (LayoutPosition) -> Bool
        let hitTest: (CGPoint) -> LayoutPosition
        let rects: (LayoutPosition, LayoutPosition) -> [CGRect]
        let string: (LayoutPosition, LayoutPosition) -> String
        let wordBoundary: (LayoutPosition) -> SelectionRange?
    }

    nonisolated private static func buildRegions(items: [Entry]) -> [Region] {
        var out: [Region] = []
        for (idx, entry) in items.enumerated() {
            guard let body = entry.body else { continue }
            switch body {
            case .fileEdit(let l):
                let d = l.body
                guard !d.containerRect.isEmpty else { continue }
                out.append(makeDiffRegion(childIndex: idx, body: d))
            case .read, .generic:
                // Header-only — no body geometry to select.
                continue
            case .bash, .grep, .glob, .webFetch, .webSearch,
                 .askUserQuestion, .agent:
                // Every kind in this arm exposes its body through
                // `textCardSections`; the accessor switch on
                // `ToolGroupChildLayout` is the single source of
                // truth for "this kind uses the text-card primitive."
                let sections = body.textCardSections ?? []
                for (sectionIndex, section) in sections.enumerated() {
                    out.append(makeTextCardRegion(
                        childIndex: idx,
                        sectionIndex: sectionIndex,
                        section: section))
                }
            }
        }
        return out
    }

    nonisolated private static func makeDiffRegion(
        childIndex: Int, body: DiffLayout
    ) -> Region {
        Region(
            bandRect: body.containerRect,
            fullRange: SelectionRange(
                start: .diff(childIndex: childIndex, char: 0),
                end: .diff(childIndex: childIndex, char: body.contentLength)),
            matches: { p in
                if case .diff(let i, _) = p { return i == childIndex }
                return false
            },
            hitTest: { point in
                .diff(childIndex: childIndex, char: body.hitTest(point: point))
            },
            rects: { a, b in
                guard case .diff(_, let ca) = a, case .diff(_, let cb) = b
                else { return [] }
                let lo = min(ca, cb), hi = max(ca, cb)
                return body.rects(loChar: lo, hiChar: hi)
            },
            string: { a, b in
                guard case .diff(_, let ca) = a, case .diff(_, let cb) = b
                else { return "" }
                let lo = min(ca, cb), hi = max(ca, cb)
                return body.string(loChar: lo, hiChar: hi)
            },
            wordBoundary: { p in
                guard case .diff(_, let c) = p,
                      let word = body.wordBoundary(at: c)
                else { return nil }
                return SelectionRange(
                    start: .diff(childIndex: childIndex, char: word.location),
                    end: .diff(childIndex: childIndex,
                               char: word.location + word.length))
            })
    }

    /// One `TextCardSection` card. Char positions are UTF-16 indices
    /// into the section's `TextLayout.attributed.string`; rects are
    /// emitted in layout-local coords by offsetting `TextLayout`'s
    /// own rects by the section's `textOrigin`.
    nonisolated private static func makeTextCardRegion(
        childIndex: Int, sectionIndex: Int, section: TextCardSection
    ) -> Region {
        let text = section.text
        let textOrigin = section.textOrigin
        let attributed = text.attributed
        let length = text.length

        let fullRange = SelectionRange(
            start: .textCard(childIndex: childIndex,
                             sectionIndex: sectionIndex, char: 0),
            end: .textCard(childIndex: childIndex,
                           sectionIndex: sectionIndex, char: length))

        return Region(
            bandRect: section.cardRect,
            fullRange: fullRange,
            matches: { p in
                if case .textCard(let i, let s, _) = p {
                    return i == childIndex && s == sectionIndex
                }
                return false
            },
            hitTest: { point in
                let local = CGPoint(
                    x: point.x - textOrigin.x,
                    y: point.y - textOrigin.y)
                return .textCard(
                    childIndex: childIndex,
                    sectionIndex: sectionIndex,
                    char: text.characterIndex(at: local))
            },
            rects: { a, b in
                guard case .textCard(_, _, let ca) = a,
                      case .textCard(_, _, let cb) = b
                else { return [] }
                let lo = min(ca, cb), hi = max(ca, cb)
                guard hi > lo else { return [] }
                let local = text.selectionRects(
                    for: NSRange(location: lo, length: hi - lo))
                return local.map {
                    $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
                }
            },
            string: { a, b in
                guard case .textCard(_, _, let ca) = a,
                      case .textCard(_, _, let cb) = b
                else { return "" }
                let lo = min(ca, cb), hi = max(ca, cb)
                guard hi > lo, hi <= attributed.length else { return "" }
                return attributed
                    .attributedSubstring(
                        from: NSRange(location: lo, length: hi - lo))
                    .string
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
            },
            wordBoundary: { p in
                guard case .textCard(_, _, let c) = p,
                      attributed.length > 0
                else { return nil }
                let clamped = max(0, min(c, attributed.length - 1))
                let word = attributed.doubleClick(at: clamped)
                return SelectionRange(
                    start: .textCard(childIndex: childIndex,
                                     sectionIndex: sectionIndex,
                                     char: word.location),
                    end: .textCard(childIndex: childIndex,
                                   sectionIndex: sectionIndex,
                                   char: word.location + word.length))
            })
    }

    /// Find the region that owns `position`. Returns `nil` when no
    /// region's `matches` accepts the value (caller passed a stale or
    /// non-toolGroup position).
    nonisolated private static func region(
        for position: LayoutPosition, in regions: [Region]
    ) -> Region? {
        regions.first(where: { $0.matches(position) })
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
    ///
    /// `hasChevron` distinguishes foldable headers (group header
    /// always, plus children whose `Child.hasExpandableBody == true`)
    /// from static labels (read / generic children). When `false`,
    /// the chevron is *not* drawn, no fold hit is registered, and
    /// the title gets the entire band width — the row reads as a
    /// plain title line, not a control affordance.
    struct Header: @unchecked Sendable {
        let foldId: UUID
        /// Whole header rect in layout-local coords.
        let rect: CGRect
        /// Display text (already truncated to fit the band).
        let title: String
        /// Width budget reserved for the title (≤ band width − chevron
        /// allowance when `hasChevron`, full band width otherwise).
        /// Used at draw time to clamp the retypeset line when hover
        /// repaints kick in.
        let titleWidth: CGFloat
        /// Baseline origin for `CTLine.draw`.
        let titleOrigin: CGPoint
        /// `true` when this header should render a chevron glyph and
        /// participate in fold-toggle hit dispatch. `false` for
        /// header-only child kinds (read, generic) — they're labels,
        /// not controls.
        let hasChevron: Bool
        /// Centre of the chevron glyph — drawn at runtime so rotation
        /// can track the fold flag without a rebuild. Only consumed
        /// when `hasChevron == true`.
        let chevronCenter: CGPoint
        /// `true` → chevron points down; `false` → chevron points right.
        let chevronExpanded: Bool
        /// Runtime status for this surface — read from
        /// `Transcript2Coordinator.statusStates` at layout-build time
        /// and used by `drawHeader` / `subviewPlan` to swap title
        /// colour + chevron tint. Geometry is independent of status,
        /// so a status change only invalidates the cached layout
        /// (single-row reload), never `noteHeightOfRows`.
        let status: ToolStatus
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
        statusStates: [UUID: ToolStatus],
        childHighlights: [UUID: HighlightValue],
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
        let groupStatus = statusStates[blockId] ?? .completed

        // Group header sits flush at the row's top-left (the cell's
        // `layoutOrigin.y` already supplies the row top padding, so
        // layout-local y starts at 0).
        //
        // Title text is resolved through `group.resolvedTitle(...)`:
        //   - (.running, folded)   → activeTitle (last child progressive)
        //   - (.running, expanded) → expandedActiveTitle (aggregated progressive)
        //   - (else, *)            → completedTitle (aggregated past-tense)
        // Geometry is identical across the three variants because the
        // header band is a fixed-height row; only the typeset text
        // changes. Status + fold both flow as snapshots into `make`,
        // so a state flip evicts the row's cached layout and recomputes
        // with the new title on the next `viewFor`.
        var y: CGFloat = 0
        let groupHeader = makeHeader(
            foldId: blockId,
            title: group.resolvedTitle(status: groupStatus,
                                       isExpanded: groupExpanded),
            hasChevron: true,
            chevronExpanded: groupExpanded,
            status: groupStatus,
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
                let canFold = child.hasExpandableBody
                let childExpanded = canFold && (foldStates[child.id] ?? false)
                let childStatus = statusStates[child.id] ?? .completed
                // Per-child header text follows status: `.running`
                // takes the progressive form, every terminal status
                // takes the past-tense form. Centralised on
                // `Child.headerLabel(for:)` so per-kind label payloads
                // (`FileEditChild.activeLabel` vs `.label`, etc.) stay
                // the single source of truth.
                let childHeader = makeHeader(
                    foldId: child.id,
                    title: child.headerLabel(for: childStatus),
                    hasChevron: canFold,
                    chevronExpanded: childExpanded,
                    status: childStatus,
                    y: y,
                    maxWidth: maxWidth)
                y += BlockStyle.toolHeaderHeight
                if canFold {
                    hits.append(InteractiveHit(
                        rect: hitRect(over: childHeader, maxWidth: maxWidth),
                        action: .toggleFold(child.id)))
                }

                let body: ToolGroupChildLayout?
                if childExpanded {
                    let bodyY = y + BlockStyle.toolHeaderChildSpacing
                    let layout = ToolGroupChildLayout.make(
                        child: child,
                        highlight: childHighlights[child.id],
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
        hasChevron: Bool,
        chevronExpanded: Bool,
        status: ToolStatus,
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
        // already supplies the row's horizontal padding). Header-only
        // children (no chevron) get the full band width; foldable
        // headers reserve `chevron + gap` on the right edge.
        let reserved: CGFloat = hasChevron ? (chevron + gap) : 0
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
        let chevronCenter: CGPoint
        if hasChevron {
            let visualCompensation = max(0, (font.capHeight - font.xHeight) / 2)
            let chevronX = min(titleWidth + gap + chevron / 2,
                               maxWidth - chevron / 2)
            chevronCenter = CGPoint(
                x: chevronX,
                y: midY + visualCompensation)
        } else {
            chevronCenter = .zero
        }

        return Header(
            foldId: foldId,
            rect: rect,
            title: displayTitle,
            titleWidth: titleWidth,
            titleOrigin: titleOrigin,
            hasChevron: hasChevron,
            chevronCenter: chevronCenter,
            chevronExpanded: chevronExpanded,
            status: status)
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
               titleOrigin: .zero, hasChevron: false,
               chevronCenter: .zero, chevronExpanded: false,
               status: .completed)
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
        if groupHeader.hasChevron {
            let tint = Self.chevronTint(
                for: groupHeader.status,
                hovered: hoveredId == groupHeader.foldId)
            chevrons.append(SubviewPlan.Chevron(
                id: groupHeader.foldId,
                center: CGPoint(x: origin.x + groupHeader.chevronCenter.x,
                                y: origin.y + groupHeader.chevronCenter.y),
                expanded: groupHeader.chevronExpanded,
                strokeColor: tint.color,
                alpha: tint.alpha))
        }

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
            if entry.header.hasChevron {
                let tint = Self.chevronTint(
                    for: entry.header.status,
                    hovered: hoveredId == entry.header.foldId)
                chevrons.append(SubviewPlan.Chevron(
                    id: entry.header.foldId,
                    center: CGPoint(x: origin.x + entry.header.chevronCenter.x,
                                    y: origin.y + entry.header.chevronCenter.y),
                    expanded: entry.header.chevronExpanded,
                    strokeColor: tint.color,
                    alpha: tint.alpha))
            }

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
        // Retypeset on draw so the hover-driven `foregroundColor`
        // swap doesn't require a layout rebuild. Title text was
        // already truncated to fit at make-time, so this is a single
        // CTLine constructor over a known-bounded string.
        guard !header.title.isEmpty else { return }
        let attr = NSAttributedString(string: header.title, attributes: [
            .font: BlockStyle.toolHeaderFont,
            .foregroundColor: titleColor(for: header.status, hovered: hovered),
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

    // MARK: - Status palette
    //
    // Single source of truth for "how does ToolStatus colour the
    // header". Both `drawHeader` and `subviewPlan` route through
    // these helpers so title + chevron stay in lockstep. Adding a
    // new status case only needs an arm in each helper.

    /// Title colour for a header in `status`, optionally with hover
    /// brightening applied. `.completed` keeps today's behaviour
    /// (secondary at idle, label at hover) so absent-from-dict rows
    /// render exactly as before this hook existed.
    nonisolated private static func titleColor(
        for status: ToolStatus, hovered: Bool
    ) -> NSColor {
        switch status {
        case .completed:
            return hovered
                ? BlockStyle.toolHeaderHoverForeground
                : BlockStyle.toolHeaderForeground
        case .running:
            // Brighter "primed" tone at all times — running headers
            // pull the eye independent of hover.
            return BlockStyle.toolHeaderHoverForeground
        case .failed:
            return .systemRed
        case .cancelled:
            return hovered
                ? BlockStyle.toolHeaderForeground
                : .tertiaryLabelColor
        }
    }

    /// Chevron stroke colour + alpha for a header in `status`,
    /// factoring in hover. Hover still raises alpha on every status
    /// so the click affordance survives.
    nonisolated private static func chevronTint(
        for status: ToolStatus, hovered: Bool
    ) -> (color: NSColor, alpha: CGFloat) {
        let alpha: CGFloat = hovered
            ? BlockStyle.toolHeaderChevronHoverAlpha
            : BlockStyle.toolHeaderChevronIdleAlpha
        switch status {
        case .completed:
            return (
                hovered
                    ? BlockStyle.toolHeaderHoverForeground
                    : BlockStyle.toolHeaderForeground,
                alpha)
        case .running:
            return (BlockStyle.toolHeaderHoverForeground,
                    BlockStyle.toolHeaderChevronHoverAlpha)
        case .failed:
            return (.systemRed, BlockStyle.toolHeaderChevronHoverAlpha)
        case .cancelled:
            return (
                hovered
                    ? BlockStyle.toolHeaderForeground
                    : .tertiaryLabelColor,
                alpha)
        }
    }

}

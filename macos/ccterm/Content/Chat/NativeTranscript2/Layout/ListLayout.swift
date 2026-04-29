import AppKit
import CoreText

/// Immutable list layout — pure function of `(ListBlock, maxWidth)`.
///
/// The marker column is intentionally **not** in the text flow. Each item's
/// marker is rendered as an independent visual element (a `CTLine` for
/// bullet / ordered numerals, a `CGPath` for checkboxes), positioned by
/// `markerCenterY`-aligned-to-first-content-line geometry. Two consequences:
///
/// 1. Marker glyphs aren't selectable — they don't exist in any
///    `NSAttributedString`. The old TextKit-based approach (tab stops +
///    leading marker run) leaks marker characters into copy / drag-select;
///    this one can't.
/// 2. Ordered "1." / "10." / "100." auto-align by the dot, because the
///    marker column is sized to the **widest** marker and individual
///    markers are right-aligned within it.
///
/// `@unchecked Sendable` because the nested type tree contains `CTLine`
/// (Apple-documented thread-safe immutable) and `NSColor` (documented safe
/// to share) — Swift can't see those guarantees.
///
/// Coordinate system: y-down (matches the table's flipped row coords).
/// All geometry inside `ListLayout` is list-local, with `(0, 0)` at the
/// list's top-left. `draw(in:origin:)` translates by `origin` before any
/// drawing.
struct ListLayout: @unchecked Sendable {
    let items: [Item]
    /// Width of the marker column — equals the widest marker among `items`.
    /// Zero when *every* item has `marker == nil` (suppressed list).
    let markerColumnWidth: CGFloat
    /// Visible gap between the marker column's right edge and the content's
    /// left edge. Zero when `markerColumnWidth == 0`.
    let markerContentGap: CGFloat
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Link hot zones from every nested `TextLayout`, already offset into
    /// list-local coords. Cell-side hit-testing applies one final offset
    /// for the cell's draw origin.
    let links: [TextLayout.LinkHit]

    /// Where item content starts (list-local). Tests / selection bookkeeping
    /// use this — `draw` doesn't go through it (it adds the per-content
    /// `originInList` directly).
    var contentOriginX: CGFloat { markerColumnWidth + markerContentGap }

    struct Item {
        let marker: Marker?
        /// Marker geometric center, list-local (y-down). Defined as the
        /// midY of the **first** content line — paragraph or first nested
        /// item — so the marker visually aligns with the first text line
        /// regardless of font size mixing.
        let markerCenterY: CGFloat
        /// `markerColumnWidth` (the marker's right edge, list-local). All
        /// items in one list share this value — markers right-align.
        let markerRightX: CGFloat
        /// Item's top in list-local coords.
        let topY: CGFloat
        /// Vertical extent of this item's contents (excluding inter-item
        /// spacing).
        let height: CGFloat
        let contents: [Content]
    }

    /// Two flavors of marker — text glyph (bullet / ordered numerals) or
    /// self-drawn checkbox. Checkbox is intentionally not a glyph: Apple
    /// system fonts ship `U+2611 ☑` and `U+2610 ☐` at noticeably different
    /// stroke weights, so a list mixing checked / unchecked items would
    /// jitter visually. Drawing the box ourselves keeps both states pixel-
    /// identical.
    enum Marker {
        case text(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)
        case checkbox(checked: Bool, size: CGFloat, color: NSColor)

        var width: CGFloat {
            switch self {
            case .text(_, let w, _, _): return w
            case .checkbox(_, let s, _): return s
            }
        }

        /// Marker's vertical extent. Used as a fallback `markerCenterY`
        /// when an item has no content (rare — empty list item).
        var height: CGFloat {
            switch self {
            case .text(_, _, let a, let d): return a + d
            case .checkbox(_, let s, _): return s
            }
        }
    }

    enum Content {
        case text(TextLayout, originInList: CGPoint)
        case list(ListLayout, originInList: CGPoint)
    }

    nonisolated static let empty = ListLayout(
        items: [], markerColumnWidth: 0, markerContentGap: 0,
        totalHeight: 0, measuredWidth: 0, links: [])

    // MARK: - Make

    nonisolated static func make(block: ListBlock, maxWidth: CGFloat) -> ListLayout {
        guard !block.items.isEmpty, maxWidth > 0 else { return .empty }

        // Step 1: pre-render every marker so we know the column width.
        // Markers don't depend on `maxWidth`, only on item state — they
        // could be cached per-item, but the cost (one CTLine per item) is
        // dwarfed by paragraph typesetting, so we recompute each pass and
        // keep the API simple.
        let preMarkers: [Marker?] = block.items.enumerated().map { idx, item in
            buildMarker(
                for: item,
                ordered: block.ordered,
                ordinal: block.startIndex + idx)
        }
        let markerColumnWidth = preMarkers.compactMap { $0?.width }.max() ?? 0
        let markerContentGap: CGFloat = markerColumnWidth > 0
            ? BlockStyle.listMarkerContentGap
            : 0
        let contentOriginX = markerColumnWidth + markerContentGap
        let contentWidth = max(1, maxWidth - contentOriginX)

        let itemSpacing = BlockStyle.listItemSpacing
        let blockSpacingWithinItem = BlockStyle.listIntraItemSpacing

        // Step 2: lay out each item's contents. Track item-local `innerY`
        // so the marker can land on the first content line's midY. After
        // all items are laid out, `y` becomes `totalHeight`.
        var laidItems: [Item] = []
        laidItems.reserveCapacity(block.items.count)
        var y: CGFloat = 0
        var measuredW: CGFloat = 0
        var links: [TextLayout.LinkHit] = []

        for (idx, srcItem) in block.items.enumerated() {
            if idx > 0 { y += itemSpacing }
            let itemTopY = y

            var contents: [Content] = []
            var innerY: CGFloat = 0
            // Captured from the first content block. Used to align the
            // marker's center to the first content line's midY (matches
            // Telegram's marker alignment — visually centered on the line
            // regardless of marker font size).
            var firstLineMidYInItem: CGFloat?

            for (bi, blockContent) in srcItem.content.enumerated() {
                if bi > 0 { innerY += blockSpacingWithinItem }
                switch blockContent {
                case .paragraph(let inlines):
                    let attr = BlockStyle.paragraphAttributed(inlines: inlines)
                    let layout = TextLayout.make(attributed: attr, maxWidth: contentWidth)
                    let originInList = CGPoint(
                        x: contentOriginX, y: itemTopY + innerY)
                    if firstLineMidYInItem == nil,
                       let mid = firstLineMidY(layout: layout)
                    {
                        firstLineMidYInItem = innerY + mid
                    }
                    for hit in layout.links {
                        links.append(TextLayout.LinkHit(
                            rect: hit.rect.offsetBy(
                                dx: originInList.x, dy: originInList.y),
                            url: hit.url))
                    }
                    contents.append(.text(layout, originInList: originInList))
                    innerY += layout.totalHeight
                    measuredW = max(measuredW, originInList.x + layout.measuredWidth)

                case .list(let nested):
                    let nestedLayout = ListLayout.make(
                        block: nested, maxWidth: contentWidth)
                    let originInList = CGPoint(
                        x: contentOriginX, y: itemTopY + innerY)
                    if firstLineMidYInItem == nil,
                       let firstNested = nestedLayout.items.first
                    {
                        // Nested list's first marker is already aligned to
                        // the nested first content line — re-using its
                        // `markerCenterY` skips re-deriving from a child
                        // TextLayout we don't directly hold here.
                        firstLineMidYInItem = innerY + firstNested.markerCenterY
                    }
                    for hit in nestedLayout.links {
                        links.append(TextLayout.LinkHit(
                            rect: hit.rect.offsetBy(
                                dx: originInList.x, dy: originInList.y),
                            url: hit.url))
                    }
                    contents.append(.list(nestedLayout, originInList: originInList))
                    innerY += nestedLayout.totalHeight
                    measuredW = max(measuredW, originInList.x + nestedLayout.measuredWidth)
                }
            }

            let marker = preMarkers[idx]
            let centerY: CGFloat
            if let mid = firstLineMidYInItem {
                centerY = itemTopY + mid
            } else if let m = marker {
                // Empty item — center the marker inside its own height
                // so it doesn't collapse to the item top.
                centerY = itemTopY + m.height / 2
            } else {
                centerY = itemTopY
            }

            laidItems.append(Item(
                marker: marker,
                markerCenterY: centerY,
                markerRightX: markerColumnWidth,
                topY: itemTopY,
                height: innerY,
                contents: contents))
            y = itemTopY + innerY
        }

        return ListLayout(
            items: laidItems,
            markerColumnWidth: markerColumnWidth,
            markerContentGap: markerContentGap,
            totalHeight: y,
            measuredWidth: max(measuredW, contentOriginX),
            links: links)
    }

    /// First-line geometric midY relative to the layout's top-left, y-down.
    ///
    /// In `TextLayout.make`, line 0 is positioned with `y += ascent` before
    /// recording the baseline, so `lineOrigins[0].y == ascent` and
    /// `top == 0`, `bottom == ascent + descent`. Hence
    /// `midY = baseline + (descent - ascent) / 2`.
    nonisolated private static func firstLineMidY(layout: TextLayout) -> CGFloat? {
        guard let baseline = layout.lineOrigins.first?.y,
              let metric = layout.lineMetrics.first
        else { return nil }
        return baseline + (metric.descent - metric.ascent) / 2
    }

    /// Per-item explicit checkbox always wins over the list-level marker —
    /// this matches how markdown renders task list items inside an
    /// otherwise unordered/ordered list.
    nonisolated private static func buildMarker(
        for item: ListBlock.Item, ordered: Bool, ordinal: Int
    ) -> Marker? {
        if let checked = item.checkbox {
            let size = BlockStyle.listCheckboxSize
            let color = checked
                ? BlockStyle.listCheckboxCheckedColor
                : BlockStyle.listCheckboxUncheckedColor
            return .checkbox(checked: checked, size: size, color: color)
        }
        let attr: NSAttributedString = ordered
            ? BlockStyle.listOrderedMarkerAttributed(ordinal)
            : BlockStyle.listBulletMarkerAttributed()
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let width = ceil(attr.size().width)
        return .text(line: line, width: width, ascent: ascent, descent: descent)
    }

    // MARK: - Draw

    /// Draw into a flipped NSView. `origin` is layout's top-left in view
    /// coords. Marker → content order matches the old layout's pass (no
    /// observable difference; CG paints in call order regardless).
    func draw(in ctx: CGContext, origin: CGPoint) {
        for item in items {
            drawMarker(item: item, origin: origin, in: ctx)
            for content in item.contents {
                switch content {
                case .text(let layout, let o):
                    layout.draw(
                        in: ctx,
                        origin: CGPoint(x: origin.x + o.x, y: origin.y + o.y))
                case .list(let nested, let o):
                    nested.draw(
                        in: ctx,
                        origin: CGPoint(x: origin.x + o.x, y: origin.y + o.y))
                }
            }
        }
    }

    private func drawMarker(item: Item, origin: CGPoint, in ctx: CGContext) {
        guard let marker = item.marker else { return }
        let centerY = origin.y + item.markerCenterY
        let rightX = origin.x + item.markerRightX
        switch marker {
        case .text(let line, let width, let ascent, let descent):
            // midY = baseline + (descent - ascent)/2  →  baseline = midY + (ascent - descent)/2.
            // Solving keeps the marker's geometric center at `centerY`
            // regardless of font asymmetry between ascent and descent.
            let baseline = centerY + (ascent - descent) / 2
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: rightX - width, y: baseline)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        case .checkbox(let checked, let size, let color):
            let rect = CGRect(
                x: rightX - size, y: centerY - size / 2,
                width: size, height: size)
            Self.drawCheckbox(in: rect, checked: checked, color: color, in: ctx)
        }
    }

    /// Self-drawn checkbox. ctx is in flipped coords (y-down) — paths read
    /// directly in screen orientation. Stroke is `inset` by half the line
    /// width so the rectangle's painted edge lands inside the math `rect`.
    private static func drawCheckbox(
        in rect: CGRect, checked: Bool, color: NSColor, in ctx: CGContext
    ) {
        ctx.saveGState()
        let stroke: CGFloat = 1.1
        let corner = rect.width * 0.18
        let box = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.addPath(CGPath(
            roundedRect: box,
            cornerWidth: corner, cornerHeight: corner,
            transform: nil))
        ctx.strokePath()
        if checked {
            // Check glyph: round caps / joins so end points read as
            // "drawn" rather than "cut". Coordinates are fractions of the
            // box side — the same proportions Apple's system checkmarks
            // use, eyeballed for visual parity at 14pt.
            let side = rect.width
            let x = rect.minX
            let y = rect.minY
            let checkStroke = max(1.3, side * 0.14)
            ctx.setLineWidth(checkStroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: x + side * 0.22, y: y + side * 0.54))
            ctx.addLine(to: CGPoint(x: x + side * 0.44, y: y + side * 0.72))
            ctx.addLine(to: CGPoint(x: x + side * 0.78, y: y + side * 0.32))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

}

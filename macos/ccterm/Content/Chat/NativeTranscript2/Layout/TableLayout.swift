import AppKit

/// Immutable table layout — pure function of `(TableBlock, maxWidth)`.
///
/// ### Column allocation (CSS-like min/max model)
///
/// Each cell exposes a `min` (Core Text's natural-break width at
/// `maxWidth = 1`, ≈ CSS `min-content`) and a `max` (single-line width,
/// ≈ CSS `max-content`). Column allocation runs three branches in order:
///
/// 1. `Σ max ≤ maxWidth` — every column gets its max; slack is parked on
///    the last column so the table fills the available width with the
///    body of the table left-anchored.
/// 2. `Σ min < maxWidth ≤ Σ max` — start every column at its min, then
///    distribute the remaining slack proportionally to each column's
///    `max` (wider-natural columns absorb more, narrow columns barely
///    move).
/// 3. `Σ min > maxWidth` — pathological narrow viewport. Scale every
///    column's min down uniformly so the table doesn't overflow the row.
///
/// ### Visual chrome
///
/// Header row gets a deeper tint; odd-indexed body rows pick up a faint
/// zebra stripe. The header / body boundary is drawn at
/// `BlockStyle.tableBorderColor`; subsequent body / body separators at
/// the lighter `tableInnerDividerColor`. Outer 1pt rounded border is
/// stroked over the corner-clipped fill.
///
/// `@unchecked Sendable` — same reason as `TextLayout` and `ListLayout`.
struct TableLayout: @unchecked Sendable {
    let columnWidths: [CGFloat]
    /// Row heights including padding. `rowHeights[0]` is the header row;
    /// indices 1+ are body rows in source order.
    let rowHeights: [CGFloat]
    /// `cells[row][col]`. Row 0 is the header.
    let cells: [[TextLayout]]
    let alignments: [TableBlock.Alignment]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat
    /// Link hot zones from every cell, already offset into table-local
    /// coords.
    let links: [TextLayout.LinkHit]

    nonisolated static let empty = TableLayout(
        columnWidths: [], rowHeights: [], cells: [],
        alignments: [], totalHeight: 0, measuredWidth: 0, links: [])

    // MARK: - Make

    nonisolated static func make(block: TableBlock, maxWidth: CGFloat) -> TableLayout {
        let columnCount = max(
            block.header.count,
            block.rows.map(\.count).max() ?? 0)
        guard columnCount > 0, maxWidth > 0 else { return .empty }

        let hPad = BlockStyle.tableCellHorizontalPadding
        let vPad = BlockStyle.tableCellVerticalPadding

        // Step 1: per-cell attributed strings. Header is bold; missing
        // cells (jagged source rows) become empty strings — tables stay
        // rectangular regardless of the source's column-count drift.
        let headerAttrs: [NSAttributedString] = (0 ..< columnCount).map { col in
            BlockStyle.tableCellAttributed(
                inlines: col < block.header.count ? block.header[col] : [],
                bold: true)
        }
        let bodyAttrs: [[NSAttributedString]] = block.rows.map { row in
            (0 ..< columnCount).map { col in
                BlockStyle.tableCellAttributed(
                    inlines: col < row.count ? row[col] : [],
                    bold: false)
            }
        }
        let allRowsAttr: [[NSAttributedString]] = [headerAttrs] + bodyAttrs

        // Step 2: per-cell min / max widths. Both include 2 × hPad so the
        // column allocator can compare directly against `maxWidth`.
        let rowCount = allRowsAttr.count
        var cellMin = Array(
            repeating: [CGFloat](repeating: 0, count: columnCount),
            count: rowCount)
        var cellMax = Array(
            repeating: [CGFloat](repeating: 0, count: columnCount),
            count: rowCount)
        for (r, row) in allRowsAttr.enumerated() {
            for (c, attr) in row.enumerated() {
                let maxW = ceil(attr.size().width) + 2 * hPad
                // CSS min-content: typeset at the narrowest possible
                // width and read back what CT settled on. CJK text breaks
                // per glyph, Latin breaks per word — exactly the natural
                // wrap point.
                let minLayout = TextLayout.make(attributed: attr, maxWidth: 1)
                let minW = ceil(minLayout.measuredWidth) + 2 * hPad
                cellMax[r][c] = maxW
                // Empty cells produce `measuredWidth == 0`; clamp so an
                // empty column doesn't claim a min wider than its max.
                cellMin[r][c] = min(minW, maxW)
            }
        }

        // Step 3: per-column min / max = max over the column's cells.
        // Floor each column's min so a single-glyph column doesn't
        // collapse to a sliver.
        var columnMins = [CGFloat](repeating: 0, count: columnCount)
        var columnMaxs = [CGFloat](repeating: 0, count: columnCount)
        for r in 0 ..< rowCount {
            for c in 0 ..< columnCount {
                columnMins[c] = max(columnMins[c], cellMin[r][c])
                columnMaxs[c] = max(columnMaxs[c], cellMax[r][c])
            }
        }
        let minFloor = BlockStyle.tableMinColumnWidth
        for c in 0 ..< columnCount {
            columnMins[c] = max(columnMins[c], minFloor)
            columnMaxs[c] = max(columnMaxs[c], columnMins[c])
        }

        // Step 4: allocate column widths under the three CSS branches.
        let minSum = columnMins.reduce(0, +)
        let maxSum = columnMaxs.reduce(0, +)
        let columnWidths: [CGFloat]
        if maxSum <= maxWidth {
            var ws = columnMaxs
            // Slack parked on the last column matches the "fill the row"
            // visual the old layout produced — the alternative (split
            // slack evenly) makes narrow columns mid-table look oddly
            // padded.
            ws[ws.count - 1] += (maxWidth - maxSum)
            columnWidths = ws
        } else if minSum < maxWidth {
            let slack = maxWidth - minSum
            let totalMax = max(maxSum, 1)
            columnWidths = zip(columnMins, columnMaxs).map { mn, mx in
                mn + slack * (mx / totalMax)
            }
        } else {
            // Pathological — viewport narrower than `Σ min`. Scale mins
            // down uniformly so the table fits even though some text
            // will get tight wraps.
            let scale = maxWidth / max(minSum, 1)
            columnWidths = columnMins.map { max(1, floor($0 * scale)) }
        }

        // Step 5: lay out each cell at its assigned width and harvest
        // links. Cell origin (table-local) is needed up-front so link
        // offsets can be baked in here — at draw-time they'd be
        // recomputed identically, so we do it once.
        var cells: [[TextLayout]] = []
        var rowHeights: [CGFloat] = []
        var links: [TextLayout.LinkHit] = []
        var rowY: CGFloat = 0
        for (_, row) in allRowsAttr.enumerated() {
            var laid: [TextLayout] = []
            var maxCellH: CGFloat = 0
            var colX: CGFloat = 0
            for (c, attr) in row.enumerated() {
                let cellW = columnWidths[c]
                let innerW = max(1, cellW - 2 * hPad)
                let layout = TextLayout.make(attributed: attr, maxWidth: innerW)

                let align = alignmentFor(c, alignments: block.alignments)
                let xOrigin = cellOriginX(
                    cellLeft: colX, cellWidth: cellW,
                    layoutWidth: layout.measuredWidth,
                    hPad: hPad, alignment: align)
                let yOrigin = rowY + vPad

                for hit in layout.links {
                    links.append(TextLayout.LinkHit(
                        rect: hit.rect.offsetBy(dx: xOrigin, dy: yOrigin),
                        url: hit.url))
                }

                laid.append(layout)
                maxCellH = max(maxCellH, layout.totalHeight)
                colX += cellW
            }
            cells.append(laid)
            let rowHeight = maxCellH + 2 * vPad
            rowHeights.append(rowHeight)
            rowY += rowHeight
        }

        return TableLayout(
            columnWidths: columnWidths,
            rowHeights: rowHeights,
            cells: cells,
            alignments: block.alignments,
            totalHeight: rowHeights.reduce(0, +),
            measuredWidth: columnWidths.reduce(0, +),
            links: links)
    }

    nonisolated private static func alignmentFor(
        _ col: Int, alignments: [TableBlock.Alignment]
    ) -> TableBlock.Alignment {
        guard col < alignments.count else { return .none }
        return alignments[col]
    }

    /// Resolve a cell's text-origin x relative to the table's left edge.
    /// `layoutWidth` is `measuredWidth` of the cell's `TextLayout`. The
    /// `right` branch falls back to `hPad` when the layout would
    /// otherwise tuck behind the cell's left padding (defensive against
    /// pathological columns).
    nonisolated private static func cellOriginX(
        cellLeft: CGFloat, cellWidth: CGFloat,
        layoutWidth: CGFloat, hPad: CGFloat,
        alignment: TableBlock.Alignment
    ) -> CGFloat {
        switch alignment {
        case .center:
            return cellLeft + max(0, (cellWidth - layoutWidth) / 2)
        case .right:
            return cellLeft + max(hPad, cellWidth - hPad - layoutWidth)
        case .left, .none:
            return cellLeft + hPad
        }
    }

    // MARK: - Draw

    /// Draw into a flipped NSView. `origin` is the table's top-left in
    /// view coords. Five passes:
    ///   1. clip to rounded rect
    ///   2. fill header bg + zebra rows
    ///   3. inner dividers
    ///   4. cell text
    ///   5. outer border stroke
    func draw(in ctx: CGContext, origin: CGPoint) {
        guard !rowHeights.isEmpty, !columnWidths.isEmpty else { return }
        let hPad = BlockStyle.tableCellHorizontalPadding
        let vPad = BlockStyle.tableCellVerticalPadding
        let radius = BlockStyle.tableCornerRadius
        let tableRect = CGRect(
            x: origin.x, y: origin.y,
            width: measuredWidth, height: totalHeight)

        // 1 + 2: clip → fill backgrounds. Clip closes with the saveGState
        // on (3) so the inner dividers also respect the rounded corners.
        ctx.saveGState()
        ctx.addPath(CGPath(
            roundedRect: tableRect,
            cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()

        var rowY = tableRect.minY
        for (idx, h) in rowHeights.enumerated() {
            let rowRect = CGRect(
                x: tableRect.minX, y: rowY,
                width: tableRect.width, height: h)
            let fill: NSColor?
            if idx == 0 {
                fill = BlockStyle.tableHeaderBackground
            } else {
                let bodyIdx = idx - 1
                fill = bodyIdx.isMultiple(of: 2) ? nil : BlockStyle.tableZebraBackground
            }
            if let fill {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(rowRect)
            }
            rowY += h
        }

        // 3: dividers. Header / body boundary uses the outer border color
        // so the header reads as a sealed band; body / body uses the
        // muted inner color so internal grid stays quiet.
        rowY = tableRect.minY
        for (idx, h) in rowHeights.enumerated() {
            rowY += h
            if idx == rowHeights.count - 1 { break }
            let color: NSColor = idx == 0
                ? BlockStyle.tableBorderColor
                : BlockStyle.tableInnerDividerColor
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(
                x: tableRect.minX, y: rowY - 0.5,
                width: tableRect.width, height: 1))
        }
        ctx.restoreGState()

        // 4: cell text. Each cell's text origin is recomputed (vs.
        // memoized at make-time): the math is cheap and skipping the
        // memo keeps `TableLayout`'s fields tightly scoped.
        var curY = tableRect.minY
        for (rIdx, h) in rowHeights.enumerated() {
            var curX = tableRect.minX
            for (cIdx, layout) in cells[rIdx].enumerated() {
                let cellW = columnWidths[cIdx]
                let align = Self.alignmentFor(cIdx, alignments: alignments)
                let xOrigin = Self.cellOriginX(
                    cellLeft: curX, cellWidth: cellW,
                    layoutWidth: layout.measuredWidth,
                    hPad: hPad, alignment: align)
                let yOrigin = curY + vPad
                layout.draw(in: ctx, origin: CGPoint(x: xOrigin, y: yOrigin))
                curX += cellW
            }
            curY += h
        }

        // 5: outer border. Inset by 0.5 so the 1pt stroke sits on the
        // pixel grid (sharp on 1× and 2× displays alike).
        ctx.saveGState()
        ctx.setStrokeColor(BlockStyle.tableBorderColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(
            roundedRect: tableRect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

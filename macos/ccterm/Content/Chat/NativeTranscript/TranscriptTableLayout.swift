import AppKit

/// Core Text 版的 markdown table layout。视觉参照老 `MarkdownTableView`:
/// - header 行有独立背景色
/// - header 与 body 之间一条分隔线(`tableBorderColor`)
/// - 奇数 body 行 zebra 底色(`tableZebraBackground`)
/// - body 行之间的分隔线用较浅的 `tableInnerDividerColor`
/// - 外框一圈 `tableBorderColor` 1pt 描边 + 圆角
struct TranscriptTableLayout {
    /// 列宽(含 cell 左右 padding)。列数 = `columnWidths.count`。
    let columnWidths: [CGFloat]
    /// 行高(含 cell 上下 padding)。`rowHeights[0]` 是 header;后续是 body。
    let rowHeights: [CGFloat]
    /// `cells[row][col]`。`rows[0]` = header 行。
    let cells: [[TranscriptTextLayout]]
    /// 每列对齐方式(列数不足时末尾用 `.none`/`.left`)。
    let alignments: [MarkdownTable.Alignment]
    let theme: TranscriptTheme

    var totalWidth: CGFloat { columnWidths.reduce(0, +) }
    var totalHeight: CGFloat { rowHeights.reduce(0, +) }

    // MARK: - Build

    static func make(
        table: MarkdownTable,
        builder: MarkdownAttributedBuilder,
        theme: TranscriptTheme,
        maxWidth: CGFloat
    ) -> TranscriptTableLayout {
        let columnCount = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return TranscriptTableLayout(
                columnWidths: [],
                rowHeights: [],
                cells: [],
                alignments: [],
                theme: theme)
        }

        // Pre-build attributed cells (header = bold)
        let headerCells: [NSAttributedString] = (0..<columnCount).map { col in
            builder.buildInline(col < table.header.count ? table.header[col] : [], bold: true)
        }
        let bodyCells: [[NSAttributedString]] = table.rows.map { row in
            (0..<columnCount).map { col in
                builder.buildInline(col < row.count ? row[col] : [], bold: false)
            }
        }
        let allRows: [[NSAttributedString]] = [headerCells] + bodyCells

        // 列理想宽度 = 单行 max + 2*hPad。之后若超过 maxWidth 按比例缩放。
        let hPad: CGFloat = 8
        let vPad: CGFloat = theme.markdown.blockPadding

        var idealColumnWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in allRows {
            for (c, cell) in row.enumerated() {
                idealColumnWidths[c] = max(idealColumnWidths[c], ceil(cell.size().width) + 2 * hPad)
            }
        }
        // 最小列宽(防止极小):3 个字的宽度
        for c in 0..<columnCount {
            idealColumnWidths[c] = max(idealColumnWidths[c], 40)
        }

        let idealSum = idealColumnWidths.reduce(0, +)
        let columnWidths: [CGFloat]
        if idealSum <= maxWidth {
            // 多的空间全给最后一列,让表格铺满;否则很窄的表格会留白
            var ws = idealColumnWidths
            if !ws.isEmpty { ws[ws.count - 1] += (maxWidth - idealSum) }
            columnWidths = ws
        } else {
            // 等比缩放塞进 maxWidth
            let scale = maxWidth / idealSum
            columnWidths = idealColumnWidths.map { floor($0 * scale) }
        }

        // 每行每列排版 cell
        var cells: [[TranscriptTextLayout]] = []
        var rowHeights: [CGFloat] = []
        for row in allRows {
            var laid: [TranscriptTextLayout] = []
            var maxCellH: CGFloat = 0
            for (c, attr) in row.enumerated() {
                let cellW = columnWidths[c]
                let innerW = max(1, cellW - 2 * hPad)
                let layout = TranscriptTextLayout.make(
                    attributed: attr, maxWidth: innerW)
                laid.append(layout)
                maxCellH = max(maxCellH, layout.totalHeight)
            }
            cells.append(laid)
            rowHeights.append(maxCellH + 2 * vPad)
        }

        return TranscriptTableLayout(
            columnWidths: columnWidths,
            rowHeights: rowHeights,
            cells: cells,
            alignments: table.alignments,
            theme: theme)
    }

    // MARK: - Draw

    /// 在 `origin`(flipped,左上角)画整个 table 到 `ctx`。
    func draw(origin: CGPoint, in ctx: CGContext) {
        guard !rowHeights.isEmpty, !columnWidths.isEmpty else { return }
        let hPad: CGFloat = 8
        let vPad: CGFloat = theme.markdown.blockPadding
        let radius = theme.markdown.blockCornerRadius
        let tableRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: totalWidth,
            height: totalHeight)

        ctx.saveGState()

        // 圆角 clip,内部的 zebra / header bg 被裁到圆角外框内。
        let outerPath = CGPath(
            roundedRect: tableRect,
            cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(outerPath)
        ctx.clip()

        // 背景:header 行底色 + 奇数 body 行 zebra
        var rowY = tableRect.minY
        for (rowIndex, h) in rowHeights.enumerated() {
            let rowRect = CGRect(x: tableRect.minX, y: rowY, width: tableRect.width, height: h)
            let fill: NSColor?
            if rowIndex == 0 {
                fill = theme.markdown.tableHeaderBackground
            } else {
                let bodyIdx = rowIndex - 1
                fill = bodyIdx.isMultiple(of: 2) ? nil : theme.markdown.tableZebraBackground
            }
            if let fill {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(rowRect)
            }
            rowY += h
        }

        // 分隔线:header 与 body 之间用 border 色,body 行之间用 inner 色
        rowY = tableRect.minY
        for (rowIndex, h) in rowHeights.enumerated() {
            rowY += h
            if rowIndex == rowHeights.count - 1 { break }
            let color = rowIndex == 0
                ? theme.markdown.tableBorderColor
                : theme.markdown.tableInnerDividerColor
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: tableRect.minX, y: rowY - 0.5, width: tableRect.width, height: 1))
        }

        ctx.restoreGState()

        // Cell 文本
        var curY = tableRect.minY
        for (rowIndex, h) in rowHeights.enumerated() {
            var curX = tableRect.minX
            for (colIndex, cellLayout) in cells[rowIndex].enumerated() {
                let cellW = columnWidths[colIndex]
                let align = alignment(for: colIndex)

                // 水平对齐:.leading=minX+hPad, .trailing=cellRight-hPad-lineWidth,
                // .center=centered in cell. layout.measuredWidth 是最大 line 宽,
                // 多行时用 leading 更直觉。
                let xOrigin: CGFloat
                switch align {
                case .center:
                    xOrigin = curX + max(0, (cellW - cellLayout.measuredWidth) / 2)
                case .right:
                    xOrigin = curX + max(hPad, cellW - hPad - cellLayout.measuredWidth)
                case .left, .none:
                    xOrigin = curX + hPad
                }
                let yOrigin = curY + vPad

                cellLayout.draw(
                    origin: CGPoint(x: xOrigin, y: yOrigin),
                    in: ctx)
                curX += cellW
            }
            curY += h
        }

        // 外框描边(不 clip,直接覆盖)
        ctx.saveGState()
        ctx.setStrokeColor(theme.markdown.tableBorderColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(
            roundedRect: tableRect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func alignment(for col: Int) -> MarkdownTable.Alignment {
        guard col < alignments.count else { return .none }
        return alignments[col]
    }
}

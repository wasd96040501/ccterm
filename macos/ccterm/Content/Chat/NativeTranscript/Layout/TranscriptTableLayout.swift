import AppKit

/// 表格的「宽度无关」预构造物。`AssistantMarkdownRow.prebuilt` 在 width 未知时
/// 算好，resize 时不重算；`TranscriptTableLayout.make(contents:)` 吃它。
///
/// 每个 cell 的 `minWidth` = Core Text 在极窄 boundingWidth 下排版得到的最大 line 宽度
/// (CJK 按字断、拉丁按词断的自然结果，等价于 CSS `min-content`)。
/// `maxWidth` = 单行不换行的宽度，等价于 CSS `max-content`。
/// 两者都已包含 cell 水平 padding。
struct TranscriptTableCellContents {
    let columnCount: Int
    /// `cells[row][col]`。row 0 = header。
    let cells: [[NSAttributedString]]
    /// 每 cell 的 min / max 宽度 (含 2*hPad)。形状与 `cells` 一致。
    let cellMinWidths: [[CGFloat]]
    let cellMaxWidths: [[CGFloat]]
    let alignments: [MarkdownTable.Alignment]
    /// cell 水平内边距，make 时会复用。
    let horizontalPadding: CGFloat

    static let horizontalPadding: CGFloat = 8

    static func make(
        table: MarkdownTable,
        builder: MarkdownAttributedBuilder
    ) -> TranscriptTableCellContents {
        let columnCount = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return TranscriptTableCellContents(
                columnCount: 0,
                cells: [],
                cellMinWidths: [],
                cellMaxWidths: [],
                alignments: [],
                horizontalPadding: Self.horizontalPadding)
        }

        let hPad = Self.horizontalPadding
        let headerCells: [NSAttributedString] = (0..<columnCount).map { col in
            builder.buildInline(col < table.header.count ? table.header[col] : [], bold: true)
        }
        let bodyCells: [[NSAttributedString]] = table.rows.map { row in
            (0..<columnCount).map { col in
                builder.buildInline(col < row.count ? row[col] : [], bold: false)
            }
        }
        let allRows: [[NSAttributedString]] = [headerCells] + bodyCells

        var minWidths: [[CGFloat]] = []
        var maxWidths: [[CGFloat]] = []
        for row in allRows {
            var rowMin: [CGFloat] = []
            var rowMax: [CGFloat] = []
            for cell in row {
                let maxW = ceil(cell.size().width) + 2 * hPad
                let minLayout = TranscriptTextLayout.make(attributed: cell, maxWidth: 1)
                let minW = ceil(minLayout.measuredWidth) + 2 * hPad
                rowMax.append(maxW)
                // min 不应超过 max (空 cell 场景下 measuredWidth=0)
                rowMin.append(min(minW, maxW))
            }
            minWidths.append(rowMin)
            maxWidths.append(rowMax)
        }

        return TranscriptTableCellContents(
            columnCount: columnCount,
            cells: allRows,
            cellMinWidths: minWidths,
            cellMaxWidths: maxWidths,
            alignments: table.alignments,
            horizontalPadding: hPad)
    }
}

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

    var measuredWidth: CGFloat { columnWidths.reduce(0, +) }
    var totalHeight: CGFloat { rowHeights.reduce(0, +) }

    // MARK: - Build

    /// 列宽分配采用 CSS-like min/max 模型:
    /// 1. 若 `sum(maxCol) <= maxWidth`:每列给 max,富余全塞给最后一列。
    /// 2. 若 `sum(minCol) <= maxWidth`:每列从 min 起步,剩余空间按 max 权重分配
    ///    (max 大的列拿得多,max 小的列几乎不被压)。
    /// 3. 极端情况 min 都装不下:等比缩 min,不让表格溢出。
    static func make(
        contents: TranscriptTableCellContents,
        theme: TranscriptTheme,
        maxWidth: CGFloat
    ) -> TranscriptTableLayout {
        guard contents.columnCount > 0 else {
            return TranscriptTableLayout(
                columnWidths: [],
                rowHeights: [],
                cells: [],
                alignments: [],
                theme: theme)
        }

        let hPad = contents.horizontalPadding
        let vPad: CGFloat = theme.markdown.blockPadding
        let columnCount = contents.columnCount

        // 每列 min/max = 该列所有 cell 的 max。min 再兜底 40(防止空列细成针)。
        var columnMins = [CGFloat](repeating: 0, count: columnCount)
        var columnMaxs = [CGFloat](repeating: 0, count: columnCount)
        for r in 0..<contents.cells.count {
            for c in 0..<columnCount {
                columnMins[c] = max(columnMins[c], contents.cellMinWidths[r][c])
                columnMaxs[c] = max(columnMaxs[c], contents.cellMaxWidths[r][c])
            }
        }
        for c in 0..<columnCount {
            columnMins[c] = max(columnMins[c], 40)
            columnMaxs[c] = max(columnMaxs[c], columnMins[c])
        }

        let minSum = columnMins.reduce(0, +)
        let maxSum = columnMaxs.reduce(0, +)
        let columnWidths: [CGFloat]
        if maxSum <= maxWidth {
            // 富余:全给最后一列,维持原有「铺满气泡宽度」的视觉。
            var ws = columnMaxs
            ws[ws.count - 1] += (maxWidth - maxSum)
            columnWidths = ws
        } else if minSum < maxWidth {
            // 常规:min 起步 + 按 max 权重分剩余空间。
            let slack = maxWidth - minSum
            let totalMax = max(maxSum, 1)
            columnWidths = zip(columnMins, columnMaxs).map { (mn, mx) in
                mn + slack * (mx / totalMax)
            }
        } else {
            // min 都超宽:等比压 min,避免横向溢出气泡。
            let scale = maxWidth / max(minSum, 1)
            columnWidths = columnMins.map { max(1, floor($0 * scale)) }
        }

        // 每行每列排版 cell
        var cells: [[TranscriptTextLayout]] = []
        var rowHeights: [CGFloat] = []
        for row in contents.cells {
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
            alignments: contents.alignments,
            theme: theme)
    }

    /// Table cell 在 table 自身坐标系里的 frame（左上为原点）。用于 hit-test /
    /// region frame 构造。`cellContentFrames[r][c]` = 第 r 行第 c 列 cell 里
    /// *layout 可画区域*（已扣除 hPad / vPad）。
    var cellContentFrames: [[CGRect]] {
        var rows: [[CGRect]] = []
        let hPad: CGFloat = TranscriptTableCellContents.horizontalPadding
        let vPad: CGFloat = theme.markdown.blockPadding
        var curY: CGFloat = 0
        for (r, rowH) in rowHeights.enumerated() {
            var cols: [CGRect] = []
            var curX: CGFloat = 0
            for (c, colW) in columnWidths.enumerated() {
                let cellLayout = cells[r][c]
                let align = alignment(for: c)
                let xOrigin: CGFloat
                switch align {
                case .center:
                    xOrigin = curX + max(0, (colW - cellLayout.measuredWidth) / 2)
                case .right:
                    xOrigin = curX + max(hPad, colW - hPad - cellLayout.measuredWidth)
                case .left, .none:
                    xOrigin = curX + hPad
                }
                let yOrigin = curY + vPad
                let w = max(1, cellLayout.measuredWidth)
                let h = max(1, cellLayout.totalHeight)
                cols.append(CGRect(x: xOrigin, y: yOrigin, width: w, height: h))
                curX += colW
            }
            rows.append(cols)
            curY += rowH
        }
        return rows
    }

    // MARK: - Draw

    /// 在 `origin`(flipped,左上角)画整个 table 到 `ctx`。
    /// `selections[r][c]` 若非空且 location != NSNotFound → 画高亮底色。
    func draw(origin: CGPoint, selections: [[NSRange]]? = nil, in ctx: CGContext) {
        guard !rowHeights.isEmpty, !columnWidths.isEmpty else { return }
        let hPad: CGFloat = TranscriptTableCellContents.horizontalPadding
        let vPad: CGFloat = theme.markdown.blockPadding
        let radius = theme.markdown.blockCornerRadius
        let tableRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: measuredWidth,
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

                let sel: NSRange? = {
                    guard let selections,
                          rowIndex < selections.count,
                          colIndex < selections[rowIndex].count else { return nil }
                    let r = selections[rowIndex][colIndex]
                    return (r.location != NSNotFound && r.length > 0) ? r : nil
                }()

                cellLayout.draw(
                    origin: CGPoint(x: xOrigin, y: yOrigin),
                    selection: sel,
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

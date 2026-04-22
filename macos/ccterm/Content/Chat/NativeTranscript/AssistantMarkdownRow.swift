import AppKit
import SwiftUI

/// Assistant 消息（纯文本部分）。
///
/// 三段分离：
/// 1. **Parse（init 时同步）**：`MarkdownDocument(parsing:)` 拆 segment。
/// 2. **Prebuild（init 时同步 + 高亮完成后再来一次）**：每个 segment 转成
///    layout 需要的「宽度无关」中间物（`NSAttributedString` 或 table 模型）。
///    syntax highlight 未就绪前 code block 用 plain monospaced；
///    `apply(codeTokens:)` 回灌后重 build 一次。
/// 3. **Layout（`makeSize(width:)`）**：按宽度喂 `TranscriptTextLayout` /
///    `TranscriptTableLayout` 排版，不做任何 parse / build。
///
/// window resize 只重 layout；theme / source 不变不重 parse；syntax highlight
/// 由 `TranscriptPreprocessor` 在 paint 前批量完成，无 plain→彩色跳变。
final class AssistantMarkdownRow: TranscriptRow {
    let source: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 一次性 parse 的结果。
    private let parsedDocument: MarkdownDocument

    /// 宽度无关的预构造物——和 `parsedDocument.segments` 一一对应。
    private var prebuilt: [PrebuiltSegment] = []

    /// 按当前 width 排版的结果。`makeSize` 填。
    private var rendered: [RenderedSegment] = []

    /// 每段 attributed segment 在 row 坐标系里的「layout 原点」——选中用。
    /// index 与 `prebuilt` / `rendered` 对齐。
    private var attributedOrigins: [Int: CGPoint] = [:]

    /// Code block header 的 click-to-copy 命中矩形，row 坐标系。`makeSize` 填，
    /// `codeBlockHit(atRowPoint:)` 读。segmentIndex 让 draw 能把"刚复制过"
    /// 的 icon 切成 checkmark；code 是原始字符串，不走 attributed string 避免
    /// syntax token 拼接 artifact。
    private var codeBlockHeaderRects: [(rect: CGRect, segmentIndex: Int, code: String)] = []

    /// 最近一次 copy 命中的 segment index。draw 在这个 index 上渲染 checkmark
    /// 代替 copy icon，是 click 的即时视觉反馈。`markCodeBlockCopied` 设置，
    /// 1.2s 后由 DispatchWorkItem 清空并触发 redraw。
    private var copiedSegmentIndex: Int?
    private var copiedResetWork: DispatchWorkItem?

    /// 每段 attributed segment 当前的选中 range。`NSNotFound` = 未选。
    private var selections: [Int: NSRange] = [:]

    /// 每个 table segment 的 per-cell 选中 range。`tableSelections[segIdx][row][col]`。
    /// 未选元素存 `NSRange(NSNotFound, 0)`。selectionRegions 按 cell 展开成独立
    /// region，每 cell 用 closure 写入这里。
    private var tableSelections: [Int: [[NSRange]]] = [:]

    /// 每个 list segment 的 per-text 选中 range。key = list 里的文本
    /// DFS 线性 index（与 `TranscriptListLayout.flattenedTexts` 对齐）。
    /// marker 不可选，所以这里的 key 只索引到正文子 layout。
    private var listSelections: [Int: [Int: NSRange]] = [:]

    init(source: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.source = source
        self.theme = theme
        self.stable = stable
        self.parsedDocument = MarkdownDocument(parsing: source)
        super.init()
        self.prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens:[:])
    }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(source)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - Preprocessor 回灌 code block tokens

    /// `TranscriptPreprocessor` 在 `setEntries` 的 Task 里 batch await highlight
    /// 完成后调这里。重 build 一次 prebuilt，清 layout cache。主线程调用。
    func apply(codeTokens: [Int: [SyntaxToken]]) {
        prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens:codeTokens)
        cachedWidth = 0
        rendered = []
        attributedOrigins = [:]
        codeBlockHeaderRects = []
        copiedResetWork?.cancel()
        copiedResetWork = nil
        copiedSegmentIndex = nil
        tableSelections = [:]
        listSelections = [:]
    }

    /// 暴露给 preprocessor 的请求列表：`(segmentIndex, code, language)`。
    var codeBlockRequests: [(segmentIndex: Int, code: String, language: String?)] {
        var out: [(Int, String, String?)] = []
        for (i, seg) in parsedDocument.segments.enumerated() {
            if case .codeBlock(let block) = seg {
                out.append((i, block.code, block.language))
            }
        }
        return out
    }

    // MARK: - Hit test (click-to-copy)

    /// Code block header hit info — segmentIndex lets callers flip the icon
    /// to a transient checkmark on the exact header that was clicked.
    struct CodeBlockHitInfo {
        let segmentIndex: Int
        let code: String
    }

    /// Returns the hit info for the code block whose header bar covers
    /// `pointInRow`, or `nil` if the point is outside every header.
    func codeBlockHit(atRowPoint pointInRow: CGPoint) -> CodeBlockHitInfo? {
        for entry in codeBlockHeaderRects where entry.rect.contains(pointInRow) {
            return CodeBlockHitInfo(segmentIndex: entry.segmentIndex, code: entry.code)
        }
        return nil
    }

    /// Flips the target code block's icon to a checkmark for `dwell` seconds,
    /// then reverts. Caller passes a `redraw` closure to force a repaint on
    /// both transitions — the row doesn't own the table view.
    func markCodeBlockCopied(
        segmentIndex: Int,
        dwell: TimeInterval = 1.2,
        redraw: @escaping () -> Void
    ) {
        copiedResetWork?.cancel()
        copiedSegmentIndex = segmentIndex
        redraw()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedSegmentIndex = nil
            self.copiedResetWork = nil
            redraw()
        }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    // MARK: - Layout

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width

        let contentWidth = max(40, width - 2 * theme.rowHorizontalPadding)
        var segments: [RenderedSegment] = []
        var origins: [Int: CGPoint] = [:]
        var newTableSelections: [Int: [[NSRange]]] = [:]
        var headerRects: [(rect: CGRect, segmentIndex: Int, code: String)] = []
        var y: CGFloat = theme.rowVerticalPadding

        for (idx, prebuiltSeg) in prebuilt.enumerated() {
            y += prebuiltSeg.topPadding

            switch prebuiltSeg {
            case .attributed(let attr, let kind, _):
                let maxWidth: CGFloat
                let layoutOriginX: CGFloat
                let layoutOriginY: CGFloat
                switch kind {
                case .text, .heading:
                    maxWidth = contentWidth
                    layoutOriginX = theme.rowHorizontalPadding
                    layoutOriginY = y
                case .blockquote:
                    let barSpace = theme.markdown.blockquoteBarWidth + theme.markdown.blockquoteBarGap
                    maxWidth = max(40, contentWidth - barSpace)
                    layoutOriginX = theme.rowHorizontalPadding + barSpace
                    layoutOriginY = y
                case .codeBlock(let header):
                    maxWidth = max(40, contentWidth - 2 * theme.codeBlockHorizontalPadding)
                    layoutOriginX = theme.rowHorizontalPadding + theme.codeBlockHorizontalPadding
                    layoutOriginY = y + theme.codeBlockHeaderHeight + theme.codeBlockVerticalPadding
                    // Row-space hit rect for the click-to-copy header bar.
                    headerRects.append((
                        rect: CGRect(
                            x: theme.rowHorizontalPadding,
                            y: y,
                            width: contentWidth,
                            height: theme.codeBlockHeaderHeight),
                        segmentIndex: idx,
                        code: header.code))
                }
                let layout = TranscriptTextLayout.make(attributed: attr, maxWidth: maxWidth)
                segments.append(.attributed(
                    layout, kind: kind,
                    layoutOrigin: CGPoint(x: layoutOriginX, y: layoutOriginY)))
                origins[idx] = CGPoint(x: layoutOriginX, y: layoutOriginY)

                switch kind {
                case .codeBlock:
                    y += theme.codeBlockHeaderHeight
                        + layout.totalHeight
                        + 2 * theme.codeBlockVerticalPadding
                default:
                    y += layout.totalHeight
                }

            case .list(let contents, _):
                let layout = TranscriptListLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                let origin = CGPoint(x: theme.rowHorizontalPadding, y: y)
                segments.append(.list(layout, origin: origin))
                y += layout.totalHeight

            case .table(let contents, _):
                let tableLayout = TranscriptTableLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                segments.append(.table(
                    tableLayout,
                    origin: CGPoint(x: theme.rowHorizontalPadding, y: y)))
                // 初始化 selection 矩阵：保留已有选中（contentHash 不变时 makeSize
                // 会被 resize 触发重入），未命中 row/col 的 slot 填 NSNotFound。
                let rowCount = tableLayout.rowHeights.count
                let colCount = tableLayout.columnWidths.count
                var matrix = [[NSRange]](
                    repeating: [NSRange](
                        repeating: NSRange(location: NSNotFound, length: 0),
                        count: colCount),
                    count: rowCount)
                if let existing = tableSelections[idx] {
                    for r in 0..<min(rowCount, existing.count) {
                        for c in 0..<min(colCount, existing[r].count) {
                            matrix[r][c] = existing[r][c]
                        }
                    }
                }
                newTableSelections[idx] = matrix
                y += tableLayout.totalHeight

            case .thematicBreak:
                segments.append(.thematicBreak(y: y))
                y += 1
            }
        }

        y += theme.rowVerticalPadding
        rendered = segments
        attributedOrigins = origins
        codeBlockHeaderRects = headerRects
        tableSelections = newTableSelections
        cachedHeight = y
    }

    // MARK: - Draw

    override func draw(in ctx: CGContext, bounds: CGRect) {
        for (idx, seg) in rendered.enumerated() {
            switch seg {
            case .attributed(let layout, let kind, let origin):
                let sel = selections[idx]
                let selectionForDraw: NSRange? =
                    (sel?.location ?? NSNotFound) != NSNotFound && (sel?.length ?? 0) > 0 ? sel : nil
                switch kind {
                case .text, .heading:
                    layout.draw(origin: origin, selection: selectionForDraw, in: ctx)
                case .blockquote:
                    drawBlockquoteBar(origin: origin, height: layout.totalHeight, in: ctx)
                    layout.draw(origin: origin, selection: selectionForDraw, in: ctx)
                case .codeBlock(let header):
                    drawCodeBlockBackground(
                        layoutOrigin: origin,
                        layoutHeight: layout.totalHeight,
                        header: header,
                        segmentIndex: idx,
                        bounds: bounds,
                        in: ctx)
                    layout.draw(origin: origin, selection: selectionForDraw, in: ctx)
                }

            case .list(let listLayout, let origin):
                let perText = listSelections[idx] ?? [:]
                listLayout.draw(
                    origin: origin,
                    selectionResolver: { textIdx in
                        guard let r = perText[textIdx] else { return nil }
                        return (r.location != NSNotFound && r.length > 0) ? r : nil
                    },
                    in: ctx)

            case .table(let tableLayout, let origin):
                tableLayout.draw(
                    origin: origin,
                    selections: tableSelections[idx],
                    in: ctx)

            case .thematicBreak(let y):
                drawThematicBreak(y: y, width: bounds.width, in: ctx)
            }
        }
    }

    private func drawBlockquoteBar(origin: CGPoint, height: CGFloat, in ctx: CGContext) {
        let barW = theme.markdown.blockquoteBarWidth
        let barGap = theme.markdown.blockquoteBarGap
        let barX = origin.x - barGap - barW
        let barRect = CGRect(x: barX, y: origin.y, width: barW, height: height)
        ctx.saveGState()
        ctx.setFillColor(theme.markdown.blockquoteBarColor.cgColor)
        let path = CGPath(
            roundedRect: barRect,
            cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func drawCodeBlockBackground(
        layoutOrigin: CGPoint,
        layoutHeight: CGFloat,
        header: CodeBlockHeader,
        segmentIndex: Int,
        bounds: CGRect,
        in ctx: CGContext
    ) {
        // Full block outline — header strip is painted on top of this, body
        // fill stays visible in the bottom half. Keeping one outer rounded
        // rect means we never have to align the header's bottom edge with
        // the body's top edge pixel-perfectly.
        let fullRect = CGRect(
            x: theme.rowHorizontalPadding,
            y: layoutOrigin.y - theme.codeBlockVerticalPadding - theme.codeBlockHeaderHeight,
            width: bounds.width - 2 * theme.rowHorizontalPadding,
            height: layoutHeight + 2 * theme.codeBlockVerticalPadding + theme.codeBlockHeaderHeight)
        ctx.saveGState()
        ctx.setFillColor(theme.markdown.codeBlockBackground.cgColor)
        let bodyPath = CGPath(
            roundedRect: fullRect,
            cornerWidth: theme.codeBlockCornerRadius,
            cornerHeight: theme.codeBlockCornerRadius,
            transform: nil)
        ctx.addPath(bodyPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Header strip — same top corners as the body, square bottom corners.
        // A full rounded-rect for the header would leave diagonal body-color
        // slivers poking through at the bottom-left/right where the header
        // rounds inward.
        let headerRect = CGRect(
            x: fullRect.minX,
            y: fullRect.minY,
            width: fullRect.width,
            height: theme.codeBlockHeaderHeight)
        ctx.saveGState()
        ctx.setFillColor(theme.codeBlockHeaderBackground.cgColor)
        let headerPath = Self.roundedRectPath(
            rect: headerRect,
            topLeft: theme.codeBlockCornerRadius,
            topRight: theme.codeBlockCornerRadius,
            bottomLeft: 0,
            bottomRight: 0)
        ctx.addPath(headerPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Language label — vertically centered on the header mid-line.
        // Skipped when the fence had no language: a lone "copy" text next to
        // the icon reads as noise.
        if let line = header.line {
            let glyphHeight = header.ascent + header.descent
            let baselineY = headerRect.minY
                + (theme.codeBlockHeaderHeight - glyphHeight) / 2
                + header.ascent
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(
                x: headerRect.minX + theme.codeBlockHeaderLabelInsetX,
                y: baselineY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // Right-aligned copy icon — or a checkmark in the 1.2s window after
        // a successful click. Inline transient state is the primary feedback
        // (toast was too far from the click site + got lost in busy chats).
        let iconSide = theme.codeBlockHeaderIconSize
        let iconRect = CGRect(
            x: headerRect.maxX - theme.codeBlockHeaderIconInsetX - iconSide,
            y: headerRect.minY + (theme.codeBlockHeaderHeight - iconSide) / 2,
            width: iconSide,
            height: iconSide)
        if copiedSegmentIndex == segmentIndex {
            Self.drawCheckmarkIcon(
                in: ctx, rect: iconRect,
                tint: theme.codeBlockHeaderForeground)
        } else {
            Self.drawCopyIcon(
                in: ctx, rect: iconRect,
                tint: theme.codeBlockHeaderForeground)
        }
    }

    /// Per-corner rounded rect path. `CGPath(roundedRect:...)` only supports a
    /// single uniform radius, but the code-block header needs its two bottom
    /// corners square so it meets the body cleanly.
    private static func roundedRectPath(
        rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomLeft: CGFloat,
        bottomRight: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        if topRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRight),
                radius: topRight)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
                radius: bottomRight)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
                radius: bottomLeft)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        if topLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + topLeft, y: rect.minY),
                radius: topLeft)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }

    /// "doc.on.doc"-style glyph drawn with two stroked rounded rectangles.
    /// Pure CG — avoids shipping a template NSImage or bouncing through
    /// `NSGraphicsContext` just for a 13pt mono icon.
    private static func drawCopyIcon(
        in ctx: CGContext,
        rect: CGRect,
        tint: NSColor
    ) {
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        let stroke: CGFloat = 1.1
        let corner = side * 0.22
        let plateSide = side * 0.72
        let offset = side - plateSide

        ctx.saveGState()
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(stroke)

        // Back plate — anchored top-right.
        let back = CGRect(
            x: originX + offset,
            y: originY,
            width: plateSide,
            height: plateSide
        ).insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.addPath(CGPath(
            roundedRect: back,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil))
        ctx.strokePath()

        // Front plate — anchored bottom-left, overlapping the back.
        let front = CGRect(
            x: originX,
            y: originY + offset,
            width: plateSide,
            height: plateSide
        ).insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.addPath(CGPath(
            roundedRect: front,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil))
        ctx.strokePath()

        ctx.restoreGState()
    }

    /// Two-segment checkmark drawn in `rect`. Context is flipped (y grows
    /// down), so "lower-left → bottom → upper-right" maps to increasing then
    /// decreasing y. Line caps rounded to match the copy icon's stroke feel.
    private static func drawCheckmarkIcon(
        in ctx: CGContext,
        rect: CGRect,
        tint: NSColor
    ) {
        let side = min(rect.width, rect.height)
        let inset = side * 0.08
        let x = rect.minX + (rect.width - side) / 2 + inset
        let y = rect.minY + (rect.height - side) / 2 + inset
        let s = side - inset * 2
        let stroke = max(1.3, side * 0.12)

        ctx.saveGState()
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: x + s * 0.10, y: y + s * 0.52))
        ctx.addLine(to: CGPoint(x: x + s * 0.42, y: y + s * 0.80))
        ctx.addLine(to: CGPoint(x: x + s * 0.92, y: y + s * 0.24))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawThematicBreak(y: CGFloat, width: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: theme.rowHorizontalPadding, y: y + 0.5))
        ctx.addLine(to: CGPoint(x: width - theme.rowHorizontalPadding, y: y + 0.5))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Data model

    enum SegmentKind {
        case text, heading, blockquote
        case codeBlock(CodeBlockHeader)
    }

    /// Header bar drawn above each fenced code block. All fields are
    /// pre-computed at prebuild time so the resize-hot `makeSize` / `draw`
    /// paths stay allocation-free.
    struct CodeBlockHeader {
        /// Raw code string copied on header click. Not derived from the
        /// attributed body so tokenizer boundary whitespace can't leak in.
        let code: String
        /// Pre-typeset language label ("swift", "python" …). `nil` when the
        /// fence had no language — in that case the header renders only the
        /// copy affordance on the right.
        let line: CTLine?
        let ascent: CGFloat
        let descent: CGFloat
    }

    enum PrebuiltSegment {
        case attributed(NSAttributedString, kind: SegmentKind, topPadding: CGFloat)
        case list(TranscriptListContents, topPadding: CGFloat)
        case table(TranscriptTableCellContents, topPadding: CGFloat)
        case thematicBreak(topPadding: CGFloat)

        var topPadding: CGFloat {
            switch self {
            case .attributed(_, _, let p),
                 .list(_, let p),
                 .table(_, let p),
                 .thematicBreak(let p):
                return p
            }
        }
    }

    enum RenderedSegment {
        case attributed(TranscriptTextLayout, kind: SegmentKind, layoutOrigin: CGPoint)
        case list(TranscriptListLayout, origin: CGPoint)
        case table(TranscriptTableLayout, origin: CGPoint)
        case thematicBreak(y: CGFloat)
    }

}

// MARK: - TextSelectable

extension AssistantMarkdownRow: TextSelectable {
    var selectableRegions: [SelectableTextRegion] {
        var regions: [SelectableTextRegion] = []
        for (idx, seg) in rendered.enumerated() {
            switch seg {
            case .attributed(let layout, _, let origin):
                guard !layout.lines.isEmpty else { continue }
                let region = SelectableTextRegion(
                    rowStableId: stableId,
                    regionIndex: Self.regionIndex(segment: idx),
                    frameInRow: CGRect(
                        x: origin.x,
                        y: origin.y,
                        width: max(layout.measuredWidth, 1),
                        height: max(layout.totalHeight, 1)),
                    layout: layout,
                    setSelection: { [weak self] range in
                        self?.selections[idx] = range
                    })
                regions.append(region)

            case .list(let listLayout, let origin):
                // 每个正文子 layout 独立 region。marker 不在可选文本流里，
                // 所以跨 item 的选中自动只覆盖正文 —— 复制出来没有 marker
                // 也没有"前导 indent"字符。
                for (textIdx, textLayout, originInList) in listLayout.flattenedTexts() {
                    guard !textLayout.lines.isEmpty else { continue }
                    let regionFrame = CGRect(
                        x: origin.x + originInList.x,
                        y: origin.y + originInList.y,
                        width: max(textLayout.measuredWidth, 1),
                        height: max(textLayout.totalHeight, 1))
                    let region = SelectableTextRegion(
                        rowStableId: stableId,
                        regionIndex: Self.regionIndex(segment: idx, listTextIndex: textIdx),
                        frameInRow: regionFrame,
                        layout: textLayout,
                        setSelection: { [weak self] range in
                            guard let self else { return }
                            var m = self.listSelections[idx] ?? [:]
                            m[textIdx] = range
                            self.listSelections[idx] = m
                        })
                    regions.append(region)
                }

            case .table(let tableLayout, let origin):
                // 每 cell 独立 region：frame = table-local cellContentFrame offset 到 row 坐标系。
                // regionIndex 编码 (segIdx, cellRow, cellCol) 保证跨 cell 在行内自然排序。
                let frames = tableLayout.cellContentFrames
                for (r, rowFrames) in frames.enumerated() {
                    for (c, cellFrame) in rowFrames.enumerated() {
                        let cellLayout = tableLayout.cells[r][c]
                        guard !cellLayout.lines.isEmpty else { continue }
                        let regionFrame = CGRect(
                            x: origin.x + cellFrame.origin.x,
                            y: origin.y + cellFrame.origin.y,
                            width: cellFrame.width,
                            height: cellFrame.height)
                        let region = SelectableTextRegion(
                            rowStableId: stableId,
                            regionIndex: Self.regionIndex(segment: idx, tableRow: r, tableCol: c),
                            frameInRow: regionFrame,
                            layout: cellLayout,
                            setSelection: { [weak self] range in
                                guard let self else { return }
                                var matrix = self.tableSelections[idx] ?? []
                                guard r < matrix.count, c < matrix[r].count else { return }
                                matrix[r][c] = range
                                self.tableSelections[idx] = matrix
                            })
                        regions.append(region)
                    }
                }

            case .thematicBreak:
                continue
            }
        }
        return regions
    }

    var selectionHeader: String? { nil }

    func clearSelection() {
        selections.removeAll()
        // 把 table 选中矩阵也清掉；下一次 makeSize 会按需重建。
        for (idx, matrix) in tableSelections {
            let empty = [[NSRange]](
                repeating: [NSRange](
                    repeating: NSRange(location: NSNotFound, length: 0),
                    count: matrix.first?.count ?? 0),
                count: matrix.count)
            tableSelections[idx] = empty
        }
        listSelections.removeAll()
    }

    /// 把 (segIdx, row, col) 编码成单调递增的 regionIndex：
    /// table 最多 1000 行 1000 列 → 6 位足够；segment 不会爆 1000 个。
    private static func regionIndex(segment: Int, tableRow: Int = 0, tableCol: Int = 0) -> Int {
        segment * 1_000_000 + tableRow * 1_000 + tableCol
    }

    /// List 正文 text 的 regionIndex：`segment * 1_000_000 + listTextIndex`。
    /// 和 table 的编码共用同一块空间（table 单 segment 里行列乘积也不会爆
    /// 1_000_000），一个 segment 不会同时是 list 和 table，所以不会撞。
    private static func regionIndex(segment: Int, listTextIndex: Int) -> Int {
        segment * 1_000_000 + listTextIndex
    }
}

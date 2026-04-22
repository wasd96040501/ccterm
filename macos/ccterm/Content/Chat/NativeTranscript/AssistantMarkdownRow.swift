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

    /// 每段 attributed segment 当前的选中 range。`NSNotFound` = 未选。
    private var selections: [Int: NSRange] = [:]

    /// 每个 table segment 的 per-cell 选中 range。`tableSelections[segIdx][row][col]`。
    /// 未选元素存 `NSRange(NSNotFound, 0)`。selectionRegions 按 cell 展开成独立
    /// region，每 cell 用 closure 写入这里。
    private var tableSelections: [Int: [[NSRange]]] = [:]

    init(source: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.source = source
        self.theme = theme
        self.stable = stable
        self.parsedDocument = MarkdownDocument(parsing: source)
        super.init()
        self.prebuilt = Self.buildPrebuilt(
            document: parsedDocument,
            theme: theme,
            codeTokens: [:])
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
        prebuilt = Self.buildPrebuilt(
            document: parsedDocument,
            theme: theme,
            codeTokens: codeTokens)
        cachedWidth = 0
        rendered = []
        attributedOrigins = [:]
        tableSelections = [:]
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

    // MARK: - Layout

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width

        let contentWidth = max(40, width - 2 * theme.rowHorizontalPadding)
        var segments: [RenderedSegment] = []
        var origins: [Int: CGPoint] = [:]
        var newTableSelections: [Int: [[NSRange]]] = [:]
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
                case .codeBlock:
                    maxWidth = max(40, contentWidth - 2 * theme.codeBlockHorizontalPadding)
                    layoutOriginX = theme.rowHorizontalPadding + theme.codeBlockHorizontalPadding
                    layoutOriginY = y + theme.codeBlockVerticalPadding
                }
                let layout = TranscriptTextLayout.make(attributed: attr, maxWidth: maxWidth)
                segments.append(.attributed(
                    layout, kind: kind,
                    layoutOrigin: CGPoint(x: layoutOriginX, y: layoutOriginY)))
                origins[idx] = CGPoint(x: layoutOriginX, y: layoutOriginY)

                switch kind {
                case .codeBlock:
                    y += layout.totalHeight + 2 * theme.codeBlockVerticalPadding
                default:
                    y += layout.totalHeight
                }

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
                case .codeBlock:
                    drawCodeBlockBackground(
                        layoutOrigin: origin,
                        layoutHeight: layout.totalHeight,
                        bounds: bounds,
                        in: ctx)
                    layout.draw(origin: origin, selection: selectionForDraw, in: ctx)
                }

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
        bounds: CGRect,
        in ctx: CGContext
    ) {
        let rect = CGRect(
            x: theme.rowHorizontalPadding,
            y: layoutOrigin.y - theme.codeBlockVerticalPadding,
            width: bounds.width - 2 * theme.rowHorizontalPadding,
            height: layoutHeight + 2 * theme.codeBlockVerticalPadding)
        ctx.saveGState()
        ctx.setFillColor(theme.markdown.codeBlockBackground.cgColor)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: theme.codeBlockCornerRadius,
            cornerHeight: theme.codeBlockCornerRadius,
            transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
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
        case text, heading, blockquote, codeBlock
    }

    enum PrebuiltSegment {
        case attributed(NSAttributedString, kind: SegmentKind, topPadding: CGFloat)
        case table(TranscriptTableCellContents, topPadding: CGFloat)
        case thematicBreak(topPadding: CGFloat)

        var topPadding: CGFloat {
            switch self {
            case .attributed(_, _, let p), .table(_, let p), .thematicBreak(let p):
                return p
            }
        }
    }

    enum RenderedSegment {
        case attributed(TranscriptTextLayout, kind: SegmentKind, layoutOrigin: CGPoint)
        case table(TranscriptTableLayout, origin: CGPoint)
        case thematicBreak(y: CGFloat)
    }

    // MARK: - Prebuild pipeline

    private static func buildPrebuilt(
        document: MarkdownDocument,
        theme: TranscriptTheme,
        codeTokens: [Int: [SyntaxToken]]
    ) -> [PrebuiltSegment] {
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        var out: [PrebuiltSegment] = []
        out.reserveCapacity(document.segments.count)

        for (idx, seg) in document.segments.enumerated() {
            let gap = gapBefore(idx: idx, segment: seg, theme: theme.markdown)

            switch seg {
            case .markdown(let blocks):
                out.append(.attributed(builder.build(blocks: blocks), kind: .text, topPadding: gap))
            case .heading(let level, let inlines):
                out.append(.attributed(builder.buildHeading(level: level, inlines: inlines), kind: .heading, topPadding: gap))
            case .blockquote(let blocks):
                out.append(.attributed(builder.buildBlockquote(blocks: blocks), kind: .blockquote, topPadding: gap))
            case .codeBlock(let block):
                let attr = buildCodeBlockAttributed(
                    block: block,
                    tokens: codeTokens[idx],
                    theme: theme)
                out.append(.attributed(attr, kind: .codeBlock, topPadding: gap))
            case .table(let table):
                let contents = TranscriptTableCellContents.make(table: table, builder: builder)
                out.append(.table(contents, topPadding: gap))
            case .mathBlock(let raw):
                let attr = NSAttributedString(
                    string: raw,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: theme.markdown.codeFontSize, weight: .regular),
                        .foregroundColor: theme.markdown.primaryColor,
                    ])
                out.append(.attributed(attr, kind: .text, topPadding: gap))
            case .thematicBreak:
                out.append(.thematicBreak(topPadding: gap))
            }
        }
        return out
    }

    private static func buildCodeBlockAttributed(
        block: MarkdownCodeBlock,
        tokens: [SyntaxToken]?,
        theme: TranscriptTheme
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(
            ofSize: theme.markdown.codeFontSize, weight: .regular)
        if let tokens, !tokens.isEmpty {
            // Build with dynamic NSColors — the attributed string outlives the
            // current appearance (it's cached in the layout). Each token's
            // color resolves at draw time via
            // `NSAppearance.performAsCurrentDrawingAppearance` in the row view,
            // so switching system appearance doesn't need a token rebuild.
            let result = NSMutableAttributedString()
            for token in tokens {
                let scope = token.scope
                let color = NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                    let scheme: ColorScheme = match == .darkAqua ? .dark : .light
                    return NSColor(SyntaxTheme.color(for: scope, scheme: scheme))
                }
                result.append(NSAttributedString(string: token.text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            }
            return result
        }
        return NSAttributedString(
            string: block.code,
            attributes: [
                .font: font,
                .foregroundColor: theme.markdown.primaryColor,
            ])
    }

    private static func gapBefore(idx: Int, segment: MarkdownSegment, theme: MarkdownTheme) -> CGFloat {
        if idx == 0 { return 0 }
        if case .heading = segment { return theme.l1 }
        return theme.l2
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
    }

    /// 把 (segIdx, row, col) 编码成单调递增的 regionIndex：
    /// table 最多 1000 行 1000 列 → 6 位足够；segment 不会爆 1000 个。
    private static func regionIndex(segment: Int, tableRow: Int = 0, tableCol: Int = 0) -> Int {
        segment * 1_000_000 + tableRow * 1_000 + tableCol
    }
}

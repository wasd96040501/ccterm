import AppKit
import CoreText
import SwiftUI

/// Assistant 消息（纯文本部分）。
///
/// 三段分离：
/// 1. **Parse**（init 时同步 / prepare 阶段 off-main）：`MarkdownDocument(parsing:)` 拆 segment。
/// 2. **Prebuild**（parse 后 / highlight 回灌后）：每个 segment 转成宽度无关的
///    `PrebuiltSegment`。syntax highlight 未就绪前 code block 用 plain
///    monospaced；`applyTokens(_:)` 回灌后重 build 一次。
/// 3. **Layout + Paint**（main 或 prepare 阶段）：按宽度喂
///    `TranscriptPrepare.layoutAssistant` 得到 `RenderedSegment`，直接缓存；
///    `draw` / `selectableRegions` / `hitRegions` 都直接 walk 这个数组。
///
/// 选中 key schema：
/// - text / heading / blockquote / codeBlock body → `segmentIndex: Int`
/// - list → `ListTextKey(base: segmentIndex, textIdx:)`
/// - table → `TableCellKey(base: segmentIndex, row:, col:)`
///
/// 这三种 key 必须在 layout rebuild（resize）间保持等价——row 的 `selections`
/// 字典就靠它们 survive。`segmentIndex` 是 `RenderedSegment` 数组下标，
/// prebuilt → rendered 转换保持下标稳定；table row / col 与 list textIdx 天然
/// 稳定。
final class AssistantMarkdownRow: TranscriptRow {
    let source: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    /// 一次性 parse 的结果。
    private let parsedDocument: MarkdownDocument

    /// 宽度无关的预构造物——和 `parsedDocument.segments` 一一对应。
    private var prebuilt: [PrebuiltSegment] = []

    /// 宽度相关的排版结果。唯一的渲染 IR——draw / hit / select 都读这个。
    private var cachedRendered: [RenderedSegment] = []
    /// Code block header 的 row-local 矩形 + segment index + 原始 code。
    /// `applyLayout` 时由 `TranscriptPrepare.layoutAssistant` 喂进来，
    /// `hitRegions` 据此派生 copy 图标的点击区。
    private var cachedHeaderRects: [(rect: CGRect, segmentIndex: Int, code: String)] = []

    /// Row-owned 选中字典。`setSelection` 闭包写这里，`draw` 路径读这里。
    /// Key 可以是 Int（text 段）/ `TableCellKey` / `ListTextKey`——都是
    /// `Hashable`，装 `AnyHashable` 统一存。
    private var selections: [AnyHashable: NSRange] = [:]

    /// 最近一次 copy 命中的 segment index。代表 copy 反馈期内该 code block 的
    /// header 图标应渲染为 checkmark 而非 copy。`markCodeBlockCopied` 设置，
    /// 1.2s 后由 DispatchWorkItem 清空并触发 redraw。
    private var copiedSegmentIndex: Int?
    private var copiedResetWork: DispatchWorkItem?

    init(source: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.source = source
        self.theme = theme
        self.stable = stable
        self.parsedDocument = MarkdownDocument(parsing: source)
        super.init()
        self.prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens: [:])
    }

    /// Adopts a precomputed `AssistantPrepared` — parse + prebuild already done
    /// off-main by `TranscriptPrepare.assistant`. O(1) alternative to
    /// `init(source:theme:stable:)`.
    init(prepared: AssistantPrepared, theme: TranscriptTheme) {
        self.source = prepared.source
        self.theme = theme
        self.stable = prepared.stable
        self.parsedDocument = prepared.parsedDocument
        super.init()
        self.prebuilt = prepared.prebuilt
    }

    /// 显式标注：Swift 6 子类 deinit 不自动继承父类 nonisolated 属性，
    /// 需要逐层声明才能真正跳过 executor-hop。见 `TranscriptRow.deinit`。
    nonisolated deinit { }

    /// Adopts a precomputed `AssistantLayoutData` — CoreText already run
    /// off-main by `TranscriptPrepare.layoutAssistant`.
    func applyLayout(_ layout: AssistantLayoutData) {
        self.cachedWidth = layout.cachedWidth
        self.cachedHeight = layout.cachedHeight
        self.cachedRendered = layout.rendered
        self.cachedHeaderRects = layout.codeBlockHeaderRects
    }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(source)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    // MARK: - Layout

    /// 宽度变了 → 重跑 layoutAssistant，采纳新的 rendered。重活集中在
    /// `TranscriptTextLayout.make`（CTTypesetter），和 prepare 阶段等价。
    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        let layout = TranscriptPrepare.layoutAssistant(
            prebuilt: prebuilt, theme: theme, width: width)
        applyLayout(layout)
    }

    /// Highlight 回灌：重 build prebuilt（带彩色），清 rendered 缓存 +
    /// 选中状态。下一次 `makeSize` 触发 `layoutAssistant` 重排。
    /// Tokens 的 key 是 `segmentIndex`（Int）——只处理 Int keys，其他类型的
    /// key 属于其他 row 的业务被忽略。
    func applyTokens(_ tokens: [AnyHashable: [SyntaxToken]]) {
        var codeTokens: [Int: [SyntaxToken]] = [:]
        for (key, value) in tokens {
            if let i = key.base as? Int {
                codeTokens[i] = value
            }
        }
        prebuilt = MarkdownRowPrebuilder.build(
            document: parsedDocument,
            theme: theme,
            codeTokens: codeTokens)
        cachedWidth = 0
        cachedRendered = []
        cachedHeaderRects = []
        copiedResetWork?.cancel()
        copiedResetWork = nil
        copiedSegmentIndex = nil
        selections.removeAll()
    }

    // MARK: - Click-to-copy

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

    // MARK: - Draw

    override func draw(in ctx: CGContext, bounds: CGRect) {
        guard !cachedRendered.isEmpty else { return }
        let contentWidth = max(40, cachedWidth - 2 * theme.rowHorizontalPadding)

        for (idx, seg) in cachedRendered.enumerated() {
            switch seg {
            case .attributed(let layout, let kind, let origin):
                drawAttributed(
                    segmentIndex: idx,
                    layout: layout,
                    kind: kind,
                    origin: origin,
                    contentWidth: contentWidth,
                    in: ctx)

            case .list(let listLayout, let origin):
                let resolver: (Int) -> NSRange? = { textIdx in
                    let r = self.selections[ListTextKey(base: idx, textIdx: textIdx)]
                    guard let r, r.location != NSNotFound, r.length > 0 else { return nil }
                    return r
                }
                listLayout.draw(
                    origin: origin,
                    selectionResolver: resolver,
                    in: ctx)

            case .table(let tableLayout, let origin):
                let matrix = tableSelectionMatrix(
                    segmentIndex: idx,
                    rowCount: tableLayout.cells.count,
                    colCount: tableLayout.cells.first?.count ?? 0)
                tableLayout.draw(origin: origin, selections: matrix, in: ctx)

            case .thematicBreak(let y):
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.separatorColor.cgColor)
                ctx.setLineWidth(1)
                let lineRect = CGRect(
                    x: theme.rowHorizontalPadding,
                    y: y + 0.5,
                    width: cachedWidth - 2 * theme.rowHorizontalPadding,
                    height: 0)
                ctx.move(to: CGPoint(x: lineRect.minX, y: lineRect.minY))
                ctx.addLine(to: CGPoint(x: lineRect.maxX, y: lineRect.minY))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    private func drawAttributed(
        segmentIndex idx: Int,
        layout: TranscriptTextLayout,
        kind: SegmentKind,
        origin: CGPoint,
        contentWidth: CGFloat,
        in ctx: CGContext
    ) {
        switch kind {
        case .text, .heading:
            let sel = textSelection(for: idx)
            layout.draw(origin: origin, selection: sel, in: ctx)

        case .blockquote:
            let barW = theme.markdown.blockquoteBarWidth
            let barGap = theme.markdown.blockquoteBarGap
            let barRect = CGRect(
                x: origin.x - barGap - barW,
                y: origin.y,
                width: barW,
                height: layout.totalHeight)
            ctx.saveGState()
            ctx.setFillColor(theme.markdown.blockquoteBarColor.cgColor)
            let barPath = CGPath(
                roundedRect: barRect,
                cornerWidth: 1,
                cornerHeight: 1,
                transform: nil)
            ctx.addPath(barPath)
            ctx.fillPath()
            ctx.restoreGState()

            let sel = textSelection(for: idx)
            layout.draw(origin: origin, selection: sel, in: ctx)

        case .codeBlock(let header):
            let bodyRect = CGRect(
                x: theme.rowHorizontalPadding,
                y: origin.y - theme.codeBlockVerticalPadding - theme.codeBlockHeaderHeight,
                width: contentWidth,
                height: layout.totalHeight
                    + 2 * theme.codeBlockVerticalPadding
                    + theme.codeBlockHeaderHeight)
            ctx.saveGState()
            ctx.setFillColor(theme.markdown.codeBlockBackground.cgColor)
            let bodyPath = CGPath(
                roundedRect: bodyRect,
                cornerWidth: theme.codeBlockCornerRadius,
                cornerHeight: theme.codeBlockCornerRadius,
                transform: nil)
            ctx.addPath(bodyPath)
            ctx.fillPath()
            ctx.restoreGState()

            let headerRect = CGRect(
                x: bodyRect.minX,
                y: bodyRect.minY,
                width: bodyRect.width,
                height: theme.codeBlockHeaderHeight)
            let headerPath = Self.roundedRectPath(
                rect: headerRect,
                topLeft: theme.codeBlockCornerRadius,
                topRight: theme.codeBlockCornerRadius,
                bottomLeft: 0,
                bottomRight: 0)
            ctx.saveGState()
            ctx.setFillColor(theme.codeBlockHeaderBackground.cgColor)
            ctx.addPath(headerPath)
            ctx.fillPath()
            ctx.restoreGState()

            if let langLine = header.line {
                let glyphHeight = header.ascent + header.descent
                let labelTop = headerRect.minY
                    + (theme.codeBlockHeaderHeight - glyphHeight) / 2
                let baselineY = labelTop + header.ascent
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(
                    x: headerRect.minX + theme.codeBlockHeaderLabelInsetX,
                    y: baselineY)
                CTLineDraw(langLine, ctx)
                ctx.restoreGState()
            }

            let iconRect = iconRectInRow(forHeaderRect: headerRect)
            ctx.saveGState()
            if copiedSegmentIndex == idx {
                Self.drawCheckmarkIcon(
                    in: ctx,
                    rect: iconRect,
                    tint: theme.codeBlockHeaderForeground)
            } else {
                Self.drawCopyIcon(
                    in: ctx,
                    rect: iconRect,
                    tint: theme.codeBlockHeaderForeground)
            }
            ctx.restoreGState()

            let sel = textSelection(for: idx)
            layout.draw(origin: origin, selection: sel, in: ctx)
        }
    }

    // MARK: - Selection

    override var selectableRegions: [SelectableTextRegion] {
        var out: [SelectableTextRegion] = []
        let rowId = stableId

        for (idx, seg) in cachedRendered.enumerated() {
            switch seg {
            case .attributed(let layout, _, let origin):
                guard !layout.lines.isEmpty else { continue }
                let selKey: AnyHashable = idx
                out.append(SelectableTextRegion(
                    rowStableId: rowId,
                    ordering: Ordering(fragmentOrdinal: idx, subIndex: 0),
                    mode: .flow,
                    frameInRow: CGRect(
                        x: origin.x, y: origin.y,
                        width: max(layout.measuredWidth, 1),
                        height: max(layout.totalHeight, 1)),
                    layout: layout,
                    setSelection: { [weak self] range in
                        self?.selections[selKey] = range
                    }))

            case .list(let listLayout, let origin):
                for (textIdx, textLayout, originInList) in listLayout.flattenedTexts() {
                    guard !textLayout.lines.isEmpty else { continue }
                    let key = ListTextKey(base: idx, textIdx: textIdx)
                    out.append(SelectableTextRegion(
                        rowStableId: rowId,
                        ordering: Ordering(fragmentOrdinal: idx, subIndex: textIdx),
                        mode: .flow,
                        frameInRow: CGRect(
                            x: origin.x + originInList.x,
                            y: origin.y + originInList.y,
                            width: max(textLayout.measuredWidth, 1),
                            height: max(textLayout.totalHeight, 1)),
                        layout: textLayout,
                        setSelection: { [weak self] range in
                            self?.selections[key] = range
                        }))
                }

            case .table(let tableLayout, let origin):
                let cellFrames = tableLayout.cellContentFrames
                var sub = 0
                for (r, rowFrames) in cellFrames.enumerated() {
                    for (c, cellFrame) in rowFrames.enumerated() {
                        let cellLayout = tableLayout.cells[r][c]
                        guard !cellLayout.lines.isEmpty else {
                            sub += 1
                            continue
                        }
                        let cellKey = TableCellKey(base: idx, row: r, col: c)
                        out.append(SelectableTextRegion(
                            rowStableId: rowId,
                            ordering: Ordering(fragmentOrdinal: idx, subIndex: sub),
                            mode: .cell,
                            frameInRow: CGRect(
                                x: origin.x + cellFrame.origin.x,
                                y: origin.y + cellFrame.origin.y,
                                width: cellFrame.width,
                                height: cellFrame.height),
                            layout: cellLayout,
                            setSelection: { [weak self] range in
                                self?.selections[cellKey] = range
                            }))
                        sub += 1
                    }
                }

            case .thematicBreak:
                continue
            }
        }
        return out
    }

    override func clearSelection() {
        selections.removeAll()
    }

    // MARK: - Selection helpers

    /// 读取 text / heading / blockquote / codeBlock body 的选中 range。
    /// `NSNotFound` / 长度 0 视为无选中。
    private func textSelection(for segmentIdx: Int) -> NSRange? {
        guard let r = selections[segmentIdx as AnyHashable],
              r.location != NSNotFound, r.length > 0 else { return nil }
        return r
    }

    /// 读取 table 的 per-cell 选中矩阵。全无选中时返回 nil
    /// （让 `TranscriptTableLayout.draw` 跳过 selection rendering）。
    private func tableSelectionMatrix(
        segmentIndex idx: Int,
        rowCount: Int,
        colCount: Int
    ) -> [[NSRange]]? {
        guard rowCount > 0, colCount > 0 else { return nil }
        var any = false
        let matrix: [[NSRange]] = (0..<rowCount).map { r in
            (0..<colCount).map { c in
                if let range = selections[TableCellKey(base: idx, row: r, col: c)],
                   range.location != NSNotFound, range.length > 0 {
                    any = true
                    return range
                }
                return NSRange(location: NSNotFound, length: 0)
            }
        }
        return any ? matrix : nil
    }

    // MARK: - Hit geometry helpers

    /// Copy / checkmark 图标的 row-local 矩形。给定 header bar 矩形
    /// 派生——`draw` 和 `hitRegions` 两条路共用，防止几何漂移。
    private func iconRectInRow(forHeaderRect headerRect: CGRect) -> CGRect {
        let iconSide = theme.codeBlockHeaderIconSize
        return CGRect(
            x: headerRect.maxX - theme.codeBlockHeaderIconInsetX - iconSide,
            y: headerRect.minY + (theme.codeBlockHeaderHeight - iconSide) / 2,
            width: iconSide,
            height: iconSide)
    }

    // MARK: - Static CG icons

    /// "doc.on.doc"-style glyph drawn with two stroked rounded rectangles.
    /// Pure CG — avoids shipping a template NSImage or bouncing through
    /// `NSGraphicsContext` just for a 13pt mono icon.
    fileprivate static func drawCopyIcon(
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
    /// decreasing y.
    fileprivate static func drawCheckmarkIcon(
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

    /// Per-corner rounded rect path. Only consumer today is the code block
    /// header strip (rounded top, square bottom where it meets the body).
    fileprivate static func roundedRectPath(
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

    // MARK: - Data model (shared with TranscriptPrepare)

    enum SegmentKind {
        case text, heading, blockquote
        case codeBlock(CodeBlockHeader)
    }

    /// Header bar metadata pre-computed at prebuild time. `draw()` only has
    /// to call `CTLineDraw`. Fences without a language get a `nil` line —
    /// the header still renders, but only the copy affordance on the right.
    struct CodeBlockHeader {
        /// Raw code string copied on header click. Not derived from the
        /// attributed body so tokenizer boundary whitespace can't leak in.
        let code: String
        /// Pre-typeset language label ("swift", "python" …). `nil` when the
        /// fence had no language.
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

    /// `TranscriptPrepare.layoutAssistant` 产出的排版结果——`prebuilt`
    /// 按宽度排版后的宽度相关中间物，直接喂 `draw`。
    enum RenderedSegment {
        case attributed(TranscriptTextLayout, kind: SegmentKind, layoutOrigin: CGPoint)
        case list(TranscriptListLayout, origin: CGPoint)
        case table(TranscriptTableLayout, origin: CGPoint)
        case thematicBreak(y: CGFloat)
    }
}

// MARK: - Selection key schemas (row-private)

/// Composite key for a cell inside an assistant table segment. `base` is
/// the segment index; `(row, col)` identifies the cell. Stable across
/// layout rebuilds since segment index + table shape don't change without
/// a contentHash change.
private struct TableCellKey: Hashable {
    let base: Int
    let row: Int
    let col: Int
}

/// Composite key for a text inside an assistant list segment. `base` is
/// the segment index; `textIdx` is the linear text ordinal within the
/// (possibly nested) list.
private struct ListTextKey: Hashable {
    let base: Int
    let textIdx: Int
}

// MARK: - InteractiveRow

extension AssistantMarkdownRow: InteractiveRow {
    /// Copy 图标的点击区域 —— 每个 code block 一个 region。从
    /// `cachedHeaderRects`（layoutAssistant 产物）派生，避免在 hover
    /// hot path 上重新扫 `cachedRendered`。
    var hitRegions: [RowHitRegion] {
        var regions: [RowHitRegion] = []
        for header in cachedHeaderRects {
            let iconRect = iconRectInRow(forHeaderRect: header.rect)
            let code = header.code
            let tag = header.segmentIndex
            regions.append(RowHitRegion(
                rectInRow: iconRect,
                cursor: .pointingHand,
                perform: { [weak self] controller in
                    guard let self else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    let rowIndex = self.index
                    self.markCodeBlockCopied(segmentIndex: tag) { [weak controller] in
                        controller?.redrawRow(at: rowIndex)
                    }
                    controller.selectionController.clear()
                }))
        }
        return regions
    }
}

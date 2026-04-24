import AgentSDK
import AppKit
import CoreText
import SwiftUI

/// Assistant 消息(Markdown 段)。
///
/// 一个 assistant entry 里相邻的 text block 拼成一段 source,中间夹的 tool_use
/// block 由 `PlaceholderComponent` 接管 —— 各组件按 entryIndex/blockIndex 全局
/// merge-sort 出最终行序。
///
/// State:
/// - `selections: [SelectionKey: NSRange]` — 各 segment / list / table 选中
/// - `copiedSegmentIndex: Int?` — code block copy 反馈期 segment idx
enum AssistantMarkdownComponent: TranscriptComponent {
    static let tag = "Assistant"

    struct Input: Sendable {
        let stableId: StableId
        let source: String
    }

    struct Content: @unchecked Sendable {
        let parsedDocument: MarkdownDocument
        let prebuilt: [PrebuiltSegment]
        /// `true` 表示 prebuilt 已含 syntax highlight tokens —— refinement 不重做。
        let hasHighlight: Bool
        /// 累积的 highlight tokens(per segment idx)。Refinement 增量 merge。
        let codeTokens: [Int: [SyntaxToken]]
    }

    struct Layout: HasHeight, @unchecked Sendable {
        let rendered: [RenderedSegment]
        let codeBlockHeaderRects: [CodeBlockHeaderInfo]
        let cachedHeight: CGFloat
        let cachedWidth: CGFloat
    }

    struct State: Sendable {
        var selections: [SelectionKey: NSRange] = [:]
        var copiedSegmentIndex: Int? = nil

        static let `default` = State()
    }

    typealias SideCar = EmptyRowSideCar

    /// Selection 的 key —— 与老 `[AnyHashable: NSRange]` schema 等价但显式 enum。
    enum SelectionKey: Hashable, Sendable {
        case segment(Int)
        case listText(segment: Int, textIdx: Int)
        case tableCell(segment: Int, row: Int, col: Int)
    }

    // MARK: - Inputs

    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>] {
        guard case .single(let single) = entry,
              case .remote(let message) = single.payload,
              case .assistant(let assistant) = message else { return [] }
        let blocks = assistant.message?.content ?? []

        var out: [IdentifiedInput<Input>] = []
        var textBuffer: [String] = []
        var textStartIndex = 0

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            let source = textBuffer.joined(separator: "\n\n")
            let stableId = StableId(entryId: single.id, locator: .block(textStartIndex))
            out.append(IdentifiedInput(
                stableId: stableId,
                entryIndex: entryIndex,
                blockIndex: textStartIndex,
                input: Input(stableId: stableId, source: source)))
            textBuffer.removeAll()
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .text(let t):
                if let s = t.text, !s.isEmpty {
                    if textBuffer.isEmpty { textStartIndex = idx }
                    textBuffer.append(s)
                }
            case .toolUse:
                flushText()
            case .thinking, .unknown:
                continue
            }
        }
        flushText()
        return out
    }

    // MARK: - Prepare

    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content {
        let doc = MarkdownDocument(parsing: input.source)
        let prebuilt = AssistantMarkdownPrebuilder.build(
            document: doc, theme: theme, codeTokens: [:])
        return Content(
            parsedDocument: doc,
            prebuilt: prebuilt,
            hasHighlight: false,
            codeTokens: [:])
    }

    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int {
        var h = Hasher()
        h.combine(input.source)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    nonisolated static func initialState(for input: Input) -> State {
        .default
    }

    // MARK: - Layout

    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout {
        let contentWidth = max(40, width - 2 * theme.rowHorizontalPadding)
        var segments: [RenderedSegment] = []
        var headerRects: [CodeBlockHeaderInfo] = []
        var y: CGFloat = theme.rowVerticalPadding

        for (idx, prebuiltSeg) in content.prebuilt.enumerated() {
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
                    let barSpace = theme.markdown.blockquoteBarWidth
                        + theme.markdown.blockquoteBarGap
                    maxWidth = max(40, contentWidth - barSpace)
                    layoutOriginX = theme.rowHorizontalPadding + barSpace
                    layoutOriginY = y
                case .codeBlock(let header):
                    maxWidth = max(40, contentWidth - 2 * theme.codeBlockHorizontalPadding)
                    layoutOriginX = theme.rowHorizontalPadding + theme.codeBlockHorizontalPadding
                    layoutOriginY = y + theme.codeBlockHeaderHeight + theme.codeBlockVerticalPadding
                    headerRects.append(CodeBlockHeaderInfo(
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

                switch kind {
                case .codeBlock:
                    y += theme.codeBlockHeaderHeight
                        + layout.totalHeight
                        + 2 * theme.codeBlockVerticalPadding
                default:
                    y += layout.totalHeight
                }

            case .list(let contents, _):
                let listLayout = TranscriptListLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                let origin = CGPoint(x: theme.rowHorizontalPadding, y: y)
                segments.append(.list(listLayout, origin: origin))
                y += listLayout.totalHeight

            case .table(let contents, _):
                let tableLayout = TranscriptTableLayout.make(
                    contents: contents,
                    theme: theme,
                    maxWidth: contentWidth)
                segments.append(.table(
                    tableLayout,
                    origin: CGPoint(x: theme.rowHorizontalPadding, y: y)))
                y += tableLayout.totalHeight

            case .thematicBreak:
                segments.append(.thematicBreak(y: y))
                y += 1
            }
        }
        y += theme.rowVerticalPadding

        return Layout(
            rendered: segments,
            codeBlockHeaderRects: headerRects,
            cachedHeight: y,
            cachedWidth: width)
    }

    // MARK: - Render

    @MainActor
    static func render(
        _ layout: Layout,
        state: State,
        theme: TranscriptTheme,
        in ctx: CGContext,
        bounds: CGRect
    ) {
        guard !layout.rendered.isEmpty else { return }
        let contentWidth = max(40, layout.cachedWidth - 2 * theme.rowHorizontalPadding)

        for (idx, seg) in layout.rendered.enumerated() {
            switch seg {
            case .attributed(let textLayout, let kind, let origin):
                drawAttributed(
                    segmentIndex: idx, layout: textLayout, kind: kind,
                    origin: origin, contentWidth: contentWidth,
                    state: state, theme: theme, in: ctx)

            case .list(let listLayout, let origin):
                let resolver: (Int) -> NSRange? = { textIdx in
                    let key = SelectionKey.listText(segment: idx, textIdx: textIdx)
                    guard let r = state.selections[key],
                          r.location != NSNotFound, r.length > 0 else { return nil }
                    return r
                }
                listLayout.draw(origin: origin, selectionResolver: resolver, in: ctx)

            case .table(let tableLayout, let origin):
                let matrix = tableSelectionMatrix(
                    segmentIndex: idx,
                    rowCount: tableLayout.cells.count,
                    colCount: tableLayout.cells.first?.count ?? 0,
                    state: state)
                tableLayout.draw(origin: origin, selections: matrix, in: ctx)

            case .thematicBreak(let y):
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.separatorColor.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: theme.rowHorizontalPadding, y: y + 0.5))
                ctx.addLine(to: CGPoint(x: layout.cachedWidth - theme.rowHorizontalPadding, y: y + 0.5))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    @MainActor
    private static func drawAttributed(
        segmentIndex idx: Int,
        layout: TranscriptTextLayout,
        kind: SegmentKind,
        origin: CGPoint,
        contentWidth: CGFloat,
        state: State,
        theme: TranscriptTheme,
        in ctx: CGContext
    ) {
        switch kind {
        case .text, .heading:
            let sel = textSelection(for: idx, state: state)
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
                roundedRect: barRect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(barPath)
            ctx.fillPath()
            ctx.restoreGState()

            let sel = textSelection(for: idx, state: state)
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
                x: bodyRect.minX, y: bodyRect.minY,
                width: bodyRect.width, height: theme.codeBlockHeaderHeight)
            let headerPath = roundedRectPath(
                rect: headerRect,
                topLeft: theme.codeBlockCornerRadius,
                topRight: theme.codeBlockCornerRadius,
                bottomLeft: 0, bottomRight: 0)
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

            let iconRect = iconRectInRow(forHeaderRect: headerRect, theme: theme)
            ctx.saveGState()
            if state.copiedSegmentIndex == idx {
                drawCheckmarkIcon(in: ctx, rect: iconRect, tint: theme.codeBlockHeaderForeground)
            } else {
                drawCopyIcon(in: ctx, rect: iconRect, tint: theme.codeBlockHeaderForeground)
            }
            ctx.restoreGState()

            let sel = textSelection(for: idx, state: state)
            layout.draw(origin: origin, selection: sel, in: ctx)
        }
    }

    @MainActor
    private static func textSelection(for segmentIdx: Int, state: State) -> NSRange? {
        guard let r = state.selections[.segment(segmentIdx)],
              r.location != NSNotFound, r.length > 0 else { return nil }
        return r
    }

    @MainActor
    private static func tableSelectionMatrix(
        segmentIndex idx: Int,
        rowCount: Int,
        colCount: Int,
        state: State
    ) -> [[NSRange]]? {
        guard rowCount > 0, colCount > 0 else { return nil }
        var any = false
        let matrix: [[NSRange]] = (0..<rowCount).map { r in
            (0..<colCount).map { c in
                if let range = state.selections[.tableCell(segment: idx, row: r, col: c)],
                   range.location != NSNotFound, range.length > 0 {
                    any = true
                    return range
                }
                return NSRange(location: NSNotFound, length: 0)
            }
        }
        return any ? matrix : nil
    }

    private static func iconRectInRow(
        forHeaderRect headerRect: CGRect,
        theme: TranscriptTheme
    ) -> CGRect {
        let iconSide = theme.codeBlockHeaderIconSize
        return CGRect(
            x: headerRect.maxX - theme.codeBlockHeaderIconInsetX - iconSide,
            y: headerRect.minY + (theme.codeBlockHeaderHeight - iconSide) / 2,
            width: iconSide,
            height: iconSide)
    }

    // MARK: - Interactions

    @MainActor
    static func interactions(
        _ layout: Layout,
        state: State
    ) -> [Interaction<Self>] {
        var out: [Interaction<Self>] = []
        let theme = TranscriptTheme.default
        for header in layout.codeBlockHeaderRects {
            let iconRect = iconRectInRow(forHeaderRect: header.rect, theme: theme)
            let code = header.code
            let segIdx = header.segmentIndex
            out.append(.custom(
                rect: iconRect,
                cursor: .pointingHand,
                handler: { ctx in
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)

                    var s = ctx.currentState()
                    s.copiedSegmentIndex = segIdx
                    ctx.applyState(s)
                    ctx.clearSelection()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        var s2 = ctx.currentState()
                        // 只有还是当前同一个 segment 才回滚 —— 用户期间又点了别的就别覆盖。
                        if s2.copiedSegmentIndex == segIdx {
                            s2.copiedSegmentIndex = nil
                            ctx.applyState(s2)
                        }
                    }
                }))
        }
        return out
    }

    // MARK: - Selectables

    @MainActor
    static func selectables(
        _ layout: Layout,
        state: State
    ) -> [SelectableSlot] {
        var out: [SelectableSlot] = []

        for (idx, seg) in layout.rendered.enumerated() {
            switch seg {
            case .attributed(let textLayout, _, let origin):
                guard !textLayout.lines.isEmpty else { continue }
                out.append(SelectableSlot(
                    ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: 0),
                    mode: .flow,
                    frameInRow: CGRect(
                        x: origin.x, y: origin.y,
                        width: max(textLayout.measuredWidth, 1),
                        height: max(textLayout.totalHeight, 1)),
                    layout: textLayout,
                    selectionKey: AnyHashable(SelectionKey.segment(idx))))

            case .list(let listLayout, let origin):
                for (textIdx, textLayout, originInList) in listLayout.flattenedTexts() {
                    guard !textLayout.lines.isEmpty else { continue }
                    out.append(SelectableSlot(
                        ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: textIdx),
                        mode: .flow,
                        frameInRow: CGRect(
                            x: origin.x + originInList.x,
                            y: origin.y + originInList.y,
                            width: max(textLayout.measuredWidth, 1),
                            height: max(textLayout.totalHeight, 1)),
                        layout: textLayout,
                        selectionKey: AnyHashable(
                            SelectionKey.listText(segment: idx, textIdx: textIdx))))
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
                        out.append(SelectableSlot(
                            ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: sub),
                            mode: .cell,
                            frameInRow: CGRect(
                                x: origin.x + cellFrame.origin.x,
                                y: origin.y + cellFrame.origin.y,
                                width: cellFrame.width,
                                height: cellFrame.height),
                            layout: cellLayout,
                            selectionKey: AnyHashable(
                                SelectionKey.tableCell(segment: idx, row: r, col: c))))
                        sub += 1
                    }
                }

            case .thematicBreak:
                continue
            }
        }
        return out
    }

    @MainActor
    static func applySelection(
        key: AnyHashable,
        range: NSRange,
        to state: State
    ) -> State {
        guard let typedKey = key.base as? SelectionKey else { return state }
        var out = state
        out.selections[typedKey] = range
        return out
    }

    @MainActor
    static func clearingSelection(_ state: State) -> State {
        var out = state
        out.selections.removeAll()
        return out
    }

    @MainActor
    static func selectedFragments(
        _ layout: Layout,
        state: State
    ) -> [CopyFragment] {
        var out: [CopyFragment] = []
        for (idx, seg) in layout.rendered.enumerated() {
            switch seg {
            case .attributed(let textLayout, _, _):
                if let r = state.selections[.segment(idx)],
                   r.location != NSNotFound, r.length > 0 {
                    let sub = textLayout.attributed.attributedSubstring(from: r)
                    out.append(CopyFragment(
                        ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: 0),
                        text: sub.string))
                }
            case .list(let listLayout, _):
                for (textIdx, textLayout, _) in listLayout.flattenedTexts() {
                    let key = SelectionKey.listText(segment: idx, textIdx: textIdx)
                    if let r = state.selections[key],
                       r.location != NSNotFound, r.length > 0 {
                        let sub = textLayout.attributed.attributedSubstring(from: r)
                        out.append(CopyFragment(
                            ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: textIdx),
                            text: sub.string))
                    }
                }
            case .table(let tableLayout, _):
                var sub = 0
                for (r, rowCells) in tableLayout.cells.enumerated() {
                    for (c, cellLayout) in rowCells.enumerated() {
                        let key = SelectionKey.tableCell(segment: idx, row: r, col: c)
                        if let range = state.selections[key],
                           range.location != NSNotFound, range.length > 0 {
                            let s = cellLayout.attributed.attributedSubstring(from: range)
                            out.append(CopyFragment(
                                ordering: SlotOrdering(fragmentOrdinal: idx, subIndex: sub),
                                text: s.string))
                        }
                        sub += 1
                    }
                }
            case .thematicBreak:
                continue
            }
        }
        return out
    }

    // MARK: - Refinements (syntax highlight)

    nonisolated static func refinements(
        _ content: Content,
        context: RefinementContext
    ) -> [Refinement<Self>] {
        guard !content.hasHighlight, let engine = context.syntaxEngine else { return [] }
        var requests: [(seg: Int, code: String, lang: String?)] = []
        for (idx, seg) in content.parsedDocument.segments.enumerated() {
            if case .codeBlock(let block) = seg {
                requests.append((idx, block.code, block.language))
            }
        }
        guard !requests.isEmpty else { return [] }

        let theme = context.theme
        let frozenRequests = requests
        return [Refinement(run: { @Sendable in
            await engine.load()
            // engine 内部对同 tick 调用做 coalescing → 一次 batch JSCore call。
            var tokens: [Int: [SyntaxToken]] = [:]
            await withTaskGroup(of: (Int, [SyntaxToken]).self) { group in
                for req in frozenRequests {
                    group.addTask {
                        let t = await engine.highlight(code: req.code, language: req.lang)
                        return (req.seg, t)
                    }
                }
                for await (idx, t) in group { tokens[idx] = t }
            }
            let snapshot = tokens
            return ContentPatch(apply: { @Sendable old in
                let merged = old.codeTokens.merging(snapshot) { _, new in new }
                let newPrebuilt = AssistantMarkdownPrebuilder.build(
                    document: old.parsedDocument,
                    theme: theme,
                    codeTokens: merged)
                return Content(
                    parsedDocument: old.parsedDocument,
                    prebuilt: newPrebuilt,
                    hasHighlight: true,
                    codeTokens: merged)
            })
        })]
    }

    // MARK: - Highlight requests / token apply (fast batch path)

    /// Builder/pipeline 的 off-main batch highlight 用 —— 收集本 item 全部 code
    /// block 请求(per-segment),pipeline 端做单次 batch JSCore call,然后
    /// 通过 `applyTokens(_:theme:width:)` 把 tokens 折回 Content。
    nonisolated static func highlightRequests(_ item: PreparedItem<Self>) -> [AnyHighlightRequest] {
        guard !item.content.hasHighlight else { return [] }
        var out: [AnyHighlightRequest] = []
        for (idx, seg) in item.content.parsedDocument.segments.enumerated() {
            if case .codeBlock(let block) = seg {
                out.append(AnyHighlightRequest(
                    code: block.code,
                    language: block.language,
                    innerKey: AnyHashable(idx)))
            }
        }
        return out
    }

    nonisolated static func applyTokens(
        _ item: PreparedItem<Self>,
        tokens: [AnyHashable: [SyntaxToken]],
        theme: TranscriptTheme,
        width: CGFloat
    ) -> PreparedItem<Self> {
        var codeTokens: [Int: [SyntaxToken]] = [:]
        for (key, value) in tokens {
            if let i = key.base as? Int { codeTokens[i] = value }
        }
        let merged = item.content.codeTokens.merging(codeTokens) { _, new in new }
        let newPrebuilt = AssistantMarkdownPrebuilder.build(
            document: item.content.parsedDocument,
            theme: theme,
            codeTokens: merged)
        let newContent = Content(
            parsedDocument: item.content.parsedDocument,
            prebuilt: newPrebuilt,
            hasHighlight: true,
            codeTokens: merged)
        let newLayout = layout(newContent, theme: theme, width: width, state: item.state)
        return PreparedItem(
            stableId: item.stableId,
            input: item.input,
            content: newContent,
            contentHash: item.contentHash,
            state: item.state,
            layout: newLayout)
    }

    // MARK: - Data model (used by Layout/Content)

    enum SegmentKind: @unchecked Sendable {
        case text, heading, blockquote
        case codeBlock(CodeBlockHeader)
    }

    struct CodeBlockHeader: @unchecked Sendable {
        /// Raw code copied on header click。
        let code: String
        /// Pre-typeset language label;`nil` 当 fence 无 language。
        let line: CTLine?
        let ascent: CGFloat
        let descent: CGFloat
    }

    enum PrebuiltSegment: @unchecked Sendable {
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

    enum RenderedSegment: @unchecked Sendable {
        case attributed(TranscriptTextLayout, kind: SegmentKind, layoutOrigin: CGPoint)
        case list(TranscriptListLayout, origin: CGPoint)
        case table(TranscriptTableLayout, origin: CGPoint)
        case thematicBreak(y: CGFloat)
    }

    struct CodeBlockHeaderInfo: @unchecked Sendable {
        let rect: CGRect
        let segmentIndex: Int
        let code: String
    }
}

// MARK: - Drawing helpers (file-private, ported from old AssistantMarkdownRow)

@MainActor
private func drawCopyIcon(in ctx: CGContext, rect: CGRect, tint: NSColor) {
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
        roundedRect: back, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.strokePath()

    let front = CGRect(
        x: originX,
        y: originY + offset,
        width: plateSide,
        height: plateSide
    ).insetBy(dx: stroke / 2, dy: stroke / 2)
    ctx.addPath(CGPath(
        roundedRect: front, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.strokePath()

    ctx.restoreGState()
}

@MainActor
private func drawCheckmarkIcon(in ctx: CGContext, rect: CGRect, tint: NSColor) {
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

private func roundedRectPath(
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

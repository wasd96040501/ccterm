import AppKit
import CoreText

/// List 的「宽度无关」预构造物。每个 item 的 marker 和正文独立预构造——marker
/// 是一个单独的 `NSAttributedString`，不混进正文文本流，彻底避免
/// `"\t" + marker + "\t" + content` 这种靠 tab stop 拼行的思路
/// （TextKit 和 CoreText 对 tab stop 坐标系的解释不同，nested 层会出现
/// 可选中的多余 `\t` 宽度——改走独立 layout 绕开）。
///
/// 正文按 block 分类：paragraph/其他 → 一段 `NSAttributedString`；
/// nested list → 递归 `TranscriptListContents`。
struct TranscriptListContents {
    let ordered: Bool
    /// 所有 item 的 marker 最大宽度——同一 list 里所有 marker 共用这一列，
    /// "1." / "99." 这种不等宽 marker 靠右对齐到这个列宽，视觉上点号对齐。
    let markerColumnWidth: CGFloat
    /// Marker 列右边缘到正文起点的水平间距（≈ 半 em）。
    let markerContentGap: CGFloat
    let items: [Item]

    struct Item {
        /// 预构造好的 marker（bullet / "1." / "☑"）。nil 表示空 item（无 marker
        /// 占位，例如 checkbox 未命中或继承列表里的空行）。
        let marker: NSAttributedString?
        /// 缓存 marker 的 typographic width，`make()` 一次算好避免重复测量。
        let markerWidth: CGFloat
        let content: [Content]
    }

    /// Item 正文的单个 block。新增 block 类型时在这里加 case，`make` 和
    /// `TranscriptListLayout.make` 各加一路分派。
    enum Content {
        case text(NSAttributedString)
        case list(TranscriptListContents)
    }

    /// 把 `MarkdownList` 转成 `TranscriptListContents`，递归处理嵌套 list。
    /// 非 paragraph/list 的 block（blockquote / heading / code / table）走
    /// `builder.build(blocks:)` 合成为单段 attributed string——丢弃块级视觉
    /// 特化（例如 blockquote 的左竖条），但保留文本内容。主流 markdown
    /// （GFM）在 list item 里极少出现这类 block，先兜底不做专门渲染。
    @MainActor
    static func make(
        list: MarkdownList,
        theme: MarkdownTheme,
        builder: MarkdownAttributedBuilder
    ) -> TranscriptListContents {
        let metrics = MarkdownListMetrics.make(list: list, theme: theme)
        let markerContentGap = metrics.gap

        var items: [Item] = []
        items.reserveCapacity(list.items.count)
        let maxMarkerW = metrics.markerColumnWidth

        for (idx, listItem) in list.items.enumerated() {
            let marker = metrics.markers[idx]
            let markerW: CGFloat = marker.map { ceil($0.size().width) } ?? 0

            // 把 item.content 按 block 类型分派——paragraph 和 list 单独走，
            // 其他 block 合并在一起让 builder 一次出一段 attributed string
            // （builder.build 已经能吞 paragraph/heading/blockquote 混合）。
            var contents: [Content] = []
            var pendingBlocks: [MarkdownBlock] = []
            func flushPending() {
                guard !pendingBlocks.isEmpty else { return }
                let attr = builder.build(blocks: pendingBlocks)
                contents.append(.text(attr))
                pendingBlocks.removeAll()
            }
            for block in listItem.content {
                switch block {
                case .paragraph:
                    pendingBlocks.append(block)
                    flushPending()
                case .list(let nested):
                    flushPending()
                    let nestedContents = make(
                        list: nested, theme: theme, builder: builder)
                    contents.append(.list(nestedContents))
                case .heading, .blockquote:
                    // 罕见：list item 内的 heading / blockquote。降级成一段
                    // attributed string，保证内容可读。
                    pendingBlocks.append(block)
                }
            }
            flushPending()

            items.append(Item(
                marker: marker,
                markerWidth: markerW,
                content: contents))
        }

        return TranscriptListContents(
            ordered: list.ordered,
            markerColumnWidth: maxMarkerW,
            markerContentGap: markerContentGap,
            items: items)
    }
}

/// 排版后的 list：每 item 的 marker 定位（CTLine + baseline 坐标）和正文
/// 子 layout 已就位。marker 本身作为独立 CTLine 画在固定列宽内，不进任何
/// 可选文本流——这就是 "marker / indent 不可选" 的根因，不依赖后续 copy
/// 过滤。
struct TranscriptListLayout {
    /// 所有 item 以 list 左上角为原点的几何。
    let items: [Item]
    /// Marker 列宽 + gap → 正文起始 x。
    let markerColumnWidth: CGFloat
    let markerContentGap: CGFloat
    var contentOriginX: CGFloat { markerColumnWidth + markerContentGap }
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    struct Item {
        let markerLine: CTLine?
        let markerAscent: CGFloat
        let markerDescent: CGFloat
        /// Marker baseline 在 **list 坐标系**下的位置（左上为原点、y 向下）。
        /// `markerRightX` = marker 右边缘（marker 右对齐到 markerColumnWidth）。
        let markerBaselineY: CGFloat
        let markerRightX: CGFloat
        let markerWidth: CGFloat
        /// Item 占用的垂直区间（list 坐标系）。
        let topY: CGFloat
        let height: CGFloat
        let contents: [Content]
    }

    enum Content {
        case text(TranscriptTextLayout, originInList: CGPoint)
        case list(TranscriptListLayout, originInList: CGPoint)
    }

    // MARK: - Build

    static func make(
        contents: TranscriptListContents,
        theme: TranscriptTheme,
        maxWidth: CGFloat
    ) -> TranscriptListLayout {
        guard !contents.items.isEmpty, maxWidth > 0 else {
            return TranscriptListLayout(
                items: [],
                markerColumnWidth: contents.markerColumnWidth,
                markerContentGap: contents.markerContentGap,
                totalHeight: 0,
                measuredWidth: 0)
        }

        let markerColumnWidth = contents.markerColumnWidth
        let markerContentGap = contents.markerContentGap
        let contentOriginX = markerColumnWidth + markerContentGap
        let contentWidth = max(1, maxWidth - contentOriginX)

        let itemSpacing = theme.markdown.l3Item
        let blockSpacingWithinItem = theme.markdown.l3Item

        var laidItems: [Item] = []
        laidItems.reserveCapacity(contents.items.count)
        var y: CGFloat = 0
        var measuredW: CGFloat = 0

        for (idx, srcItem) in contents.items.enumerated() {
            if idx > 0 { y += itemSpacing }
            let itemTopY = y

            var itemContents: [Content] = []
            var innerY: CGFloat = 0
            var firstTextBaselineInItem: CGFloat?

            for (bi, block) in srcItem.content.enumerated() {
                if bi > 0 { innerY += blockSpacingWithinItem }
                switch block {
                case .text(let attr):
                    let layout = TranscriptTextLayout.make(
                        attributed: attr, maxWidth: contentWidth)
                    let originInList = CGPoint(x: contentOriginX, y: itemTopY + innerY)
                    if firstTextBaselineInItem == nil, let first = layout.lineOrigins.first {
                        // TranscriptTextLayout.lineOrigins[i].y 是 baseline
                        // 相对 layout 原点的偏移（即 top 起算、y 向下）。
                        firstTextBaselineInItem = innerY + first.y
                    }
                    itemContents.append(.text(layout, originInList: originInList))
                    innerY += layout.totalHeight
                    measuredW = max(measuredW, originInList.x + layout.measuredWidth)

                case .list(let nestedContents):
                    let nested = make(
                        contents: nestedContents,
                        theme: theme,
                        maxWidth: contentWidth)
                    let originInList = CGPoint(x: contentOriginX, y: itemTopY + innerY)
                    // 嵌套 list 第一行的 baseline = nested 第一个 item 的
                    // markerBaselineY（正文不存在时也有一个合理的基线）。
                    if firstTextBaselineInItem == nil {
                        if let firstNestedItem = nested.items.first {
                            firstTextBaselineInItem = innerY + firstNestedItem.markerBaselineY
                        }
                    }
                    itemContents.append(.list(nested, originInList: originInList))
                    innerY += nested.totalHeight
                    measuredW = max(measuredW, originInList.x + nested.measuredWidth)
                }
            }

            // Marker baseline 对齐到 item 第一段 content 的首行 baseline。
            // 找不到（完全空 item）就用 marker 自己的 ascent 落在 item 顶。
            let markerLine = srcItem.marker.map { CTLineCreateWithAttributedString($0 as CFAttributedString) }
            var mAscent: CGFloat = 0, mDescent: CGFloat = 0, mLeading: CGFloat = 0
            if let line = markerLine {
                _ = CTLineGetTypographicBounds(line, &mAscent, &mDescent, &mLeading)
            }
            let markerBaseline: CGFloat
            if let base = firstTextBaselineInItem {
                markerBaseline = itemTopY + base
            } else {
                markerBaseline = itemTopY + mAscent
            }

            // marker 右对齐到 markerColumnWidth 列。
            let markerRightX = markerColumnWidth
            laidItems.append(Item(
                markerLine: markerLine,
                markerAscent: mAscent,
                markerDescent: mDescent,
                markerBaselineY: markerBaseline,
                markerRightX: markerRightX,
                markerWidth: srcItem.markerWidth,
                topY: itemTopY,
                height: innerY,
                contents: itemContents))

            y = itemTopY + innerY
        }

        return TranscriptListLayout(
            items: laidItems,
            markerColumnWidth: markerColumnWidth,
            markerContentGap: markerContentGap,
            totalHeight: y,
            measuredWidth: max(measuredW, contentOriginX))
    }

    // MARK: - Draw

    /// 画整个 list 到 `origin`（list 左上角，已加到 row 坐标系）。
    /// `selectionResolver(path:)` 返回某个文本子 layout 当前的选中 range
    /// （未选则 nil）——用 path 编码（itemPath linear index）定位。
    func draw(
        origin: CGPoint,
        selectionResolver: (Int) -> NSRange?,
        in ctx: CGContext
    ) {
        var textIndex = 0
        drawRecursive(
            origin: origin,
            selectionResolver: selectionResolver,
            textIndex: &textIndex,
            in: ctx)
    }

    private func drawRecursive(
        origin: CGPoint,
        selectionResolver: (Int) -> NSRange?,
        textIndex: inout Int,
        in ctx: CGContext
    ) {
        for item in items {
            if let line = item.markerLine {
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                // Marker 右对齐：x = origin.x + markerRightX - markerWidth。
                let mx = origin.x + item.markerRightX - item.markerWidth
                let my = origin.y + item.markerBaselineY
                ctx.textPosition = CGPoint(x: mx, y: my)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            for content in item.contents {
                switch content {
                case .text(let layout, let o):
                    let absOrigin = CGPoint(x: origin.x + o.x, y: origin.y + o.y)
                    let sel = selectionResolver(textIndex)
                    layout.draw(origin: absOrigin, selection: sel, in: ctx)
                    textIndex += 1
                case .list(let nested, let o):
                    let absOrigin = CGPoint(x: origin.x + o.x, y: origin.y + o.y)
                    nested.drawRecursive(
                        origin: absOrigin,
                        selectionResolver: selectionResolver,
                        textIndex: &textIndex,
                        in: ctx)
                }
            }
        }
    }

    // MARK: - Text flattening (for selection)

    /// 把 list 里所有正文 `TranscriptTextLayout` 展开成 (linearIndex, layout,
    /// origin)，origin 是相对本 list 左上角。Selectable region 构造、draw 的
    /// textIndex 顺序都依赖这个 DFS 顺序——两路必须一致。
    func flattenedTexts() -> [(index: Int, layout: TranscriptTextLayout, originInList: CGPoint)] {
        var out: [(Int, TranscriptTextLayout, CGPoint)] = []
        var idx = 0
        collectFlattened(
            accumulatedOrigin: .zero,
            out: &out,
            counter: &idx)
        return out
    }

    private func collectFlattened(
        accumulatedOrigin: CGPoint,
        out: inout [(Int, TranscriptTextLayout, CGPoint)],
        counter: inout Int
    ) {
        for item in items {
            for content in item.contents {
                switch content {
                case .text(let layout, let o):
                    let abs = CGPoint(
                        x: accumulatedOrigin.x + o.x,
                        y: accumulatedOrigin.y + o.y)
                    out.append((counter, layout, abs))
                    counter += 1
                case .list(let nested, let o):
                    let abs = CGPoint(
                        x: accumulatedOrigin.x + o.x,
                        y: accumulatedOrigin.y + o.y)
                    nested.collectFlattened(
                        accumulatedOrigin: abs,
                        out: &out,
                        counter: &counter)
                }
            }
        }
    }
}

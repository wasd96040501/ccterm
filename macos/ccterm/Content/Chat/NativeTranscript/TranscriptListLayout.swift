import AppKit
import CoreText

/// List 的「宽度无关」预构造物。每个 item 的 marker 和正文独立预构造——marker
/// 是一个独立的 ``MarkdownListMarker``（text glyph 或 checkbox），不混进正文
/// 文本流，彻底避免 `"\t" + marker + "\t" + content` 这种靠 tab stop 拼行的
/// 思路（TextKit 和 CoreText 对 tab stop 坐标系的解释不同，nested 层会出现
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
        let marker: MarkdownListMarker?
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

        var items: [Item] = []
        items.reserveCapacity(list.items.count)

        for (idx, listItem) in list.items.enumerated() {
            let marker = metrics.markers[idx]

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

            items.append(Item(marker: marker, content: contents))
        }

        return TranscriptListContents(
            ordered: list.ordered,
            markerColumnWidth: metrics.markerColumnWidth,
            markerContentGap: metrics.gap,
            items: items)
    }
}

/// 预排版后的 marker。按类型分两路绘制——text marker 走 CTLineDraw，checkbox
/// 走 CGPath 自绘。checkbox 自绘是为了绕开 SF Pro 里 `U+2611 ☑` 和 `U+2610 ☐`
/// glyph 设计不对称（checked 方框更粗更大）的问题：同一字体下 ☑/☐ 视觉无法
/// 对齐，只有自绘才能保证两种状态的方框尺寸、stroke 粗细完全一致。
enum RenderedListMarker {
    /// Predrawn text marker (bullet `•` 或 ordered 数字 `1.` / `99.`)。
    case text(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)
    /// 自绘 checkbox。`color` 在 prebuild 阶段就绑定进来——checked 用
    /// primaryColor、unchecked 用 secondaryColor，保留 dynamic NSColor
    /// 以跟随系统外观切换。
    case checkbox(checked: Bool, size: CGFloat, color: NSColor)

    var width: CGFloat {
        switch self {
        case .text(_, let w, _, _): return w
        case .checkbox(_, let s, _): return s
        }
    }

    /// Marker 的几何高度——draw 时把 center 和首行 midY 对齐（midY-to-midY），
    /// 这个高度用来把 center 换算回 top-left 或 baseline 坐标。
    var height: CGFloat {
        switch self {
        case .text(_, _, let a, let d): return a + d
        case .checkbox(_, let s, _): return s
        }
    }
}

/// 排版后的 list：每 item 的 marker 几何中心 + 正文子 layout 已就位。marker
/// 作为独立视觉元素绘制，不进任何可选文本流——这就是 "marker / indent
/// 不可选" 的根因，不依赖后续 copy 过滤。
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
        let marker: RenderedListMarker?
        /// Marker 几何中心在 **list 坐标系**下的 y（左上为原点、y 向下）。
        /// 画 marker 时按 center 落位——对 text 反推 baseline = centerY +
        /// (ascent - descent) / 2；对 checkbox 直接用 centerY - size/2 当 top。
        ///
        /// 选 midY-to-midY 对齐（而不是 baseline-to-baseline）是为了兼顾所有
        /// marker 类型：bullet `•` 几何中心 ≈ midY；数字 `1.` baseline 对齐和
        /// midY 对齐差 descent/2（≈ 2pt，肉眼忽略）；checkbox 方框中心对齐
        /// midY 视觉居中。Telegram 也是这么对齐的。
        let markerCenterY: CGFloat
        /// Marker 右边缘 x（= markerColumnWidth，所有 item 共享）。
        let markerRightX: CGFloat
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

    @MainActor
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
            var firstLineMidYInItem: CGFloat?

            for (bi, block) in srcItem.content.enumerated() {
                if bi > 0 { innerY += blockSpacingWithinItem }
                switch block {
                case .text(let attr):
                    let layout = TranscriptTextLayout.make(
                        attributed: attr, maxWidth: contentWidth)
                    let originInList = CGPoint(x: contentOriginX, y: itemTopY + innerY)
                    if firstLineMidYInItem == nil, let firstRect = layout.lineRects.first {
                        // lineRects[0].midY = 首行几何中心相对 layout 原点（y
                        // 向下）。offset 到 item 坐标：innerY + midY。
                        firstLineMidYInItem = innerY + firstRect.midY
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
                    // 嵌套 list 第一行 midY = nested 第一个 item 的 markerCenterY
                    // （嵌套 marker 已经和嵌套首行 midY 对齐了，直接拿用）。
                    if firstLineMidYInItem == nil, let firstNested = nested.items.first {
                        firstLineMidYInItem = innerY + firstNested.markerCenterY
                    }
                    itemContents.append(.list(nested, originInList: originInList))
                    innerY += nested.totalHeight
                    measuredW = max(measuredW, originInList.x + nested.measuredWidth)
                }
            }

            // 预排版 marker：text 走 CTLine，checkbox 走 CGPath（运行时 draw）。
            let rendered = renderMarker(srcItem.marker, theme: theme.markdown)

            // midY-to-midY：marker 几何中心对齐首行 midY。没有内容时退回 item
            // 顶 + marker 半高。
            let centerY: CGFloat
            if let mid = firstLineMidYInItem {
                centerY = itemTopY + mid
            } else if let r = rendered {
                centerY = itemTopY + r.height / 2
            } else {
                centerY = itemTopY
            }

            laidItems.append(Item(
                marker: rendered,
                markerCenterY: centerY,
                markerRightX: markerColumnWidth,
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

    /// 把 ``MarkdownListMarker`` 预排版成 ``RenderedListMarker``——text 走
    /// CTLine 预排版一次（typographic bounds 缓存住），checkbox 绑定颜色 +
    /// 边长，运行时 CGPath 自绘。
    @MainActor
    private static func renderMarker(
        _ marker: MarkdownListMarker?,
        theme: MarkdownTheme
    ) -> RenderedListMarker? {
        guard let marker else { return nil }
        switch marker {
        case .text(let attr):
            let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &a, &d, &l)
            let w = ceil(attr.size().width)
            return .text(line: line, width: w, ascent: a, descent: d)
        case .checkbox(let checked):
            let size = MarkdownListMetrics.checkboxSize(theme: theme)
            let color: NSColor = checked ? theme.primaryColor : theme.secondaryColor
            return .checkbox(checked: checked, size: size, color: color)
        }
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
            drawMarker(item: item, origin: origin, in: ctx)
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

    private func drawMarker(item: Item, origin: CGPoint, in ctx: CGContext) {
        guard let marker = item.marker else { return }
        let centerY = origin.y + item.markerCenterY
        let rightX = origin.x + item.markerRightX
        switch marker {
        case .text(let line, let w, let a, let d):
            // 几何中心 = (top + bottom) / 2 = baseline + (descent - ascent)/2，
            // 解出 baseline = centerY + (ascent - descent) / 2。
            let baseline = centerY + (a - d) / 2
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: rightX - w, y: baseline)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        case .checkbox(let checked, let size, let color):
            let rect = CGRect(
                x: rightX - size,
                y: centerY - size / 2,
                width: size,
                height: size)
            Self.drawCheckbox(in: rect, checked: checked, color: color, in: ctx)
        }
    }

    /// 自绘 checkbox：统一方框边长、统一 stroke 宽度；checked 额外画对号。
    /// ctx 的坐标系是 flipped（y 向下递增），path 直接按屏幕方向落。
    private static func drawCheckbox(
        in rect: CGRect,
        checked: Bool,
        color: NSColor,
        in ctx: CGContext
    ) {
        ctx.saveGState()

        // 外框：rounded rect stroke。stroke 画在 path 正中，所以要 inset 半
        // stroke 宽度避免边框被画出 rect 外。cornerRadius 按边长的 ~18% 给，
        // 视觉是"soft square"，不是"圆角按钮"。
        let stroke: CGFloat = 1.1
        let corner = rect.width * 0.18
        let box = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.addPath(CGPath(
            roundedRect: box,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil))
        ctx.strokePath()

        // 内部对号：比框的 stroke 稍粗，round line cap/join 让端点看起来
        // "画出来"而不是"切出来"。坐标按 rect 左上起点，y 向下递增。
        if checked {
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

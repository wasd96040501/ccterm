import AppKit

/// Assistant 消息(纯文本部分)。一条 assistant 消息中所有 text block 的 markdown
/// 源码拼接后,解析为 `MarkdownDocument`,逐 segment 构造 Core Text layout。
///
/// 绘制时按 segment 顺序累加 y 偏移,段间间距遵从 `MarkdownTheme.l1/l2`。
final class AssistantMarkdownRowItem: TranscriptRowItem {
    let source: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    private var rendered: [RenderedSegment] = []

    init(source: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.source = source
        self.theme = theme
        self.stable = stable
        super.init()
    }

    override var stableId: AnyHashable { stable }

    // MARK: - Segment model

    /// 已计算 layout 的单个 segment。`topPadding` 是此 segment 顶部与前一 segment
    /// 底部之间的垂直间隙。`contentHeight` 不含 topPadding。
    enum RenderedSegment {
        case text(TranscriptTextLayout, topPadding: CGFloat)
        case blockquote(TranscriptTextLayout, topPadding: CGFloat)
        case codeBlock(TranscriptTextLayout, topPadding: CGFloat)
        case table(TranscriptTableLayout, topPadding: CGFloat)
        case thematicBreak(topPadding: CGFloat)

        var topPadding: CGFloat {
            switch self {
            case .text(_, let p), .blockquote(_, let p),
                 .codeBlock(_, let p), .thematicBreak(let p):
                return p
            case .table(_, let p):
                return p
            }
        }

        var contentHeight: CGFloat {
            switch self {
            case .text(let l, _), .blockquote(let l, _), .codeBlock(let l, _):
                return l.totalHeight
            case .table(let t, _):
                return t.totalHeight
            case .thematicBreak:
                return 1
            }
        }
    }

    // MARK: - Layout

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width

        let document = MarkdownDocument(parsing: source)
        let builder = MarkdownAttributedBuilder(theme: theme.markdown)
        let contentWidth = max(40, width - 2 * theme.rowHorizontalPadding)

        var segments: [RenderedSegment] = []

        for (idx, seg) in document.segments.enumerated() {
            let gap = gapBefore(idx: idx, segment: seg)

            switch seg {
            case .markdown(let blocks):
                let attr = builder.build(blocks: blocks)
                let layout = TranscriptTextRenderer.makeLayout(
                    attributed: attr, maxWidth: contentWidth)
                segments.append(.text(layout, topPadding: gap))

            case .heading(let level, let inlines):
                let attr = builder.buildHeading(level: level, inlines: inlines)
                let layout = TranscriptTextRenderer.makeLayout(
                    attributed: attr, maxWidth: contentWidth)
                segments.append(.text(layout, topPadding: gap))

            case .blockquote(let blocks):
                let attr = builder.buildBlockquote(blocks: blocks)
                let barSpace = theme.markdown.blockquoteBarWidth + theme.markdown.blockquoteBarGap
                let innerWidth = max(40, contentWidth - barSpace)
                let layout = TranscriptTextRenderer.makeLayout(
                    attributed: attr, maxWidth: innerWidth)
                segments.append(.blockquote(layout, topPadding: gap))

            case .codeBlock(let block):
                let font = NSFont.monospacedSystemFont(
                    ofSize: theme.markdown.codeFontSize, weight: .regular)
                let attr = NSAttributedString(
                    string: block.code,
                    attributes: [
                        .font: font,
                        .foregroundColor: theme.markdown.primaryColor,
                    ])
                let pad = theme.codeBlockHorizontalPadding
                let innerWidth = max(40, contentWidth - 2 * pad)
                let layout = TranscriptTextRenderer.makeLayout(
                    attributed: attr, maxWidth: innerWidth)
                segments.append(.codeBlock(layout, topPadding: gap))

            case .table(let table):
                let tableLayout = TranscriptTableLayout.make(
                    table: table,
                    builder: builder,
                    theme: theme,
                    maxWidth: contentWidth)
                segments.append(.table(tableLayout, topPadding: gap))

            case .mathBlock(let raw):
                let attr = monospacedFallback(raw)
                let layout = TranscriptTextRenderer.makeLayout(
                    attributed: attr, maxWidth: contentWidth)
                segments.append(.text(layout, topPadding: gap))

            case .thematicBreak:
                segments.append(.thematicBreak(topPadding: gap))
            }
        }

        // 总高度 = 每个 segment 的 topPadding + contentHeight + 上/下 rowVerticalPadding
        // codeBlock 的 contentHeight 已经含 layout.height,外加块 vPad 要加一次。
        var total: CGFloat = 0
        for seg in segments {
            total += seg.topPadding
            switch seg {
            case .codeBlock(let l, _):
                total += l.totalHeight + 2 * theme.codeBlockVerticalPadding
            default:
                total += seg.contentHeight
            }
        }

        rendered = segments
        cachedHeight = total + 2 * theme.rowVerticalPadding
    }

    private func gapBefore(idx: Int, segment: MarkdownSegment) -> CGFloat {
        if idx == 0 { return 0 }
        if case .heading = segment { return theme.markdown.l1 }
        return theme.markdown.l2
    }

    private func monospacedFallback(_ s: String) -> NSAttributedString {
        NSAttributedString(
            string: s,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: theme.markdown.codeFontSize, weight: .regular),
                .foregroundColor: theme.markdown.primaryColor,
            ])
    }

    // MARK: - Draw

    override func draw(in ctx: CGContext, bounds: CGRect) {
        var y: CGFloat = theme.rowVerticalPadding
        for seg in rendered {
            y += seg.topPadding
            switch seg {
            case .text(let layout, _):
                TranscriptTextRenderer.draw(
                    layout,
                    origin: CGPoint(x: theme.rowHorizontalPadding, y: y),
                    in: ctx)
                y += layout.totalHeight

            case .blockquote(let layout, _):
                drawBlockquote(layout: layout, y: y, in: ctx)
                y += layout.totalHeight

            case .codeBlock(let layout, _):
                let h = layout.totalHeight + 2 * theme.codeBlockVerticalPadding
                drawCodeBlock(layout: layout, y: y, height: h, bounds: bounds, in: ctx)
                y += h

            case .table(let tableLayout, _):
                tableLayout.draw(
                    origin: CGPoint(x: theme.rowHorizontalPadding, y: y),
                    in: ctx)
                y += tableLayout.totalHeight

            case .thematicBreak:
                drawThematicBreak(y: y, width: bounds.width, in: ctx)
                y += 1
            }
        }
    }

    private func drawBlockquote(layout: TranscriptTextLayout, y: CGFloat, in ctx: CGContext) {
        let barX = theme.rowHorizontalPadding
        let barW = theme.markdown.blockquoteBarWidth
        let barRect = CGRect(x: barX, y: y, width: barW, height: layout.totalHeight)
        ctx.saveGState()
        ctx.setFillColor(theme.markdown.blockquoteBarColor.cgColor)
        let path = CGPath(
            roundedRect: barRect,
            cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        let textX = theme.rowHorizontalPadding
            + theme.markdown.blockquoteBarWidth
            + theme.markdown.blockquoteBarGap
        TranscriptTextRenderer.draw(
            layout,
            origin: CGPoint(x: textX, y: y),
            in: ctx)
    }

    private func drawCodeBlock(
        layout: TranscriptTextLayout,
        y: CGFloat,
        height: CGFloat,
        bounds: CGRect,
        in ctx: CGContext
    ) {
        let rect = CGRect(
            x: theme.rowHorizontalPadding,
            y: y,
            width: bounds.width - 2 * theme.rowHorizontalPadding,
            height: height)
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

        let textOrigin = CGPoint(
            x: rect.minX + theme.codeBlockHorizontalPadding,
            y: rect.minY + theme.codeBlockVerticalPadding)
        TranscriptTextRenderer.draw(layout, origin: textOrigin, in: ctx)
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
}

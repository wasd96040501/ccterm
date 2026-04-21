import AppKit

/// User 消息右对齐气泡。
///
/// 布局：
/// - maxBubbleWidth = frame.width - bubbleMinLeftGutter - bubbleRightInset
/// - 实际 bubbleWidth = min(maxBubbleWidth, textMeasuredWidth + 2 * hPad)
/// - bubbleX = frame.width - bubbleRightInset - bubbleWidth
///
/// 短文本 hug 内容，长文本 wrap 到 maxBubbleWidth。
final class UserBubbleRow: TranscriptRow {
    let text: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    private var textLayout: TranscriptTextLayout = .empty
    private var bubbleRect: CGRect = .zero

    init(text: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.text = text
        self.theme = theme
        self.stable = stable
        super.init()
    }

    override var stableId: AnyHashable { stable }

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width

        let maxBubbleWidth = max(120, width - theme.bubbleMinLeftGutter - theme.bubbleRightInset)
        let contentMaxWidth = max(40, maxBubbleWidth - 2 * theme.bubbleHorizontalPadding)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.markdown.bodyFont,
            .foregroundColor: theme.markdown.primaryColor,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        textLayout = TranscriptTextLayout.make(
            attributed: attr,
            maxWidth: contentMaxWidth)

        let bubbleWidth = min(
            maxBubbleWidth,
            textLayout.measuredWidth + 2 * theme.bubbleHorizontalPadding)
        let bubbleHeight = textLayout.totalHeight + 2 * theme.bubbleVerticalPadding
        let bubbleX = width - theme.bubbleRightInset - bubbleWidth
        let bubbleY = theme.rowVerticalPadding
        bubbleRect = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)

        cachedHeight = bubbleHeight + 2 * theme.rowVerticalPadding
    }

    override func draw(in ctx: CGContext, bounds: CGRect) {
        guard !textLayout.lines.isEmpty else { return }
        let path = CGPath(
            roundedRect: bubbleRect,
            cornerWidth: theme.bubbleCornerRadius,
            cornerHeight: theme.bubbleCornerRadius,
            transform: nil)
        ctx.saveGState()
        ctx.setFillColor(theme.bubbleFillColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        let textOrigin = CGPoint(
            x: bubbleRect.minX + theme.bubbleHorizontalPadding,
            y: bubbleRect.minY + theme.bubbleVerticalPadding)
        textLayout.draw(origin: textOrigin, in: ctx)
    }
}

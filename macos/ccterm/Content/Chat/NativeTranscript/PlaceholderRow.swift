import AppKit
import CoreText

/// 工具调用 / thinking / group 的占位 row。
/// 灰色虚线边框 + label 文本，固定高度约 36pt。
final class PlaceholderRow: TranscriptRow {
    let label: String
    let theme: TranscriptTheme
    private let stable: AnyHashable

    private var labelLine: CTLine?
    private var labelAscent: CGFloat = 0
    private var labelDescent: CGFloat = 0

    init(label: String, theme: TranscriptTheme, stable: AnyHashable) {
        self.label = label
        self.theme = theme
        self.stable = stable
        super.init()
    }

    override var stableId: AnyHashable { stable }

    override var contentHash: Int {
        var h = Hasher()
        h.combine(label)
        h.combine(theme.markdown.fingerprint)
        return h.finalize()
    }

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width

        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.placeholderTextFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        labelLine = line
        labelAscent = ascent
        labelDescent = descent

        cachedHeight = theme.placeholderHeight + 2 * theme.rowVerticalPadding
    }

    override func draw(in ctx: CGContext, bounds: CGRect) {
        let rect = CGRect(
            x: theme.placeholderHorizontalInset,
            y: theme.rowVerticalPadding + theme.placeholderVerticalInset,
            width: bounds.width - 2 * theme.placeholderHorizontalInset,
            height: theme.placeholderHeight - 2 * theme.placeholderVerticalInset)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: theme.placeholderLineDashPattern)
        ctx.setLineWidth(1)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: theme.placeholderCornerRadius,
            cornerHeight: theme.placeholderCornerRadius,
            transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        guard let labelLine else { return }
        let baselineY = rect.midY + (labelAscent - labelDescent) / 2
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: rect.minX + 12, y: baselineY)
        CTLineDraw(labelLine, ctx)
        ctx.restoreGState()
    }
}

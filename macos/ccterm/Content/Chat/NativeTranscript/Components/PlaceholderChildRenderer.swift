import AgentSDK
import AppKit
import CoreText

/// 兜底 child renderer —— 未富化 tool kind 在 group 展开态画一条虚线占位框。
/// 形态参照 standalone `PlaceholderComponent`(同高、同 dash pattern、同圆角),
/// 视觉上让"非富化"和独立 tool 行保持一致。
enum PlaceholderChildRenderer: GroupChildRenderer {

    struct Content: @unchecked Sendable {
        let label: String
        let labelLine: CTLine
        let labelAscent: CGFloat
        let labelDescent: CGFloat
    }

    struct Frame: Sendable {
        let rect: CGRect
    }

    nonisolated static func parse(_ tool: ToolUse, theme: TranscriptTheme) -> Content {
        let label = "[Tool: \(tool.caseName)]"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: theme.placeholderTextFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Content(
            label: label,
            labelLine: line,
            labelAscent: ascent,
            labelDescent: descent)
    }

    nonisolated static func contentHash(_ tool: ToolUse, theme: TranscriptTheme) -> Int {
        var h = Hasher()
        h.combine("placeholder")
        h.combine(tool.caseName)
        return h.finalize()
    }

    nonisolated static func layout(
        _ content: Content,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        theme: TranscriptTheme
    ) -> Frame {
        Frame(rect: CGRect(x: x, y: y, width: width, height: theme.groupChildPlaceholderHeight))
    }

    nonisolated static func height(_ frame: Frame) -> CGFloat {
        frame.rect.height
    }

    @MainActor
    static func draw(
        _ content: Content,
        frame: Frame,
        theme: TranscriptTheme,
        in ctx: CGContext
    ) {
        let outer = frame.rect
        // Inset 取 placeholderVerticalInset(顶/底)— 跟独立 placeholder 视觉对齐。
        let r = outer.insetBy(dx: 0, dy: theme.placeholderVerticalInset)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: theme.placeholderLineDashPattern)
        let path = CGPath(
            roundedRect: r,
            cornerWidth: theme.placeholderCornerRadius,
            cornerHeight: theme.placeholderCornerRadius,
            transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        let baselineY = r.midY + (content.labelAscent - content.labelDescent) / 2
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: r.minX + 12, y: baselineY)
        CTLineDraw(content.labelLine, ctx)
        ctx.restoreGState()
    }
}

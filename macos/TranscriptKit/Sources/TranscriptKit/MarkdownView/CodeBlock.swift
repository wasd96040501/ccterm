import AppKit
import CoreText

/// A fenced or indented code block: verbatim monospaced source on a rounded
/// card, with the language named in a chip at the top-right.
///
/// A `TextBlock`, so its whole selection surface is the inherited one — the card
/// and the chip are decoration, and `textOrigin` is what tells the default
/// implementations where the selectable part actually starts.
///
/// **The chrome is an overlay.** The badge reserves no vertical space, so a long
/// first line passes underneath it rather than being pushed down or wrapped
/// early. Its opaque chip is what keeps it legible when that happens — which is
/// why the chip is filled rather than drawn as text alone.
///
/// No copy button yet. It belongs here, next to the badge, and lands when the
/// package grows a way to hit-test and click a region — the same layer the
/// selection drag and the link activation need.
struct CodeBlock: TextBlock {

    let run: TextRun
    let textOrigin: CGPoint
    let size: CGSize

    private let cornerRadius: CGFloat
    private let backgroundColor: NSColor

    private let badge: Badge?

    /// The language chip: a filled rounded rect with one pre-typeset line on it.
    private struct Badge {
        let line: CTLine
        /// Baseline origin, in block-local coordinates.
        let textOrigin: CGPoint
        let rect: CGRect
        let cornerRadius: CGFloat
        let backgroundColor: NSColor
    }

    static func make(
        code: String, language: String?, width: CGFloat, style: MarkdownStyle
    ) -> CodeBlock {
        let textWidth = max(1, width - style.codeHorizontalPadding * 2)
        let run = TextRun.make(
            NSAttributedString(
                string: code,
                attributes: [.font: style.codeFont, .foregroundColor: style.textColor]),
            width: textWidth)

        let height = style.codeVerticalPadding * 2 + run.size.height

        return CodeBlock(
            run: run,
            textOrigin: CGPoint(x: style.codeHorizontalPadding, y: style.codeVerticalPadding),
            size: CGSize(width: width, height: height),
            cornerRadius: style.codeCornerRadius,
            backgroundColor: style.codeBackgroundColor,
            badge: badge(language: language, width: width, style: style))
    }

    private static func badge(
        language: String?, width: CGFloat, style: MarkdownStyle
    ) -> Badge? {
        let name = language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !name.isEmpty else { return nil }

        let attributed = NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: style.codeBadgeFontSize, weight: .regular),
                .foregroundColor: style.secondaryColor,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let chipWidth = textWidth + style.codeBadgeHorizontalPadding * 2
        let chipHeight = (ascent + descent).rounded(.up) + 4
        let rect = CGRect(
            x: width - style.codeChromeInset - chipWidth,
            y: style.codeChromeInset,
            width: chipWidth,
            height: chipHeight)
        // Nowhere to put it without crowding the body's own left padding.
        guard rect.minX >= style.codeHorizontalPadding else { return nil }

        return Badge(
            line: line,
            // Centred in the chip: in a y-down layout the glyph box's top is
            // `midY - (ascent + descent) / 2` and the baseline is `top +
            // ascent`, which reduces to `midY + (ascent - descent) / 2`.
            textOrigin: CGPoint(
                x: rect.minX + style.codeBadgeHorizontalPadding,
                y: rect.midY + (ascent - descent) / 2),
            rect: rect,
            cornerRadius: style.codeBadgeCornerRadius,
            backgroundColor: style.codeBadgeBackgroundColor)
    }

    // MARK: - Draw

    func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: CGRect(origin: origin, size: size),
                cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Body first: the badge overlays the top-right corner, so a long first
        // line has to pass under the chip rather than over it.
        run.draw(
            at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y),
            in: ctx, dirty: dirty)

        guard let badge else { return }
        ctx.saveGState()
        ctx.setFillColor(badge.backgroundColor.cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: badge.rect.offsetBy(dx: origin.x, dy: origin.y),
                cornerWidth: badge.cornerRadius, cornerHeight: badge.cornerRadius,
                transform: nil))
        ctx.fillPath()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: origin.x + badge.textOrigin.x, y: origin.y + badge.textOrigin.y)
        CTLineDraw(badge.line, ctx)
        ctx.restoreGState()
    }
}

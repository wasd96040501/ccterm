import AppKit
import CoreText

/// Verbatim monospaced source on a rounded card, with the language named in a
/// chip at the top-right.
///
/// Everything a code block looks like is in this file — the fill, the radius, the
/// padding inside the card, the padding outside it, the chip. None of it is
/// stated anywhere else, and none of it is announced to whatever is stacking it.
///
/// **The chrome is an overlay.** The badge reserves no vertical space, so a long
/// first line passes underneath it rather than being pushed down or wrapped
/// early. Its opaque chip is what keeps it legible when that happens, which is
/// why the chip is filled rather than drawn as text alone.
///
/// No copy button yet. It belongs here, next to the badge, and lands when the
/// package grows a way to hit-test and click a region — the same layer selection
/// dragging and link activation need.
struct CodeBlock: Layout {

    let code: String
    let language: String?

    /// Monospaced at the body point size, so a card sandwiched between paragraphs
    /// reads as a sibling rather than a tonal shift. The caller supplies the size
    /// because it is the surrounding text's, not the card's.
    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var textColor: NSColor = .labelColor

    /// `#F5F5F7` light / `#2A2A2E` dark — one elevation tier above the window
    /// background in either mode, so the card reads as a raised surface.
    var backgroundColor: NSColor = dynamic(dark: 0x2A2A2E, light: 0xF5F5F7)

    /// The "structural" corner tier — data, code, grids. A tight curve reads as
    /// engineering; the soft tier belongs to chat bubbles.
    var cornerRadius: CGFloat = 6
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 12

    /// Room outside the card, on top of the container's own spacing. A hard edge
    /// crowds its neighbours more than a text edge does, so it buys back two
    /// points on each side — and does it inside its own measured height, without
    /// telling anyone.
    var outerPadding: CGFloat = 2

    var badgeInset: CGFloat = 8
    var badgeFontSize: CGFloat = 11
    var badgeCornerRadius: CGFloat = 4
    var badgeHorizontalPadding: CGFloat = 6
    var badgeBackgroundColor: NSColor = dynamic(dark: 0x3E3E43, light: 0xE1E1E3)
    var badgeTextColor: NSColor = .secondaryLabelColor

    init(code: String, language: String?) {
        self.code = code
        self.language = language
    }

    func measure(_ width: CGFloat) -> MarkdownBlock {
        let run = MarkdownTextRun.make(
            NSAttributedString(
                string: code, attributes: [.font: font, .foregroundColor: textColor]),
            width: max(1, width - horizontalPadding * 2))

        let card = CGRect(
            x: 0, y: outerPadding,
            width: width, height: verticalPadding * 2 + run.size.height)

        return Measured(
            run: run,
            textOrigin: CGPoint(x: horizontalPadding, y: card.minY + verticalPadding),
            size: CGSize(width: width, height: card.height + outerPadding * 2),
            card: card,
            cornerRadius: cornerRadius,
            backgroundColor: backgroundColor,
            badge: badge(width: width, cardTop: card.minY))
    }

    private func badge(width: CGFloat, cardTop: CGFloat) -> Measured.Badge? {
        let name = language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !name.isEmpty else { return nil }

        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: badgeFontSize, weight: .regular),
                    .foregroundColor: badgeTextColor,
                ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let chipWidth = textWidth + badgeHorizontalPadding * 2
        let rect = CGRect(
            x: width - badgeInset - chipWidth,
            y: cardTop + badgeInset,
            width: chipWidth,
            height: (ascent + descent).rounded(.up) + 4)
        // Nowhere to put it without crowding the body's own left padding.
        guard rect.minX >= horizontalPadding else { return nil }

        return Measured.Badge(
            line: line,
            // Centred in the chip: in a y-down layout the glyph box's top is
            // `midY - (ascent + descent) / 2` and the baseline is `top + ascent`,
            // which reduces to `midY + (ascent - descent) / 2`.
            textOrigin: CGPoint(
                x: rect.minX + badgeHorizontalPadding, y: rect.midY + (ascent - descent) / 2),
            rect: rect,
            cornerRadius: badgeCornerRadius,
            backgroundColor: badgeBackgroundColor)
    }

    private static func dynamic(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
    }

    /// A `MarkdownTextBlock`, so its whole selection surface is the inherited one — the
    /// card and the chip are decoration, and `textOrigin` is what tells the
    /// default implementations where the selectable part starts.
    struct Measured: MarkdownTextBlock, @unchecked Sendable {

        /// The language chip: a filled rounded rect with one pre-typeset line.
        struct Badge {
            let line: CTLine
            /// Baseline origin, in block-local coordinates.
            let textOrigin: CGPoint
            let rect: CGRect
            let cornerRadius: CGFloat
            let backgroundColor: NSColor
        }

        let run: MarkdownTextRun
        let textOrigin: CGPoint
        let size: CGSize
        let card: CGRect
        let cornerRadius: CGFloat
        let backgroundColor: NSColor
        let badge: Badge?

        func draw(at origin: CGPoint, in ctx: CGContext, dirty: CGRect) {
            ctx.saveGState()
            ctx.setFillColor(backgroundColor.cgColor)
            ctx.addPath(
                CGPath(
                    roundedRect: card.offsetBy(dx: origin.x, dy: origin.y),
                    cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()

            // Body first: the badge overlays the top-right corner, so a long
            // first line passes under the chip rather than over it.
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
}

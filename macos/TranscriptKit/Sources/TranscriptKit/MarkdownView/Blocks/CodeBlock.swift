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
struct CodeBlock: Block {

    /// The card's body. Monospaced at the body point size — the caller resolves
    /// that, because the size is the surrounding text's and not the card's.
    let text: ShapedText

    /// The language chip's text, already typeset: one word that never wraps, so
    /// nothing about it depends on the width the card ends up at. Only where it
    /// sits does, and that is all `measure` computes.
    let badge: TypesetText?

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
    var badgeCornerRadius: CGFloat = 4
    var badgeHorizontalPadding: CGFloat = 6
    var badgeBackgroundColor: NSColor = dynamic(dark: 0x3E3E43, light: 0xE1E1E3)

    /// The point size the chip's text is set at. Not a property of the card —
    /// whoever typesets `badge` decides it — but stated here so the one caller
    /// and the geometry around the chip read from the same number.
    static let badgeFontSize: CGFloat = 11

    init(text: ShapedText, badge: TypesetText? = nil) {
        self.text = text
        self.badge = badge
    }

    func measure(_ width: CGFloat) -> MeasuredBlock {
        let run = text.typeset(width: max(1, width - horizontalPadding * 2))

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
            badge: placedBadge(width: width, cardTop: card.minY))
    }

    /// Where the chip goes. The run itself arrived typeset — all that is left is
    /// arithmetic against a width, which is why this is the only part of the chip
    /// still on the `measure` path.
    private func placedBadge(width: CGFloat, cardTop: CGFloat) -> Measured.Badge? {
        guard let run = badge, let line = run.lines.first else { return nil }
        let ascent = line.ascent
        let descent = line.descent
        let textWidth = run.size.width

        let chipWidth = textWidth + badgeHorizontalPadding * 2
        let rect = CGRect(
            x: width - badgeInset - chipWidth,
            y: cardTop + badgeInset,
            width: chipWidth,
            height: (ascent + descent).rounded(.up) + 4)
        // Nowhere to put it without crowding the body's own left padding.
        guard rect.minX >= horizontalPadding else { return nil }

        return Measured.Badge(
            run: run,
            // Centred in the chip: in a y-down layout the glyph box's top is
            // `midY - (ascent + descent) / 2`. (A run is placed by its top-left;
            // the baseline it derives from that is `top + ascent`, which is the
            // `midY + (ascent - descent) / 2` this used to state directly.)
            textOrigin: CGPoint(
                x: rect.minX + badgeHorizontalPadding, y: rect.midY - (ascent + descent) / 2),
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

    /// A `MeasuredTextBlock`, so its whole selection surface is the inherited one — the
    /// card and the chip are decoration, and `textOrigin` is what tells the
    /// default implementations where the selectable part starts.
    struct Measured: MeasuredTextBlock, @unchecked Sendable {

        /// The language chip: a filled rounded rect with one pre-typeset run.
        struct Badge {
            let run: TypesetText
            /// Top-left of the run, in block-local coordinates.
            let textOrigin: CGPoint
            let rect: CGRect
            let cornerRadius: CGFloat
            let backgroundColor: NSColor
        }

        let run: TypesetText
        let textOrigin: CGPoint
        let size: CGSize
        let card: CGRect
        let cornerRadius: CGFloat
        let backgroundColor: NSColor
        let badge: Badge?

        /// The card is `.background`, the code is `.content`, the chip is
        /// `.overlay` — which is what makes the chip sit over a long first line
        /// while a selection band sits under the glyphs and over the card, with
        /// none of the three knowing about the others.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .fill(
                    roundedRect: card.offsetBy(dx: origin.x, dy: origin.y),
                    radius: cornerRadius, backgroundColor))

            list.append(
                .text(run, at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y)))

            guard let badge else { return }
            list.append(
                .fill(
                    roundedRect: badge.rect.offsetBy(dx: origin.x, dy: origin.y),
                    radius: badge.cornerRadius, badge.backgroundColor, phase: .overlay))
            list.append(
                .text(
                    badge.run,
                    at: CGPoint(x: origin.x + badge.textOrigin.x, y: origin.y + badge.textOrigin.y),
                    phase: .overlay))
        }
    }
}

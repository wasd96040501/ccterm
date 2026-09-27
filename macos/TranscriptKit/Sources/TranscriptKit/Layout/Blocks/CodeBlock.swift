import AppKit
import CoreText

/// Verbatim monospaced source on a rounded card, with the language named in a
/// chip at the top-right.
///
/// Everything a code block looks like is in this file — the fill, the radius, the
/// padding inside the card, the padding outside it, the chip. None of it is
/// stated anywhere else, and none of it is announced to whatever is stacking it.
///
/// **The chip costs no row, and covers no code.** It sits in the card's
/// top-trailing corner and reserves no vertical space; a first line long enough
/// to reach it wraps short of it instead of running underneath —
/// `ShapedText.typeset(width:limit:excluding:)`, which is TextKit's exclusion
/// path. Only a line that would actually meet the chip is affected: a short first
/// line keeps its width and the card keeps its height, and a long one costs the
/// wrap it would have cost anyway a few characters earlier. A header row naming
/// the language would buy the same legibility with a line of height on every
/// card, most of which have nothing near the corner.
///
/// No copy button yet. It belongs here, next to the badge, and the layer it was
/// waiting on now exists: `MeasuredBlock.link(at:)` is a point query answered by
/// the block that owns the geometry, and `BlockView` already turns a press into
/// a click on one. A button is that shape with a closure where the `URL` is.
struct CodeBlock: Block, @unchecked Sendable {

    /// The card's body. Monospaced at the body point size — the caller resolves
    /// that, because the size is the surrounding text's and not the card's.
    let text: ShapedText

    /// The language chip's text, already typeset: one word that never wraps, so
    /// nothing about it depends on the width the card ends up at. Only where it
    /// sits does, and that is all `measure` computes.
    let badge: TypesetText?

    /// `tertiarySystemFill` — a translucent tier, darker than the page in light
    /// mode and lighter in dark, **whatever the page is.**
    ///
    /// Relative on purpose. The transcript draws no background of its own, so
    /// the card sits on the window's material or on whatever a host put behind
    /// it, and the colour of that is not known here. An opaque card was: it
    /// was `#F5F5F7`, chosen to sit a tier above a window background of about
    /// `#ECECEC` — and the window it met was `#F1F2F2`, which left four levels
    /// between them and a card that read as a smudge. A fill is composited over
    /// whatever it lands on, so its contrast is the same on every page.
    var backgroundColor: NSColor = tertiaryFill

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
    /// The same fill again, over the card's: one tier further from the page than
    /// the card is, in either mode, for the reason `backgroundColor` gives.
    var badgeBackgroundColor: NSColor = tertiaryFill

    /// The point size the chip's text is set at. Not a property of the card —
    /// whoever typesets `badge` decides it — but stated here so the one caller
    /// and the geometry around the chip read from the same number.
    static let badgeFontSize: CGFloat = 11

    init(text: ShapedText, badge: TypesetText? = nil) {
        self.text = text
        self.badge = badge
    }

    func measure(_ width: CGFloat) -> MeasuredBlock {
        let textWidth = max(1, width - horizontalPadding * 2)
        let cardTop = outerPadding
        let textOrigin = CGPoint(x: horizontalPadding, y: cardTop + verticalPadding)

        // The chip is placed first because the text depends on it and it depends
        // on nothing but the width: it is the corner the first line wraps short
        // of, carried into the text's own coordinates with a gap on its leading
        // side.
        let badge = placedBadge(width: width, cardTop: cardTop, textWidth: textWidth)
        let text = text.typeset(
            width: textWidth,
            excluding: badge.map {
                CGRect(
                    x: $0.rect.minX - badgeInset - textOrigin.x, y: $0.rect.minY - textOrigin.y,
                    width: $0.rect.width + badgeInset, height: $0.rect.height)
            })

        let card = CGRect(
            x: 0, y: cardTop,
            width: width, height: verticalPadding * 2 + text.size.height)

        return Measured(
            text: text,
            textOrigin: textOrigin,
            size: CGSize(width: width, height: card.height + outerPadding * 2),
            card: card,
            cornerRadius: cornerRadius,
            backgroundColor: backgroundColor,
            badge: badge)
    }

    /// Where the chip goes. The chip's text arrived typeset — all that is left
    /// is arithmetic against a width, which is why this is the only part of the
    /// chip still on the `measure` path.
    ///
    /// Left out when it would take more than half the line beside it: the first
    /// line wraps short of the chip, and on a card that narrow the chip would be
    /// deciding the code's layout rather than labelling it.
    private func placedBadge(
        width: CGFloat, cardTop: CGFloat, textWidth: CGFloat
    )
        -> Measured.Badge?
    {
        guard let badge, let line = badge.lines.first else { return nil }
        let ascent = line.ascent
        let descent = line.descent
        let textWidth = badge.size.width

        let chipWidth = textWidth + badgeHorizontalPadding * 2
        let rect = CGRect(
            x: width - badgeInset - chipWidth,
            y: cardTop + badgeInset,
            width: chipWidth,
            height: (ascent + descent).rounded(.up) + 4)
        guard rect.minX - badgeInset - horizontalPadding >= textWidth / 2 else { return nil }

        return Measured.Badge(
            text: badge,
            // Centred in the chip: in a y-down layout the glyph box's top is
            // `midY - (ascent + descent) / 2`. (Text is placed by its top-left;
            // the baseline it derives from that is `top + ascent`, which is the
            // `midY + (ascent - descent) / 2` this used to state directly.)
            textOrigin: CGPoint(
                x: rect.minX + badgeHorizontalPadding, y: rect.midY - (ascent + descent) / 2),
            rect: rect,
            cornerRadius: badgeCornerRadius,
            backgroundColor: badgeBackgroundColor)
    }

    /// `NSColor.tertiarySystemFill`, which arrived in macOS 14 — this package
    /// reaches back to 12, where the same fill is spelled out: black over a
    /// light page, white over a dark one, at the alpha the system uses.
    private static var tertiaryFill: NSColor {
        if #available(macOS 14.0, *) { return .tertiarySystemFill }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.047) : NSColor(white: 0, alpha: 0.047)
        }
    }

    /// A `MeasuredTextBlock`, so its whole selection surface is the inherited one — the
    /// card and the chip are decoration, and `textOrigin` is what tells the
    /// default implementations where the selectable part starts.
    struct Measured: MeasuredTextBlock, @unchecked Sendable {

        /// The language chip: a filled rounded rect with one pre-typeset text.
        struct Badge {
            let text: TypesetText
            /// Top-left of the text, in block-local coordinates.
            let textOrigin: CGPoint
            let rect: CGRect
            let cornerRadius: CGFloat
            let backgroundColor: NSColor
        }

        let text: TypesetText
        let textOrigin: CGPoint
        let size: CGSize
        let card: CGRect
        let cornerRadius: CGFloat
        let backgroundColor: NSColor
        let badge: Badge?

        /// The card is `.background`, the code is `.content`, the chip is
        /// `.overlay` — so a selection band sits under the glyphs and over the
        /// card, with none of the three knowing about the others. No code runs
        /// under the chip any more (`measure` wraps it short), but a selection
        /// band can reach past the end of a wrapped first line, and the chip
        /// stays above that.
        func paint(at origin: CGPoint, dirty: CGRect, into list: inout [PaintItem]) {
            list.append(
                .fill(
                    roundedRect: card.offsetBy(dx: origin.x, dy: origin.y),
                    radius: cornerRadius, backgroundColor))

            list.append(
                .text(text, at: CGPoint(x: origin.x + textOrigin.x, y: origin.y + textOrigin.y)))

            guard let badge else { return }
            list.append(
                .fill(
                    roundedRect: badge.rect.offsetBy(dx: origin.x, dy: origin.y),
                    radius: badge.cornerRadius, badge.backgroundColor, phase: .overlay))
            list.append(
                .text(
                    badge.text,
                    at: CGPoint(x: origin.x + badge.textOrigin.x, y: origin.y + badge.textOrigin.y),
                    phase: .overlay))
        }
    }
}

import AppKit

extension NSAttributedString.Key {
    /// Custom attribute carrying the fill color for an inline code span.
    /// Read by ``MarkdownLayoutManager`` to draw a padded, rounded chip behind
    /// the run — `NSAttributedString.Key.backgroundColor` only supports tight
    /// rectangles, hence this dedicated marker.
    static let inlineCodeBackground = NSAttributedString.Key("MarkdownInlineCodeBackground")
}

/// `NSLayoutManager` subclass that draws inline-code chips with horizontal
/// padding and rounded corners. Chips are recognised via the
/// ``NSAttributedString/Key/inlineCodeBackground`` attribute on text storage.
///
/// Padding/corner values are configured per-instance so the host view can pull
/// them from the theme.
final class MarkdownLayoutManager: NSLayoutManager {
    var inlineCodeHorizontalPadding: CGFloat = 4
    var inlineCodeVerticalPadding: CGFloat = 1
    var inlineCodeCornerRadius: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage,
              let container = textContainers.first,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let charRange = characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: nil)

        textStorage.enumerateAttribute(
            .inlineCodeBackground,
            in: charRange,
            options: []
        ) { value, attrRange, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = self.glyphRange(
                forCharacterRange: attrRange,
                actualCharacterRange: nil)

            let hPad = self.inlineCodeHorizontalPadding
            let vPad = self.inlineCodeVerticalPadding
            let radius = self.inlineCodeCornerRadius

            // enumerateEnclosingRects yields one rect per line fragment, so a
            // wrapped inline code span draws as separate chips on each line —
            // matches what GitHub / Notion do.
            self.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let chip = NSRect(
                    x: rect.minX + origin.x - hPad,
                    y: rect.minY + origin.y - vPad,
                    width: rect.width + 2 * hPad,
                    height: rect.height + 2 * vPad)
                context.saveGState()
                color.setFill()
                NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius).fill()
                context.restoreGState()
            }
        }
    }
}

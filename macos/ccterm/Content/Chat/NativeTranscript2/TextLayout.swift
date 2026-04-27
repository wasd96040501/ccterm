import AppKit
import CoreText

/// Immutable Core Text layout — pure function of (attributed string, max width).
///
/// Coordinate system: y grows downward (matches NSTableView's flipped row coords).
/// `lineOrigins[i].y` is the baseline distance from the top of the layout.
struct TextLayout {
    let lines: [CTLine]
    let lineOrigins: [CGPoint]
    let totalHeight: CGFloat
    let measuredWidth: CGFloat

    static let empty = TextLayout(
        lines: [], lineOrigins: [], totalHeight: 0, measuredWidth: 0)

    static func make(attributed: NSAttributedString, maxWidth: CGFloat) -> TextLayout {
        guard attributed.length > 0, maxWidth > 0 else { return .empty }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var origins: [CGPoint] = []
        var y: CGFloat = 0
        var start: CFIndex = 0

        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(
                typesetter, CFRange(location: start, length: count))

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

            y += ascent
            origins.append(CGPoint(x: 0, y: y))
            y += descent + leading
            lines.append(line)
            start += count
        }

        return TextLayout(
            lines: lines, lineOrigins: origins,
            totalHeight: y, measuredWidth: maxWidth)
    }

    /// Draw into a flipped NSView. `origin` is layout's top-left in view coords.
    func draw(in ctx: CGContext, origin: CGPoint) {
        ctx.saveGState()
        // Flip text matrix so Core Text glyphs render upright in a flipped view.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (line, lineOrigin) in zip(lines, lineOrigins) {
            ctx.textPosition = CGPoint(
                x: origin.x + lineOrigin.x,
                y: origin.y + lineOrigin.y)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

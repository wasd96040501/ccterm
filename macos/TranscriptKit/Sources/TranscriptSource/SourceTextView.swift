import AppKit

/// The text of a ``SourceView``: a read-only `NSTextView` that also paints each
/// line's comparison tint and the word-level highlights under the glyphs.
///
/// TextKit 1, not 2: the gutter asks where each line's first fragment is, for
/// visible lines only, and `NSLayoutManager` answers that by glyph range with
/// non-contiguous layout — a file of any length lays out only what is looked at.
@MainActor
final class SourceTextView: NSTextView {
    /// The document's lines, and the UTF-16 offset each starts at in the
    /// text storage (lines are joined by one `\n`).
    private(set) var lines: [SourceLine] = []
    private(set) var lineStarts: [Int] = []
    /// The face most of the text is set in, for placing the gutter's numbers.
    var plainFont = SourceTheme.font(dark: false)

    func setLines(_ lines: [SourceLine]) {
        self.lines = lines
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.text.utf16.count + 1
        }
        lineStarts = starts
    }

    // MARK: - Geometry

    /// The line holding UTF-16 offset `character`.
    func lineIndex(forCharacter character: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// The lines with any part inside `rect` (this view's coordinates).
    func lineIndexes(in rect: NSRect) -> Range<Int> {
        guard let layoutManager, let textContainer, !lines.isEmpty else { return 0..<0 }
        let origin = textContainerOrigin
        let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(forCharacter: characters.location)
        let last = lineIndex(forCharacter: max(characters.location, NSMaxRange(characters) - 1))
        // An empty last line has no glyph of its own; reaching the end of the
        // text reaches it.
        let end = NSMaxRange(characters) >= (textStorage?.length ?? 0) ? lines.count : last + 1
        return first..<min(end, lines.count)
    }

    /// Line `index`'s full height — every fragment it wraps to — spanning the
    /// view's width, in this view's coordinates.
    func rect(ofLine index: Int) -> NSRect {
        guard let layoutManager, let textContainer, lines.indices.contains(index) else { return .zero }
        let origin = textContainerOrigin
        let length = lines[index].text.utf16.count
        let characters = NSRange(location: lineStarts[index], length: index < lines.count - 1 ? length + 1 : length)
        var fragment: NSRect
        if characters.length == 0 {
            fragment = layoutManager.extraLineFragmentRect
            if fragment.isEmpty {
                let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                fragment = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            }
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layoutManager.lineFragmentRect(
                forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
            fragment = first.union(last)
        }
        return NSRect(x: 0, y: fragment.minY + origin.y, width: bounds.width, height: fragment.height)
    }

    /// Where line `index`'s first baseline is, in this view's coordinates:
    /// the bottom of its first fragment, less the plain face's descent. Read
    /// from the fragment rather than a glyph's location, which an empty line
    /// (a lone newline glyph) reports lower than a line with text.
    func baseline(ofLine index: Int, descent: CGFloat) -> CGFloat? {
        guard let layoutManager, lines.indices.contains(index) else { return nil }
        let origin = textContainerOrigin
        let fragment: NSRect
        if lines[index].text.isEmpty, index == lines.count - 1 {
            fragment = layoutManager.extraLineFragmentRect
            if fragment.isEmpty { return nil }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[index])
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        return fragment.maxY - descent + origin.y
    }

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let visible = lineIndexes(in: rect)
        for index in visible {
            let line = lines[index]
            guard let tint = SourceView.tint(for: line.change) else { continue }
            tint.setFill()
            self.rect(ofLine: index).fill()
        }
        SourceTheme.addedWordBackground.setFill()
        let origin = textContainerOrigin
        for index in visible where !lines[index].changedRanges.isEmpty {
            let lineRect = self.rect(ofLine: index)
            for range in lines[index].changedRanges {
                let characters = NSRange(location: lineStarts[index] + range.lowerBound, length: range.count)
                let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { enclosing, _ in
                    // Full line height, as Xcode draws it, not the glyphs' box.
                    let fragment = layoutManager.lineFragmentRect(
                        forGlyphAt: layoutManager.glyphIndex(
                            for: NSPoint(x: enclosing.midX, y: enclosing.midY), in: textContainer),
                        effectiveRange: nil)
                    let box = NSRect(
                        x: enclosing.minX + origin.x, y: fragment.minY + origin.y, width: enclosing.width,
                        height: fragment.height
                    ).intersection(lineRect)
                    box.fill()
                }
            }
        }
    }
}

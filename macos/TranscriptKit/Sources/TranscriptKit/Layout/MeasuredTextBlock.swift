import AppKit

/// A block whose selectable content is one `TypesetText` — "I am a stack of typeset
/// lines, possibly with some decoration around them."
///
/// Paragraphs, headings, code blocks and table cells all are. Conforming costs
/// two declarations, and hands back all four selection members.
///
/// `textOrigin` is the only thing that varies between them: decoration pushes
/// the text somewhere other than the block's own top-left — a code block's
/// padding, a heading's leading space. The default implementations translate
/// between the two spaces so that no conforming block offsets a rectangle by
/// hand. That translation was previously written once per composite in the
/// renderer this replaces (`BlockquoteLayout.links` re-projecting hit rects,
/// `ListLayout.Content` carrying an `originInList` per case); one place is the
/// point.
protocol MeasuredTextBlock: MeasuredBlock {

    /// The typeset content.
    var text: TypesetText { get }

    /// Where the text's top-left sits inside this block. Defaults to the block's
    /// own top-left, which is right for anything undecorated.
    var textOrigin: CGPoint { get }
}

extension MeasuredTextBlock {

    var textOrigin: CGPoint { .zero }

    var length: Int { text.length }

    func index(at point: CGPoint) -> Int {
        text.index(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
    }

    func rects(from: Int, to: Int) -> [CGRect] {
        text.rects(from: from, to: to)
            .map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
    }

    /// `self.` because the property and this method share a base name — legal,
    /// since a method's full name includes its labels, but worth spelling out
    /// rather than leaving a reader to wonder whether it recurses.
    func text(from: Int, to: Int) -> String {
        self.text.text(from: from, to: to)
    }

    func characterIndex(at point: CGPoint) -> Int? {
        text.characterIndex(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
    }

    /// No offset: `textOrigin` is geometry, and this side is index space.
    func link(at index: Int) -> InlineLink? { text.link(at: index) }

    /// Both of these are geometry on the way in, so both take the offset — the
    /// mirror of `index(at:)` above, where the index-taking versions they
    /// replace needed none.
    func wordRange(at point: CGPoint) -> Range<Int> {
        text.wordRange(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
    }

    func paragraphRange(at point: CGPoint) -> Range<Int> {
        text.paragraphRange(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
    }
}

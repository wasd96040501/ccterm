import AppKit

/// A block whose selectable content is one `MarkdownTextRun` — "I am a stack of typeset
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
protocol MarkdownTextBlock: MarkdownBlock {

    /// The typeset content.
    var run: MarkdownTextRun { get }

    /// Where the run's top-left sits inside this block. Defaults to the block's
    /// own top-left, which is right for anything undecorated.
    var textOrigin: CGPoint { get }
}

extension MarkdownTextBlock {

    var textOrigin: CGPoint { .zero }

    var length: Int { run.length }

    func index(at point: CGPoint) -> Int {
        run.index(at: CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y))
    }

    func rects(from: Int, to: Int) -> [CGRect] {
        run.rects(from: from, to: to)
            .map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
    }

    func text(from: Int, to: Int) -> String {
        run.text(from: from, to: to)
    }

    func wordRange(at index: Int) -> Range<Int> {
        guard run.length > 0 else { return index..<index }
        let word = run.attributed.doubleClick(at: min(max(0, index), run.length - 1))
        return word.lowerBound..<word.upperBound
    }

    func paragraphRange(at index: Int) -> Range<Int> {
        guard run.length > 0 else { return index..<index }
        let paragraph = (run.attributed.string as NSString).paragraphRange(
            for: NSRange(location: min(max(0, index), run.length - 1), length: 0))
        return paragraph.lowerBound..<paragraph.upperBound
    }
}

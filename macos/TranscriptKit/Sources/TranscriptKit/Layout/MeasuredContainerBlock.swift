import AppKit

/// A block that wraps one content block and shifts it by a fixed offset — a
/// quote's indent, a list item's marker column. Every text query is the
/// content's, translated by `contentOrigin`; the container writes only `paint`.
///
/// The content's index space is the whole of the container's (one child, base
/// zero), so the index-space queries forward unchanged and only the geometry
/// ones translate.
protocol MeasuredContainerBlock: MeasuredBlock {
    var content: MeasuredBlock { get }
    var contentOrigin: CGPoint { get }
}

extension MeasuredContainerBlock {

    var length: Int { content.length }

    func characterIndexForInsertion(at point: CGPoint) -> Int {
        content.characterIndexForInsertion(at: local(point))
    }

    func rects(from: Int, to: Int) -> [CGRect] {
        content.rects(from: from, to: to).map {
            $0.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
        }
    }

    func text(from: Int, to: Int) -> String { content.text(from: from, to: to) }

    func characterIndex(at point: CGPoint) -> Int? {
        content.characterIndex(at: local(point))
    }

    func link(at index: Int) -> InlineLink? { content.link(at: index) }

    func ranges(of query: String) -> [Range<Int>] { content.ranges(of: query) }

    func wordRange(at point: CGPoint) -> Range<Int> {
        content.wordRange(at: local(point))
    }

    func paragraphRange(at point: CGPoint) -> Range<Int> {
        content.paragraphRange(at: local(point))
    }

    /// `point` in the content's coordinates.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - contentOrigin.x, y: point.y - contentOrigin.y)
    }
}

import AppKit

/// What `FindSession` needs of the transcript: which row is where and the width
/// it is laid out at, the host's answers for its own rows, the report a find
/// makes, and scrolling a hit into view — the view's geometry, not the find's.
@MainActor
protocol FindSessionOwner: AnyObject {

    var contentWidth: CGFloat { get }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow?

    /// A `.view` row's matches, as its host answers them; none without a delegate.
    func findMatches(of query: String, inRow row: Int) -> [Range<Int>]

    /// The find's state now — the host's
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)`.
    func findDidUpdate(matches: Int, isComplete: Bool)

    /// Brings the characters `range` of row `row` on screen.
    func scrollFindMatchToVisible(_ range: Range<Int>, inRow row: Int)
}

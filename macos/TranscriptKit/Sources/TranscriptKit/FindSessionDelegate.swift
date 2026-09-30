import AppKit

/// What a find says back to the transcript: its state, and scrolling a hit into
/// view — the view's geometry, not the find's.
@MainActor
protocol FindSessionDelegate: AnyObject {

    /// The find's state now — the host's
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)`.
    func findSession(_ findSession: FindSession, didUpdateMatches matches: Int, isComplete: Bool)

    /// Brings the characters `range` of row `row` on screen.
    func findSession(
        _ findSession: FindSession, didRequestScrollRangeToVisible range: Range<Int>, inRow row: Int)
}

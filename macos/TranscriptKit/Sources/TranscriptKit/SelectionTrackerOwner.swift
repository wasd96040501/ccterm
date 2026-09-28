import AppKit

/// What `SelectionTracker` needs of the transcript: which row is where, and the
/// width rows are laid out at — the two things a point is turned into a position
/// with.
@MainActor
protocol SelectionTrackerOwner: AnyObject {

    var contentWidth: CGFloat { get }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow?
}

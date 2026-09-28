import AppKit

/// What `RemeasureScheduler` needs of the transcript: the width it measures for,
/// which row is where, and a way to publish heights that holds the viewport still.
@MainActor
protocol RemeasureSchedulerOwner: AnyObject {

    /// The content width rows are measured against now; a batch measured for
    /// another is dropped.
    var contentWidth: CGFloat { get }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow?

    /// Tells the table these rows' heights changed, holding the viewport still.
    func noteHeightOfRows(withIndexesChanged indexes: IndexSet)
}

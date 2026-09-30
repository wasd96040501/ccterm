import AppKit

/// What `RemeasureScheduler` needs of the transcript: the width it measures for,
/// and which row is where.
@MainActor
protocol RemeasureSchedulerOwner: AnyObject {

    /// The content width rows are measured against now; a batch measured for
    /// another is dropped.
    var contentWidth: CGFloat { get }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow?
}

import AppKit

/// What the transcript's collaborators (`SelectionTracker`, `RemeasureScheduler`,
/// `FindSession`) read of it: which row is where, the width rows are laid out at,
/// and a row's measured tree — the data half of every collaborator's needs.
@MainActor
protocol RowDataSource: AnyObject {

    var numberOfRows: Int { get }

    /// The content width rows are measured against now.
    var contentWidth: CGFloat { get }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow?

    /// The measured tree for `row` at the current width, or `nil` for a row
    /// that has none (a `.view` row).
    func measuredBlock(for row: TranscriptRow) -> MeasuredBlock?
}

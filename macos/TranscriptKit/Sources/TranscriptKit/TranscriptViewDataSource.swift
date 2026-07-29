import Foundation

/// Supplies a `TranscriptView` with its rows, mirroring `NSTableViewDataSource`.
///
/// The conforming object is the single source of truth for row count and
/// content. After mutating the backing data, announce the change to the view
/// through `insertRows(at:withAnimation:)` / `removeRows(at:withAnimation:)` /
/// `reloadRows(at:)` (or `reloadData()`) — the view never observes the data
/// source on its own.
///
/// Data only. How a row *looks* — how tall it is, and what view stands behind
/// a `.view` row — belongs to `TranscriptViewDelegate`, the same split
/// `NSTableView` draws between its data source and its delegate.
@MainActor
public protocol TranscriptViewDataSource: AnyObject {

    /// The current number of rows in the transcript.
    func numberOfRows(in transcriptView: TranscriptView) -> Int

    /// Which kind of content the given row holds.
    ///
    /// Called on demand, possibly repeatedly and in any order, for rows far
    /// outside the viewport as readily as visible ones — the implementation
    /// must be side-effect free and cheap. In particular it must not build or
    /// recycle views; that is
    /// `TranscriptViewDelegate.transcriptView(_:viewForRow:)`'s job.
    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent
}

import Foundation

/// Supplies a `TranscriptView` with its rows, mirroring `NSTableViewDataSource`.
///
/// The conforming object is the single source of truth for row count and
/// content. After mutating the backing data, announce the change to the view
/// through `insertRows(at:withAnimation:)` / `removeRows(at:withAnimation:)` /
/// `reloadRows(at:)` (or `reloadData()`) — the view never observes the data
/// source on its own.
@MainActor
public protocol TranscriptViewDataSource: AnyObject {

    /// The current number of rows in the transcript.
    func numberOfRows(in transcriptView: TranscriptView) -> Int

    /// The content of the given row.
    ///
    /// Called on demand, possibly repeatedly and in any order while the view
    /// lays out or scrolls — the implementation must be side-effect free.
    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent
}

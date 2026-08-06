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

    /// Which row sits at `row`, and what it holds.
    ///
    /// Called on demand, possibly repeatedly and in any order, for rows far
    /// outside the viewport as readily as visible ones — the implementation
    /// must be side-effect free and cheap. In particular it must not build or
    /// recycle views; that is
    /// `TranscriptViewDelegate.transcriptView(_:viewForRow:)`'s job.
    ///
    /// Answering both halves at once is deliberate, and `TranscriptRow` says
    /// why. What this side owes is that `id` names the same row for as long as
    /// that row exists — the measurement cache is keyed on it, and an identity
    /// that moves costs the reuse rather than the correctness.
    ///
    /// **No default implementation**, though there is an obvious one: `row`
    /// itself. It would compile everywhere and be wrong everywhere a transcript
    /// mutates, since every insert renumbers every row below it and hands every
    /// cached measurement to the wrong document. A requirement a host must
    /// answer costs one line at the one place it is written; a default that is
    /// silently wrong costs an afternoon.
    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow
}

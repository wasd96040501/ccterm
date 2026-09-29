import AppKit

/// What a row of the transcript reports: intent only, by id. The row never
/// knows what opening, toggling or deciding does — its tab's controller does.
@MainActor
protocol PageRowViewDelegate: AnyObject {
    /// Open what `id` names beside the transcript (`TranscriptPage.document(for:)`):
    /// a click shows it in the other editor's temporary tab, a double-click
    /// (`pinned`) in a tab that stays.
    func rowView(_ rowView: NSView, open id: String, pinned: Bool)

    /// Expand or collapse run (or news row) `runID`; `all` — ⌥-click — does
    /// the same to every run in the transcript.
    func rowView(_ rowView: NSView, toggle runID: String, all: Bool)

    /// *Show N more*: list every item of run `runID`.
    func rowView(_ rowView: NSView, showAllOf runID: String)

    /// ↖ on a piece of news: bring the call that started the task into view.
    func rowView(_ rowView: NSView, revealOrigin callID: String)

    /// The reader answered call `callID` — a permission, a plan, a question.
    func rowView(_ rowView: NSView, decide decision: Decision, for callID: String)
}

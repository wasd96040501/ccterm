import AppKit

/// What a row of the transcript reports: intent only, by id. The row never
/// knows what opening, toggling or deciding does — its tab's controller does.
@MainActor
protocol PageRowViewDelegate: AnyObject {
    /// Open what `id` names beside the transcript (`TranscriptPage.document(for:)`):
    /// a click shows it in the other editor's temporary tab, a double-click
    /// (`pinned`) in a tab that stays.
    func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool)

    /// Expand or collapse run (or news row) `runID`; `all` — ⌥-click — does
    /// the same to every run in the transcript.
    func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool)

    /// *Show N more*: list every item of run `runID`.
    func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String)

    /// ↖ on a piece of news: bring the call that started the task into view.
    func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String)

    /// The reader answered call `callID` — a permission, a plan, a question.
    func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String)

    /// *Withdraw* under a queued prompt: take it back.
    func pageRowView(_ rowView: NSView, didRequestWithdrawOfPrompt uuid: String)

    /// *Resend* under a prompt that was not sent.
    func pageRowView(_ rowView: NSView, didRequestResendOfPrompt uuid: String)
}

extension PageRowViewDelegate {
    func pageRowView(_ rowView: NSView, didRequestWithdrawOfPrompt uuid: String) {}
    func pageRowView(_ rowView: NSView, didRequestResendOfPrompt uuid: String) {}
}

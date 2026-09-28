import AppKit

/// What `TranscriptTableView` reports: that it placed its rows, and the
/// responder events a selection and the keyboard need — each forwarded by the
/// transcript to whichever collaborator owns it.
@MainActor
protocol TranscriptTableViewOwner: AnyObject {

    /// `tile()` ran: row geometry and the document's height may have moved.
    func tableViewDidTile(_ tableView: TranscriptTableView)

    /// `layout()` ran: row views have taken the geometry `tile()` worked out.
    func tableViewDidLayout(_ tableView: TranscriptTableView)

    /// A press the table received, to be tracked to its release.
    func tableView(_ tableView: TranscriptTableView, trackSelectionFrom event: NSEvent)

    func tableViewDidResignFirstResponder(_ tableView: TranscriptTableView)

    /// A standard key binding's command; `false` hands the key on up the chain.
    func tableView(_ tableView: TranscriptTableView, performScrollCommand selector: Selector) -> Bool

    func tableViewCopySelection(_ tableView: TranscriptTableView)

    func tableViewCanCopySelection(_ tableView: TranscriptTableView) -> Bool
}

import AppKit

@MainActor
protocol DocumentViewControllerDelegate: AnyObject {
    /// *Show in Transcript*: bring what the document was opened from back
    /// into view in its transcript, and flash it.
    func documentViewController(_ document: DocumentViewController, showInTranscript reference: DocumentReference)
}

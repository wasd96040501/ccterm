import AppKit

/// What a `TranscriptViewController` tells the session tab around it — what
/// the composer needs from the transcript. A subagent's conversation has no
/// such tab and no delegate.
@MainActor
protocol TranscriptViewControllerDelegate: AnyObject {
    /// Whether a request waiting for the reader (an approval, a question, a
    /// plan's decision) is in view — the composer says *Waiting for you ↑*
    /// when it isn't.
    func transcriptViewController(
        _ transcriptViewController: TranscriptViewController, didChangeWaitingRequestVisibility isVisible: Bool)
    /// A question was answered with *Chat About This*: the focus goes to the
    /// composer.
    func transcriptViewControllerDidRequestComposer(_ transcriptViewController: TranscriptViewController)
}

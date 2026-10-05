import AppKit

/// What a `TranscriptViewController` tells the session tab around it. A
/// subagent's conversation has no such tab and no delegate.
@MainActor
protocol TranscriptViewControllerDelegate: AnyObject {
    /// Whether a request waiting for the reader (an approval, a question, a
    /// plan's decision) is in view.
    func transcriptViewController(
        _ transcriptViewController: TranscriptViewController, didChangeWaitingRequestVisibility isVisible: Bool)
    /// A question was answered with *Chat About This*: the reader answers in
    /// the conversation.
    func transcriptViewControllerDidChooseToChat(_ transcriptViewController: TranscriptViewController)
}

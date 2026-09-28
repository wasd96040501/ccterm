import Foundation

/// What a transcript tab asks of the window around it.
@MainActor
protocol TranscriptViewControllerDelegate: AnyObject {
    /// The reader asked to see `document` — what a tool call did, what a
    /// command printed. `pinned` asks for a tab that stays; otherwise it
    /// takes the temporary one.
    func transcriptViewController(
        _ controller: TranscriptViewController, open document: ToolDocument, pinned: Bool)
}

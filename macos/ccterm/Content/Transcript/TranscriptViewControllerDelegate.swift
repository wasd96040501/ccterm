import AppKit

@MainActor
protocol TranscriptViewControllerDelegate: AnyObject {
    /// The reader clicked `document` open to see beside the transcript; a
    /// double-click wants it `pinned`. The focus goes with it.
    func transcriptViewController(_ transcript: TranscriptViewController, open document: Document, pinned: Bool)
}

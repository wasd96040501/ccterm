import AppKit

@MainActor
protocol TranscriptViewControllerDelegate: AnyObject {
    /// The reader opened `document` — a click, or a step with ↑ / ↓ — to see
    /// beside the transcript; a double-click wants it `pinned`.
    func transcriptViewController(_ transcript: TranscriptViewController, open document: Document, pinned: Bool)
}

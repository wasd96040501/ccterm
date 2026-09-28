import AppKit

/// What a transcript card reports: intent only. The card is recycled across
/// rows, so it names itself and the host finds which row it is serving now.
@MainActor
protocol TranscriptCardDelegate: AnyObject {
    /// The reader opened or closed a tool group's list.
    func cardDidToggle(_ card: NSView)
    /// The reader asked to see `document` — `pinned` for a tab that stays
    /// (double-click, Open in New Tab), otherwise the temporary one.
    func card(_ card: NSView, open document: ToolDocument, pinned: Bool)
}

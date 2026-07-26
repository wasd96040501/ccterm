import AppKit

/// Reuse identifiers for the transcript table — one per row-view class,
/// so `makeView(withIdentifier:owner:)` recycles a paragraph view only
/// into another paragraph row.
///
/// Centralized constants referenced at both the dequeue and the
/// assign-on-create site, per the list conventions: a typo becomes a
/// compile error instead of a silently blank row.
extension NSUserInterfaceItemIdentifier {
    static let transcriptParagraphRow = NSUserInterfaceItemIdentifier(
        "TranscriptParagraphRow")
    static let transcriptHeadingRow = NSUserInterfaceItemIdentifier("TranscriptHeadingRow")
    static let transcriptCodeBlockRow = NSUserInterfaceItemIdentifier(
        "TranscriptCodeBlockRow")
    static let transcriptListRow = NSUserInterfaceItemIdentifier("TranscriptListRow")
    static let transcriptTableRow = NSUserInterfaceItemIdentifier("TranscriptTableRow")
    static let transcriptBlockquoteRow = NSUserInterfaceItemIdentifier(
        "TranscriptBlockquoteRow")
    static let transcriptThematicBreakRow = NSUserInterfaceItemIdentifier(
        "TranscriptThematicBreakRow")
    static let transcriptImageRow = NSUserInterfaceItemIdentifier("TranscriptImageRow")
    static let transcriptUserBubbleRow = NSUserInterfaceItemIdentifier(
        "TranscriptUserBubbleRow")
    static let transcriptUserAttachmentsRow = NSUserInterfaceItemIdentifier(
        "TranscriptUserAttachmentsRow")
    static let transcriptGroupHeaderRow = NSUserInterfaceItemIdentifier(
        "TranscriptGroupHeaderRow")
    /// The `NSTableRowView` wrapper, which is kind-agnostic.
    static let transcriptRowWrapper = NSUserInterfaceItemIdentifier("TranscriptRowWrapper")
}

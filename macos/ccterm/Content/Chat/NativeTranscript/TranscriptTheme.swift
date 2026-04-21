import AppKit

/// Transcript-local visual tokens that build on top of `MarkdownTheme`.
///
/// `MarkdownTheme` already owns typography (fonts, sizes) and the generic
/// block-level paddings. `TranscriptTheme` adds the chat-specific layout
/// constants that the NativeTranscript renderer needs: row gutters, user
/// bubble geometry, etc.
struct TranscriptTheme {
    let markdown: MarkdownTheme

    // MARK: - Row layout

    /// Horizontal inset between the row content and the table view edges.
    var rowHorizontalPadding: CGFloat = 20
    /// Vertical space reserved above/below content inside each row. Two
    /// adjacent rows' v-paddings sum to the visible gap between them.
    var rowVerticalPadding: CGFloat = 8

    // MARK: - User bubble

    /// Minimum distance from the bubble's LEFT edge to the frame's left edge
    /// when the text content is long enough to wrap.
    var bubbleMinLeftGutter: CGFloat = 60
    /// Right-edge inset of the bubble from the frame's right edge.
    var bubbleRightInset: CGFloat = 20
    var bubbleHorizontalPadding: CGFloat = 14
    var bubbleVerticalPadding: CGFloat = 10
    var bubbleCornerRadius: CGFloat = 14

    var bubbleFillColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.15)
    }

    // MARK: - Placeholder (tool / group / thinking)

    var placeholderHeight: CGFloat = 36
    var placeholderHorizontalInset: CGFloat = 20
    var placeholderVerticalInset: CGFloat = 4
    var placeholderCornerRadius: CGFloat = 6
    var placeholderLineDashPattern: [CGFloat] = [4, 3]
    var placeholderTextFont: NSFont {
        .systemFont(ofSize: 12, weight: .regular)
    }

    // MARK: - Code block (Stage 3 visual, but used by row height math in Stage 2)

    var codeBlockHorizontalPadding: CGFloat = 12
    var codeBlockVerticalPadding: CGFloat { markdown.blockPadding }
    var codeBlockCornerRadius: CGFloat { markdown.blockCornerRadius }
}

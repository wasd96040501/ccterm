import SwiftUI

/// v1 placeholder for ``MarkdownSegment/codeBlock(_:)`` — monospaced text with
/// a tinted background. Syntax highlighting can plug in later via the existing
/// `SyntaxHighlightEngine`.
struct MarkdownCodeBlockView: View {
    let block: MarkdownCodeBlock

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        Text(block.code)
            .font(.system(size: theme.codeFontSize, design: .monospaced))
            .foregroundStyle(Color(nsColor: theme.primaryColor))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(nsColor: theme.codeBlockBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

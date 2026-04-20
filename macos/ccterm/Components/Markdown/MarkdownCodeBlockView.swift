import SwiftUI

/// Renders a fenced code block. Tokens are pre-computed by ``MarkdownView``
/// during `refresh()` and passed in here, so the first paint already shows
/// the syntax-highlighted attributed string — there is no plain → colored
/// flicker. When `tokens` is `nil` (e.g. no ``SyntaxHighlightEngine`` in the
/// environment), the body falls back to a plain monospaced rendering.
struct MarkdownCodeBlockView: View {
    let block: MarkdownCodeBlock
    let tokens: [SyntaxToken]?

    @Environment(\.markdownTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(content)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, theme.blockPadding)
            .padding(.horizontal, 12)
            .background(Color(nsColor: theme.codeBlockBackground))
            .clipShape(RoundedRectangle(cornerRadius: theme.blockCornerRadius))
    }

    private var content: AttributedString {
        let font = Font.system(size: theme.codeFontSize, design: .monospaced)
        if let tokens {
            return SyntaxAttributedString.build(
                tokens: tokens,
                colorScheme: colorScheme,
                font: font)
        }
        var plain = AttributedString(block.code)
        plain.font = font
        plain.foregroundColor = SyntaxTheme.plainColor(colorScheme)
        return plain
    }
}

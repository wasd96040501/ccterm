import SwiftUI

/// v1 placeholder for ``MarkdownSegment/mathBlock(_:)`` — renders raw LaTeX
/// source in monospace. A proper TeX renderer (SwiftMath) can swap in later
/// without touching other layers.
struct MarkdownMathBlockView: View {
    let raw: String

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        Text(raw)
            .font(.system(size: theme.codeFontSize, design: .monospaced))
            .foregroundStyle(Color(nsColor: theme.secondaryColor))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(nsColor: theme.codeBlockBackground).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// v1 ``MarkdownSegment/thematicBreak`` renderer.
struct MarkdownThematicBreakView: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

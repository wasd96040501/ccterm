import AppKit
import SwiftUI

/// Renders a ``MarkdownSegment/mathBlock(_:)``. The SwiftMath image is
/// pre-rendered during ``MarkdownView`` `refresh()` and passed in here, so
/// `body` is a pure data lookup. On parse failure (image == nil) we fall
/// back to monospaced source text so users still see something.
struct MarkdownMathBlockView: View {
    let raw: String
    let image: NSImage?

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text(raw)
                    .font(.system(size: theme.codeFontSize, design: .monospaced))
                    .foregroundStyle(Color(nsColor: theme.secondaryColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, theme.blockPadding)
        .padding(.horizontal, 12)
        .background(Color(nsColor: theme.codeBlockBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// v1 ``MarkdownSegment/thematicBreak`` renderer.
struct MarkdownThematicBreakView: View {
    var body: some View {
        Divider()
    }
}

import AppKit
import SwiftUI
import SwiftMath

/// Renders a ``MarkdownSegment/mathBlock(_:)`` as a typeset LaTeX image via
/// `SwiftMath`. The image is regenerated whenever the LaTeX source, font size,
/// or colour scheme changes. On parse failure we fall back to the raw source
/// in monospace so users still see something.
struct MarkdownMathBlockView: View {
    let raw: String

    @Environment(\.markdownTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = render() {
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

    /// Render LaTeX to an NSImage via SwiftMath. Returns nil on parse failure;
    /// callers fall back to the raw source. `colorScheme` is read so the view
    /// re-renders when the appearance flips.
    private func render() -> NSImage? {
        _ = colorScheme  // tracked so re-render fires on appearance change
        var img = MathImage(
            latex: raw,
            fontSize: theme.bodyFontSize * 1.4,
            textColor: theme.primaryColor,
            labelMode: .display,
            textAlignment: .center)
        let (error, image, _) = img.asImage()
        guard error == nil, let image else { return nil }
        return image
    }
}

/// v1 ``MarkdownSegment/thematicBreak`` renderer.
struct MarkdownThematicBreakView: View {
    var body: some View {
        Divider()
    }
}

import AppKit
import SwiftUI

/// Renders a top-level blockquote segment with a GitHub-style left bar.
/// Uses a SwiftUI `HStack` for the bar/content layout and `MarkdownTextView`
/// for the inner attributed string so links and inline styles still work.
struct MarkdownBlockquoteView: View {
    let attributed: NSAttributedString

    @Environment(\.markdownTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: theme.blockquoteBarGap) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(nsColor: theme.blockquoteBarColor))
                .frame(width: theme.blockquoteBarWidth)

            MarkdownTextView(
                attributed: attributed,
                linkColor: theme.linkColor,
                onOpenURL: { openURL($0) },
                inlineCodeHPadding: theme.inlineCodeHPadding,
                inlineCodeVPadding: theme.inlineCodeVPadding,
                inlineCodeCornerRadius: theme.inlineCodeCornerRadius)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

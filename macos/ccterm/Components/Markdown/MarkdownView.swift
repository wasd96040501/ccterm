import AppKit
import SwiftUI

// MARK: - Public API

/// Native SwiftUI markdown renderer.
///
/// Accepts either a raw markdown source or a pre-parsed ``MarkdownDocument``.
/// Styling and layout mode are controlled through environment values — see
/// ``SwiftUICore/View/markdownTheme(_:)`` and
/// ``SwiftUICore/View/markdownLayout(_:)``.
///
/// ```swift
/// MarkdownView(message.text)                // eager VStack (default)
///
/// MarkdownView(document: doc)
///     .markdownLayout(.lazy)                // long documents
///     .markdownTheme(.default)
/// ```
struct MarkdownView: View {
    private let input: Input

    init(_ source: String) {
        self.input = .source(source)
    }

    init(document: MarkdownDocument) {
        self.input = .document(document)
    }

    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownLayout) private var layout
    @Environment(\.openURL) private var openURL

    @State private var state: RenderState?

    var body: some View {
        content
            .task(id: taskKey) {
                await refresh()
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let state {
            switch layout {
            case .eager:
                VStack(alignment: .leading, spacing: theme.segmentSpacing) {
                    segmentViews(for: state)
                }
            case .lazy:
                LazyVStack(alignment: .leading, spacing: theme.segmentSpacing) {
                    segmentViews(for: state)
                }
            }
        } else {
            // Placeholder — collapses to zero height until the first task completes.
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private func segmentViews(for state: RenderState) -> some View {
        ForEach(Array(state.document.segments.enumerated()), id: \.offset) { idx, segment in
            segmentView(segment: segment, prebuilt: state.prebuilt[idx])
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(segment: MarkdownSegment, prebuilt: NSAttributedString?) -> some View {
        switch segment {
        case .markdown:
            if let prebuilt {
                MarkdownTextView(
                    attributed: prebuilt,
                    linkColor: theme.linkColor,
                    onOpenURL: { openURL($0) })
            }
        case .codeBlock(let block):
            MarkdownCodeBlockView(block: block)
        case .table(let table):
            MarkdownTableView(table: table)
        case .mathBlock(let raw):
            MarkdownMathBlockView(raw: raw)
        case .thematicBreak:
            MarkdownThematicBreakView()
        }
    }

    // MARK: - Task

    private var taskKey: TaskKey {
        switch input {
        case .source(let s):
            return TaskKey(inputHash: s.hashValue, fingerprint: theme.fingerprint)
        case .document(let d):
            return TaskKey(inputHash: d.hashValue, fingerprint: theme.fingerprint)
        }
    }

    private func refresh() async {
        let document: MarkdownDocument
        switch input {
        case .source(let s):
            document = await Task.detached(priority: .userInitiated) {
                MarkdownDocument(parsing: s)
            }.value
        case .document(let d):
            document = d
        }
        guard !Task.isCancelled else { return }

        let builder = MarkdownAttributedBuilder(theme: theme)
        let prebuilt: [NSAttributedString?] = document.segments.map { segment in
            if case .markdown(let blocks) = segment {
                return builder.build(blocks: blocks)
            }
            return nil
        }
        guard !Task.isCancelled else { return }
        state = RenderState(document: document, prebuilt: prebuilt)
    }

    // MARK: - Types

    private enum Input {
        case source(String)
        case document(MarkdownDocument)
    }

    private struct RenderState {
        let document: MarkdownDocument
        let prebuilt: [NSAttributedString?]
    }

    private struct TaskKey: Hashable {
        let inputHash: Int
        let fingerprint: MarkdownTheme.Fingerprint
    }
}

// MARK: - Layout mode

enum MarkdownLayout: Hashable, Sendable {
    /// Plain `VStack` — every segment is laid out up front. Default.
    /// Right for chat messages and other short content.
    case eager

    /// `LazyVStack` — segments are materialized as they scroll into view.
    /// Right for long documents.
    case lazy
}

// MARK: - Environment

private struct MarkdownThemeKey: EnvironmentKey {
    static let defaultValue: MarkdownTheme = .default
}

private struct MarkdownLayoutKey: EnvironmentKey {
    static let defaultValue: MarkdownLayout = .eager
}

extension EnvironmentValues {
    var markdownTheme: MarkdownTheme {
        get { self[MarkdownThemeKey.self] }
        set { self[MarkdownThemeKey.self] = newValue }
    }

    var markdownLayout: MarkdownLayout {
        get { self[MarkdownLayoutKey.self] }
        set { self[MarkdownLayoutKey.self] = newValue }
    }
}

extension View {
    /// Override the markdown theme for this subtree.
    func markdownTheme(_ theme: MarkdownTheme) -> some View {
        environment(\.markdownTheme, theme)
    }

    /// Pick between eager and lazy segment layout. Default is ``MarkdownLayout/eager``.
    func markdownLayout(_ mode: MarkdownLayout) -> some View {
        environment(\.markdownLayout, mode)
    }
}

// MARK: - Preview

#Preview("Markdown demo") {
    let sample = #"""
    # Markdown Renderer

    Native **SwiftUI** + *TextKit 1* rendering. Visit [Apple](https://apple.com) or read the `README.md`.

    Soft
    break collapses. Hard break below.\
    New line.

    ## Features

    - Paragraphs with **bold**, *italic*, ~~strike~~, `inline code`
    - Links like [GitHub](https://github.com)
    - Task list:
      - [x] Parse GFM
      - [ ] Render math blocks natively
      - [x] Tables via Grid
    - Nested:
      - level 2
        - level 3

    1. First ordered
    2. Second
    3. Third

    ### Blockquote

    > This is a blockquote.
    > Second line, same paragraph.
    >
    > Nested paragraphs work too.

    ### Code

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \(name)!"
    }
    ```

    ### Table

    | Name  | Age | Role     |
    |:------|:---:|---------:|
    | Alice |  30 | Engineer |
    | Bob   |  25 | Designer |

    ### Math

    Inline: $E = mc^2$. Block below:

    $$
    \int_0^1 x^2 dx = \frac{1}{3}
    $$

    ---

    End.
    """#

    ScrollView {
        MarkdownView(sample)
            .padding()
    }
    .frame(width: 640, height: 800)
}

#Preview("Short — eager, dark") {
    MarkdownView("Hello **world** — a [link](https://example.com) and `code`.")
        .padding()
        .frame(width: 400)
        .preferredColorScheme(.dark)
}

#Preview("Lazy layout") {
    let chunks = (1...80).map { "## Section \($0)\n\nSome **content** with `code` and a [link](https://example.com).\n" }
    ScrollView {
        MarkdownView(chunks.joined(separator: "\n"))
            .markdownLayout(.lazy)
            .padding()
    }
    .frame(width: 520, height: 700)
}

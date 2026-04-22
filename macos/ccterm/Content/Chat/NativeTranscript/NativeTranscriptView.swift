import AgentSDK
import AppKit
import SwiftUI

/// Native, NSTableView-backed chat transcript。对齐 Telegram macOS 的滚动性能：
/// - layer-backed 全栈 + `.never` redraw → live scroll 0 个 draw 调用
/// - 自绘 Core Text → 每行只做一次排版，CTLine 缓存
/// - NSTableView 的 rowView recycling 复用已经画好的 layer backing
///
/// 入口是 `NSViewRepresentable`，SwiftUI 侧可无感替换旧 `ChatTranscriptView`。
struct NativeTranscriptView: NSViewRepresentable {
    let entries: [MessageEntry]
    @Environment(\.markdownTheme) private var theme
    @Environment(\.syntaxEngine) private var syntaxEngine

    func makeNSView(context: Context) -> TranscriptScrollView {
        let sv = TranscriptScrollView()
        sv.controller.theme = theme
        sv.controller.syntaxEngine = syntaxEngine
        // Defer the first `setEntries` to `updateNSView` so we can lay out
        // against the real tableView width (SwiftUI inserts the view into the
        // hierarchy before updateNSView runs).
        return sv
    }

    func updateNSView(_ nsView: TranscriptScrollView, context: Context) {
        let ctrl = nsView.controller
        let themeChanged = ctrl.theme?.fingerprint != theme.fingerprint
        ctrl.theme = theme
        ctrl.syntaxEngine = syntaxEngine
        ctrl.setEntries(entries, themeChanged: themeChanged)
    }
}

// MARK: - Preview helpers

private enum PreviewFactory {
    static func userMessage(_ text: String) -> Message2 {
        let json: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": text,
            ],
        ]
        return parseOrUnknown(json, name: "user")
    }

    static func assistantText(_ text: String) -> Message2 {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        return parseOrUnknown(json, name: "assistant")
    }

    static func single(_ message: Message2) -> MessageEntry {
        .single(SingleEntry(
            id: UUID(),
            payload: .remote(message),
            delivery: nil,
            toolResults: [:]))
    }

    static func user(_ text: String) -> MessageEntry {
        single(userMessage(text))
    }

    static func assistant(_ markdown: String) -> MessageEntry {
        single(assistantText(markdown))
    }

    private static func parseOrUnknown(_ json: [String: Any], name: String) -> Message2 {
        (try? Message2(json: json)) ?? Message2.unknown(name: name, raw: json)
    }
}

// MARK: - Previews

#Preview("Empty") {
    NativeTranscriptView(entries: [])
        .frame(width: 480, height: 240)
}

#Preview("User only — short / long wrap") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Hi"),
        PreviewFactory.user(
            "Just checking that short bubbles hug their text and don't stretch."),
        PreviewFactory.user(
            "And that a much longer message also wraps cleanly without running into the left edge — the bubble should keep a comfortable gutter on the left while the right edge stays aligned with the content area."),
        PreviewFactory.user("OK, thanks!"),
    ])
    .frame(width: 640, height: 360)
}

#Preview("Headings & paragraphs") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        # Heading 1 — project overview

        A paragraph immediately after the H1 so we see the l1 gap.

        ## Heading 2 — goals

        This section describes goals. The paragraph should wrap cleanly across
        multiple lines, staying inside the content gutter, without overlapping
        either the H2 above or the H3 below.

        ### Heading 3 — nested details

        Another paragraph under H3, keeping consistent vertical rhythm.

        #### Heading 4
        ##### Heading 5
        ###### Heading 6

        Trailing paragraph to confirm the last heading has a body beneath it.
        """),
    ])
    .frame(width: 680, height: 600)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Inline styles") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        Text can be **bold**, *italic*, or ***both***. Inline code like
        `let x = 42` renders inside a chip, even when it spans more than one
        token: `UIViewController.viewDidLoad()`.

        Mixed: the function `greet(name:)` is **not** *yet* implemented — it
        should return a `String` built from `"Hello, \\(name)"`.

        A [link to swift.org](https://swift.org) is styled with the link color;
        bare URLs like https://developer.apple.com are auto-linkified when the
        parser supports it.

        Strikethrough uses ~~two tildes~~ around the span.
        """),
    ])
    .frame(width: 680, height: 400)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Links — across contexts") {
    NativeTranscriptView(entries: [
        PreviewFactory.user(
            "See [the swift.org guide](https://swift.org/documentation/) — bare URL too: https://developer.apple.com"),
        PreviewFactory.assistant("""
        Inline forms:

        - Markdown link: [Apple developer](https://developer.apple.com)
        - Bare URL: https://www.swift.org
        - Link with `code` inside: [the `URLSession` docs](https://developer.apple.com/documentation/foundation/urlsession)
        - Image syntax: ![Swift logo](https://swift.org/assets/images/swift.svg)

        Inside a blockquote:

        > Reference: [SE-0258 Property Wrappers](https://github.com/apple/swift-evolution/blob/main/proposals/0258-property-wrappers.md)
        > and a bare URL https://forums.swift.org for discussion.

        Inside a table:

        | Resource | URL |
        | -------- | --- |
        | Docs     | [developer.apple.com](https://developer.apple.com) |
        | Forums   | https://forums.swift.org |
        | Source   | [github.com/apple/swift](https://github.com/apple/swift) |

        Nested in a list with other inline styles:

        1. **Bold** then a [link](https://swift.org), then *italic*.
        2. A long line with multiple links: [one](https://example.com/one),
           [two](https://example.com/two), and [three](https://example.com/three)
           — all should be individually clickable without overlapping.
        """),
    ])
    .frame(width: 720, height: 560)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Lists — ordered / unordered / nested") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        Unordered:

        - First item
        - Second item with a longer description that wraps to the next line to
          confirm the hanging indent lines up with the bullet above
        - Third item
          - Nested A
          - Nested B with `inline code`
            - Deeply nested
        - Fourth item

        Ordered:

        1. Read the existing file
        2. Apply a small edit
        3. Run the tests
           1. Unit tests
           2. Integration tests
        4. Commit and push

        Mixed / task list:

        - [x] Checked item
        - [ ] Unchecked item
        - [ ] Another pending item with **bold** and *italic*
        """),
    ])
    .frame(width: 680, height: 620)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Blockquotes") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        Short blockquote:

        > This is a single-paragraph quote. It should render with the left bar
        > and a small gap before the text.

        Multi-paragraph:

        > First paragraph of a quote. It covers the setup of the argument.
        >
        > Second paragraph continues the thought and should keep the same bar
        > running down the full height of the block.

        Quote with inline styles:

        > **Note:** this is a quick prototype — we'll harden it later. Use
        > `force: true` only in tests, and ~~never~~ in production.
        """),
    ])
    .frame(width: 680, height: 520)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Code blocks — multiple languages") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        Swift:

        ```swift
        func greet(_ name: String) -> String {
            let salutation = "Hello"
            return "\\(salutation), \\(name)!"
        }
        ```

        Bash:

        ```bash
        #!/usr/bin/env bash
        set -euo pipefail

        for f in *.swift; do
          echo "Compiling $f"
        done
        ```

        JSON:

        ```json
        {
          "name": "ccterm",
          "version": "0.1.0",
          "deps": ["SwiftUI", "AppKit"]
        }
        ```

        Plain fenced (no language):

        ```
        plain preformatted
        block with   spaces
        preserved as-is
        ```
        """),
    ])
    .frame(width: 720, height: 720)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Tables") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        A small table with alignments:

        | Name  | Role           | Count |
        | :---- | :------------: | ----: |
        | Alice | Designer       |     3 |
        | Bob   | Engineer       |    12 |
        | Carol | Product Lead   |     7 |

        A wider table that should distribute column widths sensibly:

        | Feature      | Status         | Notes                                  |
        | ------------ | -------------- | -------------------------------------- |
        | Streaming    | Done           | Backpressure handled via AsyncStream   |
        | Cancellation | In progress    | Needs cooperative cancel points        |
        | Retries      | Not started    | Waiting on error taxonomy to stabilize |
        """),
    ])
    .frame(width: 760, height: 440)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Thematic break + mixed") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistant("""
        Part one — a short intro.

        ---

        Part two — after a horizontal rule.

        ***

        Part three — a third rule with asterisks.

        And a final paragraph to close things out.
        """),
    ])
    .frame(width: 640, height: 380)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Full conversation — kitchen sink") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Plan out the refactor and explain the tradeoffs."),
        PreviewFactory.assistant("""
        # Refactor plan

        Here's what I propose:

        1. Extract the **layout pass** into its own type.
        2. Merge *renderer* and *layout* into a single value.
        3. Keep the `Controller` purely as a data source.

        > Caveat: step 2 changes the public API of the layout module — any
        > callers outside `NativeTranscript` would need to migrate.

        ## Code sketch

        ```swift
        struct TranscriptTextLayout {
            static func make(attributed: NSAttributedString, maxWidth: CGFloat) -> Self { … }
            func draw(origin: CGPoint, in ctx: CGContext) { … }
        }
        ```

        ## Tradeoffs

        | Option         | Pros                | Cons                      |
        | -------------- | ------------------- | ------------------------- |
        | Merge          | Fewer files         | Bigger single file        |
        | Keep separate  | Clear responsibility| More import surface       |

        ---

        Let me know which option you prefer and I'll start executing.
        """),
        PreviewFactory.user(
            "Option one. And please update the comments to match the new layout."),
        PreviewFactory.assistant("""
        Got it — proceeding with **Option 1**. I'll:

        - Merge `TranscriptTextRenderer` into `TranscriptTextLayout`
        - Update doc comments in `AssistantMarkdownRow` and `UserBubbleRow`
        - Re-run `make build` to confirm

        ```bash
        make build
        ```

        Will report back with a diff summary.
        """),
        PreviewFactory.user("Thanks!"),
    ])
    .frame(width: 760, height: 820)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

import AgentSDK
import AppKit
import SwiftUI

/// Native, NSTableView-backed chat transcript。对齐 Telegram macOS 的滚动性能：
/// - layer-backed 全栈 + `.never` redraw → live scroll 0 个 draw 调用
/// - 自绘 Core Text → 每行只做一次排版，CTLine 缓存
/// - NSTableView 的 rowView recycling 复用已经画好的 layer backing
///
/// 消费契约：绑定 `SessionHandle2.snapshot`，每次 snapshot 变更 → controller
/// `setEntries(..., reason: snapshot.reason, ...)`。**reason 由 storage 层决定**，
/// controller 不从 entries delta 形状推断（对齐 Telegram `ChatHistoryViewUpdateType`
/// → `TableScrollState` 分层）。
///
/// Preview / 测试可直接用 `init(entries:reason:)` 跳过 snapshot，模拟一次固定
/// reason 的 paint。
struct NativeTranscriptView: NSViewRepresentable {
    let entries: [MessageEntry]
    let reason: TranscriptUpdateReason
    /// 仅 `.initialPaint` 消费：caller 在外层（session 切回来时）从
    /// `SessionHandle2.savedScrollAnchor` 读出并传入，让 controller 首帧围绕
    /// anchor 展开并恢复离开时的位置。其他 reason 忽略。
    var scrollHint: SavedScrollAnchor?
    /// 用户点击 sidebar 的时刻（从 `ChatHistoryView.task` 传入）。non-nil 时
    /// controller 会在首次 `.initialPaint` 的 Phase 2 merge 完成后 emit 一条
    /// OpenMetrics 日志，包含真实 TTFP（含 loadHistory I/O）+ cache 命中率。
    var openT0: CFAbsoluteTime? = nil
    /// SwiftUI 拆除本 NSView 时（`.id(sessionId)` 触发）调用一次，传入当前
    /// 顶部可见 row 的 anchor。caller 写回 `SessionHandle2.savedScrollAnchor`，
    /// 下次切回同 session 时恢复位置。nil = 离开时在 bottom / 无可捕。
    var onDismantle: ((SavedScrollAnchor?) -> Void)?

    @Environment(\.markdownTheme) private var theme
    @Environment(\.syntaxEngine) private var syntaxEngine

    init(entries: [MessageEntry],
         reason: TranscriptUpdateReason = .initialPaint,
         scrollHint: SavedScrollAnchor? = nil,
         openT0: CFAbsoluteTime? = nil,
         onDismantle: ((SavedScrollAnchor?) -> Void)? = nil) {
        self.entries = entries
        self.reason = reason
        self.scrollHint = scrollHint
        self.openT0 = openT0
        self.onDismantle = onDismantle
    }

    /// 桥接 SwiftUI `dismantleNSView`（static）与 instance 闭包。`updateNSView`
    /// 把当前 `onDismantle` 存到 coordinator；`dismantleNSView` 从 coordinator
    /// 读出来调用。
    final class Coordinator {
        weak var scrollView: TranscriptScrollView?
        var onDismantle: ((SavedScrollAnchor?) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let sv = TranscriptScrollView()
        sv.controller.theme = theme
        sv.controller.syntaxEngine = syntaxEngine
        context.coordinator.scrollView = sv
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
        context.coordinator.onDismantle = onDismantle
        // openT0 只在 controller 还没领到值 / 新的 session-open 起点时覆盖，
        // 避免重复赋值把同一 session 的 metric 重置。
        if let t0 = openT0, ctrl.openStartedAt == nil {
            ctrl.openStartedAt = t0
        }
        ctrl.setEntries(
            entries, reason: reason, themeChanged: themeChanged,
            scrollHint: scrollHint)
    }

    static func dismantleNSView(
        _ nsView: TranscriptScrollView,
        coordinator: Coordinator
    ) {
        guard let onDismantle = coordinator.onDismantle else { return }
        let hint = coordinator.scrollView?.controller.captureScrollHint()
        onDismantle(hint)
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

    /// Build an assistant message whose `content` is a caller-provided list of
    /// blocks (text / tool_use). Used by diff previews to co-locate a lead-in
    /// paragraph with an Edit / Write tool_use in a single message.
    static func assistantBlocks(_ blocks: [[String: Any]]) -> Message2 {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": blocks,
            ],
        ]
        return parseOrUnknown(json, name: "assistant")
    }

    static func editBlock(
        id: String = UUID().uuidString,
        filePath: String,
        oldString: String,
        newString: String
    ) -> [String: Any] {
        [
            "type": "tool_use",
            "name": "Edit",
            "id": id,
            "input": [
                "file_path": filePath,
                "old_string": oldString,
                "new_string": newString,
            ],
        ]
    }

    static func writeBlock(
        id: String = UUID().uuidString,
        filePath: String,
        content: String
    ) -> [String: Any] {
        [
            "type": "tool_use",
            "name": "Write",
            "id": id,
            "input": [
                "file_path": filePath,
                "content": content,
            ],
        ]
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
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

    static func assistantWithBlocks(_ blocks: [[String: Any]]) -> MessageEntry {
        single(assistantBlocks(blocks))
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

#Preview("Diff — Edit single hunk") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Rename `greet` to `sayHello` and update the salutation."),
        PreviewFactory.assistantWithBlocks([
            PreviewFactory.textBlock("I'll update the function name and the string it returns."),
            PreviewFactory.editBlock(
                filePath: "/Users/demo/app/Sources/Greeting.swift",
                oldString: """
                func greet(_ name: String) -> String {
                    let salutation = "Hello"
                    return "\\(salutation), \\(name)!"
                }
                """,
                newString: """
                func sayHello(_ name: String) -> String {
                    let salutation = "Hi"
                    return "\\(salutation), \\(name)!"
                }
                """),
        ]),
    ])
    .frame(width: 760, height: 420)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Diff — Edit multi-hunk with context") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistantWithBlocks([
            PreviewFactory.textBlock(
                "Extract the common prefix into a constant and tighten the guard."),
            PreviewFactory.editBlock(
                filePath: "macos/ccterm/Services/Logger.swift",
                oldString: """
                func log(_ level: Level, _ category: String, _ message: String) {
                    guard level.rawValue >= threshold.rawValue else { return }
                    let prefix = "[ccterm]"
                    let line = "\\(prefix) [\\(category)] \\(message)"
                    writer.write(line)
                }

                func logError(_ category: String, _ message: String) {
                    let prefix = "[ccterm]"
                    let line = "\\(prefix) [ERROR] [\\(category)] \\(message)"
                    writer.write(line)
                }
                """,
                newString: """
                private let logPrefix = "[ccterm]"

                func log(_ level: Level, _ category: String, _ message: String) {
                    guard level >= threshold else { return }
                    let line = "\\(logPrefix) [\\(category)] \\(message)"
                    writer.write(line)
                }

                func logError(_ category: String, _ message: String) {
                    let line = "\\(logPrefix) [ERROR] [\\(category)] \\(message)"
                    writer.write(line)
                }
                """),
        ]),
    ])
    .frame(width: 820, height: 620)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Diff — Write new file") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Create a small JSON config for the ingester."),
        PreviewFactory.assistantWithBlocks([
            PreviewFactory.textBlock("Writing a minimal config with sensible defaults."),
            PreviewFactory.writeBlock(
                filePath: "config/ingester.json",
                content: """
                {
                  "source": "s3://ingest-prod/events",
                  "batchSize": 500,
                  "parallelism": 4,
                  "retries": {
                    "max": 5,
                    "backoffMs": 250
                  }
                }
                """),
        ]),
    ])
    .frame(width: 760, height: 460)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Diff — long lines wrap") {
    NativeTranscriptView(entries: [
        PreviewFactory.assistantWithBlocks([
            PreviewFactory.textBlock(
                "Reformat the error message to include more context — note the lines are long enough to force wrapping inside the diff gutter."),
            PreviewFactory.editBlock(
                filePath: "macos/ccterm/Services/Session/SessionHandle.swift",
                oldString: """
                throw SessionError.invalidState("session is not running")
                """,
                newString: """
                throw SessionError.invalidState("session \\(id) is not running — current status=\\(status), last transition at \\(lastTransitionAt), pending permissions=\\(pendingPermissions.count); call start() before sending messages, or resume via SessionService.resume(id:) if the underlying process has exited")
                """),
        ]),
    ])
    .frame(width: 700, height: 420)
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

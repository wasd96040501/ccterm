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
        appLog(.info, "NativeTranscriptView",
            "[update] updateNSView reason=\(reason.logTag) entries=\(entries.count) "
            + "themeChanged=\(themeChanged) hasHint=\(scrollHint != nil) "
            + "openT0Set=\(ctrl.openStartedAt != nil)")
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
        parseOrUnknown([
            "type": "user",
            "uuid": UUID().uuidString,
            "message": ["role": "user", "content": text],
        ], name: "user")
    }

    static func assistantText(_ text: String) -> Message2 {
        parseOrUnknown([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ], name: "assistant")
    }

    static func assistantBlocks(_ blocks: [[String: Any]]) -> Message2 {
        parseOrUnknown([
            "type": "assistant",
            "message": ["role": "assistant", "content": blocks],
        ], name: "assistant")
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func editBlock(filePath: String, oldString: String, newString: String) -> [String: Any] {
        [
            "type": "tool_use", "name": "Edit", "id": UUID().uuidString,
            "input": [
                "file_path": filePath,
                "old_string": oldString,
                "new_string": newString,
            ],
        ]
    }

    static func writeBlock(filePath: String, content: String) -> [String: Any] {
        [
            "type": "tool_use", "name": "Write", "id": UUID().uuidString,
            "input": ["file_path": filePath, "content": content],
        ]
    }

    static func readToolUse(filePath: String) -> [String: Any] {
        [
            "type": "tool_use", "name": "Read", "id": UUID().uuidString,
            "input": ["file_path": filePath],
        ]
    }

    static func grepToolUse(pattern: String) -> [String: Any] {
        [
            "type": "tool_use", "name": "Grep", "id": UUID().uuidString,
            "input": ["pattern": pattern],
        ]
    }

    static func bashToolUse(command: String, description: String? = nil) -> [String: Any] {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        return [
            "type": "tool_use", "name": "Bash", "id": UUID().uuidString,
            "input": input,
        ]
    }

    static func user(_ text: String) -> MessageEntry {
        .single(SingleEntry(
            id: UUID(), payload: .remote(userMessage(text)),
            delivery: nil, toolResults: [:]))
    }

    static func assistant(_ markdown: String) -> MessageEntry {
        .single(SingleEntry(
            id: UUID(), payload: .remote(assistantText(markdown)),
            delivery: nil, toolResults: [:]))
    }

    static func assistantWithBlocks(_ blocks: [[String: Any]]) -> MessageEntry {
        .single(SingleEntry(
            id: UUID(), payload: .remote(assistantBlocks(blocks)),
            delivery: nil, toolResults: [:]))
    }

    /// Wrap N tool_use blocks into a GroupEntry — each block becomes its own
    /// SingleEntry (assistant with that one tool_use).
    static func group(toolUses: [[String: Any]]) -> MessageEntry {
        let items = toolUses.map { use -> SingleEntry in
            SingleEntry(
                id: UUID(),
                payload: .remote(assistantBlocks([use])),
                delivery: nil,
                toolResults: [:])
        }
        return .group(GroupEntry(id: UUID(), items: items))
    }

    private static func parseOrUnknown(_ json: [String: Any], name: String) -> Message2 {
        (try? Message2(json: json)) ?? Message2.unknown(name: name, raw: json)
    }
}

// MARK: - Previews

/// Fixed frame across previews —— 足够看清 layout、不至于超出 Xcode 画板。
private let kPreviewWidth: CGFloat = 760
private let kPreviewHeight: CGFloat = 620

#Preview("Conversation — markdown + code + tables") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Plan the refactor and explain the tradeoffs."),
        PreviewFactory.assistant("""
        # Refactor plan

        Here's what I propose:

        1. Extract the **layout pass** into its own type.
        2. Merge *renderer* and *layout* into a single value.
        3. Keep the `Controller` purely as a data source.

        > **Note:** step 2 changes the public API of the layout module — any
        > callers outside `NativeTranscript` would need to migrate.

        ## Code sketch

        ```swift
        struct TranscriptTextLayout {
            static func make(attributed: NSAttributedString, maxWidth: CGFloat) -> Self { … }
            func draw(origin: CGPoint, in ctx: CGContext) { … }
        }
        ```

        ## Tradeoffs

        | Option         | Pros                 | Cons                    |
        | -------------- | -------------------- | ----------------------- |
        | Merge          | Fewer files          | Bigger single file      |
        | Keep separate  | Clear responsibility | More import surface     |

        See [the swift.org guide](https://swift.org/documentation/) for more.
        """),
        PreviewFactory.user("Option one — and update the comments."),
    ])
    .frame(width: kPreviewWidth, height: kPreviewHeight)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Tools — single-use + diffs") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Rename `greet` to `sayHello` and add a config file."),
        PreviewFactory.assistantWithBlocks([
            PreviewFactory.textBlock("I'll update the function name, then write the config."),
            PreviewFactory.editBlock(
                filePath: "Sources/Greeting.swift",
                oldString: """
                func greet(_ name: String) -> String {
                    return "Hello, \\(name)!"
                }
                """,
                newString: """
                func sayHello(_ name: String) -> String {
                    return "Hi, \\(name)!"
                }
                """),
            PreviewFactory.writeBlock(
                filePath: "config/app.json",
                content: """
                {
                  "name": "ccterm",
                  "version": "0.1.0"
                }
                """),
        ]),
    ])
    .frame(width: kPreviewWidth, height: kPreviewHeight)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

/// Groups cover: completed(collapsed)、completed(with different tool kinds),
/// 最后一条 **active group 带 shimmer**（isLastEntry == true）。
#Preview("Groups — completed + active shimmer") {
    NativeTranscriptView(entries: [
        PreviewFactory.user("Look through the repo for TODOs and summarize."),
        // Completed group —— 过往 turn,不是最后一条 → 显示 "Read 2 files · Searched 1 patterns"
        PreviewFactory.group(toolUses: [
            PreviewFactory.readToolUse(filePath: "src/alpha.swift"),
            PreviewFactory.readToolUse(filePath: "src/beta.swift"),
            PreviewFactory.grepToolUse(pattern: "TODO"),
        ]),
        PreviewFactory.assistant("""
        Found 2 occurrences — let me patch the first one and run the tests.
        """),
        // 另一条 completed group —— mixed edits + bash
        PreviewFactory.group(toolUses: [
            PreviewFactory.editBlock(
                filePath: "Sources/Foo.swift",
                oldString: "// TODO: x",
                newString: "// done"),
            PreviewFactory.bashToolUse(command: "swift test", description: "run tests"),
        ]),
        PreviewFactory.user("Now search for unused imports."),
        // Active group —— entries.last,isActive=true,shimmer + active title
        // "Searching \"unused import\"" 形式。
        PreviewFactory.group(toolUses: [
            PreviewFactory.grepToolUse(pattern: "unused import"),
        ]),
    ])
    .frame(width: kPreviewWidth, height: kPreviewHeight)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

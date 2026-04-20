import AgentSDK
import SwiftUI

// MARK: - View

/// Native SwiftUI chat transcript — renders the timeline produced by
/// ``SessionHandle2`` (i.e. ``MessageEntry``) into a read-only, top-to-bottom
/// stream of user bubbles, assistant content, and grouped tool invocations.
///
/// Pure presentation: the caller owns the entries array; this view does not
/// react to session state.
struct ChatTranscriptView: View {
    let entries: [MessageEntry]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(for entry: MessageEntry) -> some View {
        switch entry {
        case .single(let single):
            SingleEntryView(entry: single)
        case .group(let group):
            GroupEntryView(
                group: group,
                isActive: entries.last?.id == entry.id)
        }
    }
}

// MARK: - Single entry

private struct SingleEntryView: View {
    let entry: SingleEntry

    var body: some View {
        switch entry.message {
        case .user(let u):
            if let text = u.plainText, !text.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 60)
                    UserBubble(text: text)
                }
            }
        case .assistant(let a):
            AssistantContentView(
                blocks: a.message?.content ?? [],
                toolResults: entry.toolResults)
        default:
            EmptyView()
        }
    }
}

// MARK: - Assistant content

private struct AssistantContentView: View {
    let blocks: [Message2AssistantMessageContent]
    let toolResults: [String: ItemToolResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    if let text = t.text, !text.isEmpty {
                        MarkdownView(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .toolUse(let use):
                    ToolBlockRow(toolUse: use, item: use.id.flatMap { toolResults[$0] })
                case .thinking, .unknown:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Group entry

private struct GroupEntryView: View {
    let group: GroupEntry
    let isActive: Bool

    @State private var isExpanded = false

    var body: some View {
        GroupBlock(isExpanded: $isExpanded) {
            ForEach(Array(toolUses.enumerated()), id: \.offset) { _, pair in
                ToolBlockRow(toolUse: pair.toolUse, item: pair.item)
            }
        } label: {
            Text(group.title(isActive: isActive))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var toolUses: [(toolUse: ToolUse, item: ItemToolResult?)] {
        group.items.flatMap { item in
            item.toolUses.map { use in
                (use, use.id.flatMap { item.toolResults[$0] })
            }
        }
    }
}

// MARK: - Tool block row

private struct ToolBlockRow: View {
    let toolUse: ToolUse
    let item: ItemToolResult?

    var body: some View {
        ToolBlockView(
            toolUse: toolUse,
            result: item.flatMap(toolUseResult(from:)),
            isError: item?.isError ?? false,
            errorText: item.flatMap(errorText(from:)))
    }
}

// MARK: - ItemToolResult → ToolBlockView inputs

/// Best-effort mapping from the block-level `tool_result` into the typed
/// ``ToolUseResult`` the tool blocks expect. Typed object projections
/// (``ToolUseResultObject``) aren't recoverable from the block content alone;
/// we fall back to string form so generic / text-based blocks still render.
private func toolUseResult(from item: ItemToolResult) -> ToolUseResult? {
    switch item.content {
    case .string(let s)?:
        return .string(s)
    case .array(let items)?:
        let texts = items.compactMap { entry -> String? in
            if case .text(let t) = entry { return t.text }
            return nil
        }
        return .string(texts.joined(separator: "\n"))
    case .other?, nil:
        return nil
    }
}

private func errorText(from item: ItemToolResult) -> String? {
    guard item.isError == true else { return nil }
    if case .string(let s) = toolUseResult(from: item) { return s }
    return nil
}

// MARK: - User message text extraction

private extension Message2User {
    /// Concatenate visible text from `.string` / `.array` user content. Ignores
    /// tool_result / image parts.
    var plainText: String? {
        switch message?.content {
        case .string(let s)?:
            return s
        case .array(let items)?:
            let parts = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.text }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }
}

// MARK: - User bubble

private struct UserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(.primary)
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

    static func assistantToolUses(_ uses: [[String: Any]]) -> Message2 {
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": uses,
            ],
        ]
        return parseOrUnknown(json, name: "assistant")
    }

    static func assistantMixed(text: String, uses: [[String: Any]]) -> Message2 {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: uses)
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": content,
            ],
        ]
        return parseOrUnknown(json, name: "assistant")
    }

    static func toolUse(id: String, name: String, input: [String: Any]) -> [String: Any] {
        [
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": input,
        ]
    }

    static func itemResult(
        toolUseId: String,
        text: String,
        isError: Bool = false
    ) -> ItemToolResult {
        let json: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": [["type": "text", "text": text]],
            "is_error": isError,
        ]
        return try! ItemToolResult(json: json)
    }

    static func single(_ message: Message2, results: [String: ItemToolResult] = [:]) -> MessageEntry {
        .single(SingleEntry(id: UUID(), message: message, delivery: nil, toolResults: results))
    }

    static func group(_ items: [SingleEntry]) -> MessageEntry {
        .group(GroupEntry(id: UUID(), items: items))
    }

    static func assistantSingle(_ uses: [[String: Any]], results: [String: ItemToolResult] = [:]) -> SingleEntry {
        SingleEntry(
            id: UUID(),
            message: assistantToolUses(uses),
            delivery: nil,
            toolResults: results)
    }

    private static func parseOrUnknown(_ json: [String: Any], name: String) -> Message2 {
        (try? Message2(json: json)) ?? Message2.unknown(name: name, raw: json)
    }
}

// MARK: - Previews

#Preview("Mixed — user + assistant + tools + group") {
    let bashId = "tu-bash"
    let editId = "tu-edit"
    let readA = "tu-read-a"
    let readB = "tu-read-b"
    let grepId = "tu-grep"

    return ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.userMessage(
            "List /usr/local/bin then patch the timeout in src/config.swift")),
        PreviewFactory.single(PreviewFactory.assistantMixed(
            text: "Sure — I'll **list the directory** first, then patch the config.",
            uses: [PreviewFactory.toolUse(
                id: bashId,
                name: "Bash",
                input: ["command": "ls -la /usr/local/bin"])]),
            results: [bashId: PreviewFactory.itemResult(
                toolUseId: bashId,
                text: "total 128\ndrwxr-xr-x  brew  staff  4096 Apr 18 10:30 .\n-rwxr-xr-x  brew  staff  2048 Apr 17 08:12 bun\n-rwxr-xr-x  brew  staff  1024 Apr 17 08:12 fzf")]),
        PreviewFactory.single(PreviewFactory.assistantMixed(
            text: "Now editing **src/config.swift**:",
            uses: [PreviewFactory.toolUse(
                id: editId,
                name: "Edit",
                input: [
                    "file_path": "src/config.swift",
                    "old_string": "let timeout = 3000",
                    "new_string": "let timeout = 5000",
                ])])),
        PreviewFactory.group([
            PreviewFactory.assistantSingle([
                PreviewFactory.toolUse(
                    id: readA, name: "Read",
                    input: ["file_path": "src/a.swift"]),
            ]),
            PreviewFactory.assistantSingle([
                PreviewFactory.toolUse(
                    id: readB, name: "Read",
                    input: ["file_path": "src/b.swift"]),
            ]),
            PreviewFactory.assistantSingle([
                PreviewFactory.toolUse(
                    id: grepId, name: "Grep",
                    input: ["pattern": "timeout"]),
            ]),
        ]),
        PreviewFactory.single(PreviewFactory.assistantText(
            "Done. The diff above shows the timeout going from `3000` to `5000` ms.")),
        PreviewFactory.single(PreviewFactory.userMessage("Thanks!")),
    ])
    .frame(width: 760, height: 720)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("All tool blocks — single assistant") {
    let ids = (
        bash: "p-bash",
        edit: "p-edit",
        write: "p-write",
        read: "p-read",
        grep: "p-grep",
        glob: "p-glob",
        webFetch: "p-webfetch",
        webSearch: "p-websearch",
        agent: "p-agent",
        ask: "p-ask",
        todo: "p-todo",
        skill: "p-skill"
    )

    return ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.assistantText(
            "Here's every tool block the dispatcher can render:")),
        PreviewFactory.single(PreviewFactory.assistantToolUses([
            PreviewFactory.toolUse(
                id: ids.bash, name: "Bash",
                input: ["command": "make build"]),
            PreviewFactory.toolUse(
                id: ids.edit, name: "Edit",
                input: [
                    "file_path": "src/config.swift",
                    "old_string": "let timeout = 3000",
                    "new_string": "let timeout = 5000",
                ]),
            PreviewFactory.toolUse(
                id: ids.write, name: "Write",
                input: [
                    "file_path": "NOTES.md",
                    "content": "# Notes\nA quick note.",
                ]),
            PreviewFactory.toolUse(
                id: ids.read, name: "Read",
                input: ["file_path": "src/main.swift"]),
            PreviewFactory.toolUse(
                id: ids.grep, name: "Grep",
                input: ["pattern": "func main"]),
            PreviewFactory.toolUse(
                id: ids.glob, name: "Glob",
                input: ["pattern": "**/*.swift"]),
            PreviewFactory.toolUse(
                id: ids.webFetch, name: "WebFetch",
                input: ["url": "https://example.com/docs"]),
            PreviewFactory.toolUse(
                id: ids.webSearch, name: "WebSearch",
                input: ["query": "swift concurrency"]),
            PreviewFactory.toolUse(
                id: ids.agent, name: "Agent",
                input: ["description": "Audit launch readiness"]),
            PreviewFactory.toolUse(
                id: ids.ask, name: "AskUserQuestion",
                input: ["questions": [["question": "Ship now?"]]]),
            PreviewFactory.toolUse(
                id: ids.todo, name: "TodoWrite",
                input: ["todos": []]),
            PreviewFactory.toolUse(
                id: ids.skill, name: "Skill",
                input: ["skill": "review"]),
        ]),
            results: [
                ids.bash: PreviewFactory.itemResult(
                    toolUseId: ids.bash,
                    text: "** BUILD SUCCEEDED **"),
                ids.read: PreviewFactory.itemResult(
                    toolUseId: ids.read,
                    text: "1\timport Foundation\n2\t\n3\tprint(\"hello\")"),
                ids.grep: PreviewFactory.itemResult(
                    toolUseId: ids.grep,
                    text: "src/main.swift:3:func main() {"),
            ]),
    ])
    .frame(width: 780, height: 900)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Error — assistant tool failure") {
    let bashId = "err-bash"
    return ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.userMessage("rm the missing file please")),
        PreviewFactory.single(PreviewFactory.assistantMixed(
            text: "Trying:",
            uses: [PreviewFactory.toolUse(
                id: bashId,
                name: "Bash",
                input: ["command": "rm /does/not/exist"])]),
            results: [bashId: PreviewFactory.itemResult(
                toolUseId: bashId,
                text: "rm: /does/not/exist: No such file or directory",
                isError: true)]),
    ])
    .frame(width: 720, height: 420)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Group — active progressive title") {
    let readId = "g-read"
    return ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.userMessage("Read a few source files")),
        PreviewFactory.group([
            PreviewFactory.assistantSingle([
                PreviewFactory.toolUse(
                    id: "g-r1", name: "Read",
                    input: ["file_path": "src/alpha.swift"]),
            ]),
            PreviewFactory.assistantSingle([
                PreviewFactory.toolUse(
                    id: readId, name: "Read",
                    input: ["file_path": "src/beta.swift"]),
            ]),
        ]),
    ])
    .frame(width: 720, height: 380)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("User only") {
    ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.userMessage("Hi")),
        PreviewFactory.single(PreviewFactory.userMessage(
            "Just checking that short bubbles hug their text and don't stretch.")),
        PreviewFactory.single(PreviewFactory.userMessage(
            "And that a much longer message also wraps cleanly without running into the left edge — the bubble should keep a comfortable gutter on the left while the right edge stays aligned with the content area.")),
    ])
    .frame(width: 640, height: 360)
}

#Preview("Assistant only — long markdown") {
    ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.assistantText("""
        ## Plan

        Here is the approach:

        1. Read the existing file
        2. Apply a small edit
        3. Run the tests

        ```swift
        func greet(_ name: String) -> String {
            return "Hello, \\(name)!"
        }
        ```

        > Note: this is a quick prototype — we'll harden it later.
        """)),
    ])
    .frame(width: 640, height: 500)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Empty") {
    ChatTranscriptView(entries: [])
        .frame(width: 480, height: 240)
}

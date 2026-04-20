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
            VStack(alignment: .leading, spacing: 16) {
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
    let toolResults: [String: ToolResultPayload]

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
                    ToolBlockRow(toolUse: use, payload: use.id.flatMap { toolResults[$0] })
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
                ToolBlockRow(toolUse: pair.toolUse, payload: pair.payload)
            }
        } label: {
            Text(group.title(isActive: isActive))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var toolUses: [(toolUse: ToolUse, payload: ToolResultPayload?)] {
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
    let payload: ToolResultPayload?

    var body: some View {
        ToolBlockView(
            toolUse: toolUse,
            result: payload.flatMap(resolvedResult(from:)),
            isError: payload?.isError ?? false,
            errorText: payload.flatMap(errorText(from:)))
    }
}

// MARK: - Payload → ToolBlockView inputs

/// Prefer the typed projection (carries `ObjectBash`, `ObjectGrep`, etc.
/// needed by body renderers). Fall back to a string reconstruction of the
/// tool_result block content so generic / text-only blocks still render.
private func resolvedResult(from payload: ToolResultPayload) -> ToolUseResult? {
    if let typed = payload.typed { return typed }
    switch payload.item.content {
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

private func errorText(from payload: ToolResultPayload) -> String? {
    guard payload.isError == true else { return nil }
    switch payload.item.content {
    case .string(let s)?:
        return s
    case .array(let items)?:
        let texts = items.compactMap { entry -> String? in
            if case .text(let t) = entry { return t.text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    case .other?, nil:
        return nil
    }
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

    static func payload(
        toolUseId: String,
        text: String,
        isError: Bool = false,
        typed: ToolUseResult? = nil
    ) -> ToolResultPayload {
        let json: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": [["type": "text", "text": text]],
            "is_error": isError,
        ]
        return ToolResultPayload(item: try! ItemToolResult(json: json), typed: typed)
    }

    static func grepResult(
        filenames: [String] = [],
        content: String? = nil,
        numFiles: Int? = nil,
        numMatches: Int? = nil
    ) -> ToolUseResult {
        var raw: [String: Any] = [:]
        if !filenames.isEmpty { raw["filenames"] = filenames }
        if let content { raw["content"] = content }
        if let numFiles { raw["num_files"] = numFiles }
        if let numMatches { raw["num_matches"] = numMatches }
        return .object(.Grep(try! ObjectGrep(json: raw), origin: nil))
    }

    static func webSearchResult(queryResults: [(title: String, url: String)]) -> ToolUseResult {
        let results: [[String: Any]] = queryResults.map { r in
            [
                "tool_use_id": UUID().uuidString,
                "content": [["title": r.title, "url": r.url]],
            ]
        }
        let raw: [String: Any] = ["results": results]
        return .object(.WebSearch(try! ObjectWebSearch(json: raw), origin: nil))
    }

    static func webFetchResult(code: Int, result: String) -> ToolUseResult {
        let raw: [String: Any] = ["code": code, "result": result]
        return .object(.WebFetch(try! ObjectWebFetch(json: raw), origin: nil))
    }

    static func bashResult(stdout: String? = nil, stderr: String? = nil) -> ToolUseResult {
        var raw: [String: Any] = [:]
        if let stdout { raw["stdout"] = stdout }
        if let stderr { raw["stderr"] = stderr }
        return .object(.Bash(try! ObjectBash(json: raw), origin: nil))
    }

    static func single(_ message: Message2, results: [String: ToolResultPayload] = [:]) -> MessageEntry {
        .single(SingleEntry(id: UUID(), payload: .remote(message), delivery: nil, toolResults: results))
    }

    static func group(_ items: [SingleEntry]) -> MessageEntry {
        .group(GroupEntry(id: UUID(), items: items))
    }

    static func assistantSingle(
        _ uses: [[String: Any]],
        results: [String: ToolResultPayload] = [:]
    ) -> SingleEntry {
        SingleEntry(
            id: UUID(),
            payload: .remote(assistantToolUses(uses)),
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
                input: [
                    "command": "ls -la /usr/local/bin",
                    "description": "list /usr/local/bin",
                ])]),
            results: [bashId: PreviewFactory.payload(
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
                input: [
                    "command": "make build",
                    "description": "build project",
                ]),
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
                ids.bash: PreviewFactory.payload(
                    toolUseId: ids.bash,
                    text: "** BUILD SUCCEEDED **",
                    typed: PreviewFactory.bashResult(
                        stdout: "Compiling Foo.swift\nCompiling Bar.swift\n** BUILD SUCCEEDED **",
                        stderr: nil)),
                ids.read: PreviewFactory.payload(
                    toolUseId: ids.read,
                    text: "1\timport Foundation\n2\t\n3\tprint(\"hello\")"),
                ids.grep: PreviewFactory.payload(
                    toolUseId: ids.grep,
                    text: "2 matches across 1 file",
                    typed: PreviewFactory.grepResult(
                        filenames: ["src/main.swift"],
                        content: "src/main.swift:3:func main() {\nsrc/main.swift:12:    main()",
                        numFiles: 1,
                        numMatches: 2)),
                ids.webFetch: PreviewFactory.payload(
                    toolUseId: ids.webFetch,
                    text: "fetched",
                    typed: PreviewFactory.webFetchResult(
                        code: 200,
                        result: "# Example\n\nThis is the fetched markdown content.\n\n- item 1\n- item 2")),
                ids.webSearch: PreviewFactory.payload(
                    toolUseId: ids.webSearch,
                    text: "2 results",
                    typed: PreviewFactory.webSearchResult(queryResults: [
                        (title: "Swift Concurrency — the road to Swift 6",
                         url: "https://swift.org/blog/concurrency"),
                        (title: "WWDC: Meet async/await",
                         url: "https://developer.apple.com/videos/play/wwdc2021/10132"),
                    ])),
            ]),
    ])
    .frame(width: 780, height: 900)
    .environment(\.syntaxEngine, SyntaxHighlightEngine())
}

#Preview("Errors — mixed tools") {
    let bash = "err-bash"
    let edit = "err-edit"
    let write = "err-write"
    let read = "err-read"
    let grep = "err-grep"

    return ChatTranscriptView(entries: [
        PreviewFactory.single(PreviewFactory.assistantToolUses([
            PreviewFactory.toolUse(
                id: bash, name: "Bash",
                input: [
                    "command": "rm /does/not/exist",
                    "description": "remove missing file",
                ]),
            PreviewFactory.toolUse(
                id: edit, name: "Edit",
                input: [
                    "file_path": "/readonly/file.swift",
                    "old_string": "let a = 1",
                    "new_string": "let a = 2",
                ]),
            PreviewFactory.toolUse(
                id: write, name: "Write",
                input: [
                    "file_path": "/readonly/NEW.md",
                    "content": "# header\nbody",
                ]),
            PreviewFactory.toolUse(
                id: read, name: "Read",
                input: ["file_path": "/missing/file.txt"]),
            PreviewFactory.toolUse(
                id: grep, name: "Grep",
                input: ["pattern": "[unterminated"]),
        ]),
            results: [
                bash: PreviewFactory.payload(
                    toolUseId: bash,
                    text: "rm: /does/not/exist: No such file or directory",
                    isError: true),
                edit: PreviewFactory.payload(
                    toolUseId: edit,
                    text: "EACCES: permission denied, open '/readonly/file.swift'",
                    isError: true),
                write: PreviewFactory.payload(
                    toolUseId: write,
                    text: "EROFS: read-only file system",
                    isError: true),
                read: PreviewFactory.payload(
                    toolUseId: read,
                    text: "ENOENT: no such file or directory",
                    isError: true),
                grep: PreviewFactory.payload(
                    toolUseId: grep,
                    text: "regex parse error: missing closing bracket",
                    isError: true),
            ]),
    ])
    .frame(width: 760, height: 720)
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

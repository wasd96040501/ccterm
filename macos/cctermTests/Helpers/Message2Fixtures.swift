import AgentSDK
import Foundation

@testable import ccterm

/// JSON-driven Message2 fixtures for unit tests. We construct messages by
/// feeding JSON dictionaries through `Message2Resolver` (the same path
/// production code uses for JSONL replay), avoiding hand-built generated
/// types whose initializers shift between SDK regenerations.
enum Message2Fixtures {

    /// One assistant text message. `parentToolUseId == nil` so it counts
    /// as visible.
    static func assistantText(_ text: String, messageId: String = "m") -> Message2 {
        resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
            ],
        ])
    }

    /// One user message containing a plain text content array.
    static func userText(_ text: String) -> Message2 {
        resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    /// Assistant message containing exactly one Read tool_use block. Useful
    /// for tool_group rendering tests.
    static func assistantRead(
        toolUseId: String, filePath: String
    ) -> Message2 {
        resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Read",
                        "input": ["file_path": filePath],
                    ]
                ],
            ],
        ])
    }

    /// JSONL line for `assistantText(...)` — useful when a test feeds bytes
    /// into `SessionRuntime.loadHistory(overrideURL:)`.
    static func assistantTextJSONL(_ text: String) -> String {
        jsonl([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m\(UUID().uuidString.prefix(8))",
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    static func userTextJSONL(_ text: String) -> String {
        jsonl([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    /// One assistant `tool_use` JSONL line. `toolUseId` is the anchor a
    /// matching `tool_result` user line refers back to.
    static func assistantReadJSONL(toolUseId: String, filePath: String) -> String {
        jsonl([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m\(UUID().uuidString.prefix(8))",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Read",
                        "input": ["file_path": filePath],
                    ]
                ],
            ],
        ])
    }

    /// One user `tool_result` JSONL line that resolves a prior tool_use.
    static func userToolResultJSONL(toolUseId: String, content: String) -> String {
        jsonl([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                ],
            ],
        ])
    }

    /// Generic assistant `tool_use` line — caller supplies tool `name`
    /// and `input` payload verbatim. Tool-specific helpers below thread
    /// through this.
    static func assistantToolUseJSONL(
        name: String, input: [String: Any], toolUseId: String
    ) -> String {
        jsonl([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m\(UUID().uuidString.prefix(8))",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": name,
                        "input": input,
                    ]
                ],
            ],
        ])
    }

    /// User `tool_result` line carrying a structured `toolUseResult`
    /// object so the renderer can hydrate the child's expandable body
    /// (Bash stdout/stderr, Grep filenames, etc.). The `content` field
    /// on the message is still a string — `toolUseResult` is the typed
    /// shape sibling to it that the resolver picks up.
    static func userTypedToolResultJSONL(
        toolUseId: String, content: String, toolUseResult: [String: Any]
    ) -> String {
        jsonl([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                ],
            ],
            "toolUseResult": toolUseResult,
        ])
    }

    // MARK: - Markdown-rich assistant fixtures

    static let assistantHeadingMarkdown: String = """
        # Section overview

        This paragraph follows the heading. The renderer should produce a
        heading row and a paragraph row.
        """

    static let assistantCodeBlockMarkdown: String = """
        Here is a swift snippet:

        ```swift
        func greet(name: String) -> String {
            return "hi, \\(name)"
        }
        ```
        """

    static let assistantListMarkdown: String = """
        Three notes:

        - first item with **bold** emphasis
        - second item that links to [the docs](https://example.test/)
        - third item that is a longer line that wraps to verify the list
          layout's continuation indent
        """

    static let assistantTableMarkdown: String = """
        | Phase | Source | Effect |
        | --- | --- | --- |
        | A | tail | renders the last viewport |
        | B | prefix | prepends remaining backlog |
        """

    static let assistantBlockquoteMarkdown: String = """
        > Quoting a previous reply:
        >
        > The transcript anchors at the bottom on cold mount.
        """

    /// Synthesise `n` mixed JSONL lines for a non-trivial history fixture
    /// that exercises every renderable transcript layout: assistant prose
    /// with markdown variants (heading / codeBlock / list / table /
    /// blockquote), user prompts (userBubble path), and every tool_use
    /// kind the bridge maps to a foldable child (Read / Edit / Write /
    /// Bash / Grep / Glob / WebFetch / WebSearch / Agent /
    /// AskUserQuestion) paired with a typed `toolUseResult` so the
    /// expandable body has real content to render. Output is plain
    /// English; the goal is "exceeds one viewport and trips the
    /// Phase A → Phase B boundary AND covers all expandable child
    /// kinds", not realism beyond what the renderer parses.
    static func bulkAssortedJSONL(count n: Int) -> [String] {
        precondition(n > 0)
        let userPrompts = [
            "Walk me through the chat transcript layout pipeline.",
            "Where does the bridge translate MessagesChange events?",
            "How is the loading pill rendered in the transcript?",
            "Explain the two-phase history load.",
            "Why does setHistory replace the block list?",
            "How does anchor-on-mount work after the refactor?",
            "Can you summarize the coordinator's responsibilities?",
            "What happens when the user switches sessions in the sidebar?",
        ]
        // Plain paragraph fallback when the rotation lands outside the
        // markdown/tool variants.
        let assistantParagraphs = [
            "The transcript is an `NSTableView` driven by a coordinator. Blocks "
                + "are diffed and rows are noted for height; nothing flows through "
                + "SwiftUI's normal layout path.",
            "Each `MessagesChange` event is consumed by the bridge, which maps "
                + "entries into block ids and forwards `apply` calls. The "
                + "controller is the public surface; the coordinator owns the table.",
            "The pill row is a sentinel block appended at the tail when "
                + "`isRunning` flips true. Removing it is the bridge's job once the "
                + "session quiets down again.",
        ]
        // Markdown variants — heading / codeBlock / list / table /
        // blockquote — to exercise every assistant-side block kind.
        let markdownVariants: [String] = [
            assistantHeadingMarkdown,
            assistantCodeBlockMarkdown,
            assistantListMarkdown,
            assistantTableMarkdown,
            assistantBlockquoteMarkdown,
        ]
        // Tool-use families. Each closure returns the pair of JSONL
        // lines (assistant tool_use + matching user tool_result with
        // typed `toolUseResult`) for one tool kind. The result payload
        // shapes mirror what AgentSDK's resolvers expect so the bridge
        // hydrates the expandable body. Order in this array drives the
        // rotation below.
        let toolGenerators: [(Int) -> [String]] = [
            // Read
            { turn in
                let id = "toolu_read_\(turn)"
                return [
                    assistantReadJSONL(
                        toolUseId: id,
                        filePath: "/tmp/transcript-fixture/turn-\(turn).md"),
                    userToolResultJSONL(
                        toolUseId: id,
                        content: "Line A from turn-\(turn).md\nLine B\nLine C"),
                ]
            },
            // Edit (fileEdit child — diff body)
            { turn in
                let id = "toolu_edit_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "Edit",
                        input: [
                            "file_path": "/tmp/fixture/edit-\(turn).swift",
                            "old_string":
                                "func legacy() {\n    return 0\n}",
                            "new_string":
                                "func renamed() {\n    return 1\n}",
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "Applied edit.",
                        toolUseResult: [
                            "type": "Edit",
                            "filePath": "/tmp/fixture/edit-\(turn).swift",
                            "oldString": "func legacy() {\n    return 0\n}",
                            "newString": "func renamed() {\n    return 1\n}",
                        ]),
                ]
            },
            // Bash (stdout + stderr)
            { turn in
                let id = "toolu_bash_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "Bash",
                        input: [
                            "command": "swiftc -version && echo turn=\(turn)",
                            "description": "Print compiler info",
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "swiftc-5.9 target: arm64-apple-macos14.0",
                        toolUseResult: [
                            "type": "Bash",
                            "stdout":
                                "swiftc-5.9 target: arm64-apple-macos14.0\nturn=\(turn)",
                            "stderr": "",
                            "interrupted": false,
                            "isImage": false,
                        ]),
                ]
            },
            // Grep
            { turn in
                let id = "toolu_grep_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "Grep",
                        input: [
                            "pattern": "TODO\\(turn-\(turn)\\)",
                            "path": "/tmp/fixture",
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "found 2 matches",
                        toolUseResult: [
                            "type": "Grep",
                            "filenames": [
                                "/tmp/fixture/sources/a.swift",
                                "/tmp/fixture/sources/b.swift",
                            ],
                            "content":
                                "a.swift:12: // TODO(turn-\(turn)) drop this branch\n"
                                + "b.swift:88: // TODO(turn-\(turn)) confirm policy",
                            "numFiles": 2,
                            "mode": "content",
                        ]),
                ]
            },
            // Glob
            { turn in
                let id = "toolu_glob_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "Glob",
                        input: ["pattern": "**/*.swift", "path": "/tmp/fixture"],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "matched 4 files",
                        toolUseResult: [
                            "type": "Glob",
                            "filenames": [
                                "/tmp/fixture/a.swift",
                                "/tmp/fixture/b.swift",
                                "/tmp/fixture/c.swift",
                                "/tmp/fixture/sources/inner-\(turn).swift",
                            ],
                            "numFiles": 4,
                            "truncated": false,
                        ]),
                ]
            },
            // WebFetch
            { turn in
                let id = "toolu_webfetch_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "WebFetch",
                        input: [
                            "url": "https://example.test/turn/\(turn)",
                            "prompt": "Summarize the page",
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "Fetched HTML",
                        toolUseResult: [
                            "type": "WebFetch",
                            "code": 200,
                            "codeText": "OK",
                            "url": "https://example.test/turn/\(turn)",
                            "result": "<title>Turn \(turn)</title><body>...</body>",
                            "durationMs": 142,
                            "bytes": 4_096,
                        ]),
                ]
            },
            // WebSearch
            { turn in
                let id = "toolu_websearch_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "WebSearch",
                        input: ["query": "transcript anchor stability turn \(turn)"],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "3 results",
                        toolUseResult: [
                            "type": "WebSearch",
                            "results": [
                                [
                                    "tool_use_id": id,
                                    "content": [
                                        [
                                            "title":
                                                "Anchor stability in NSTableView — example.test",
                                            "url":
                                                "https://example.test/anchor/\(turn)",
                                        ]
                                    ],
                                ]
                            ],
                            "query": "transcript anchor stability turn \(turn)",
                            "durationSeconds": 1.4,
                        ]),
                ]
            },
            // Agent (Task)
            { turn in
                let id = "toolu_agent_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "Task",
                        input: [
                            "name": "Explore",
                            "description":
                                "Find references to legacy() in fixture-\(turn)",
                            "prompt":
                                "Search /tmp/fixture for references to legacy()",
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "Agent task completed",
                        toolUseResult: [
                            "type": "Task",
                            "content": [
                                ["type": "text", "text": "Scanning fixture-\(turn)"],
                                [
                                    "type": "text",
                                    "text":
                                        "Found 2 references and 1 stale comment",
                                ],
                            ],
                            "totalDurationMs": 2_340,
                            "totalTokens": 1_823,
                        ]),
                ]
            },
            // AskUserQuestion
            { turn in
                let id = "toolu_ask_\(turn)"
                return [
                    assistantToolUseJSONL(
                        name: "AskUserQuestion",
                        input: [
                            "questions": [
                                [
                                    "question":
                                        "Approve change for turn \(turn)?",
                                    "header": "Approval",
                                    "multiSelect": false,
                                    "options": [
                                        ["label": "Yes", "description": "Accept"],
                                        ["label": "No", "description": "Reject"],
                                    ],
                                ]
                            ]
                        ],
                        toolUseId: id),
                    userTypedToolResultJSONL(
                        toolUseId: id,
                        content: "answered",
                        toolUseResult: [
                            "type": "AskUserQuestion",
                            "answers": [
                                "Approve change for turn \(turn)?": "Yes"
                            ],
                        ]),
                ]
            },
        ]

        var out: [String] = []
        out.reserveCapacity(n)
        // Outer loop drives turns; each turn emits a user prompt + an
        // assistant response. The response cycles through paragraph,
        // markdown variants, and the tool-use family — so a 60-turn
        // history hits every layout at least a few times. The fixture
        // is truncated to exactly `n` lines at the end.
        var turn = 0
        while out.count < n {
            let prompt = userPrompts[turn % userPrompts.count]
            out.append(userTextJSONL("Turn \(turn + 1): \(prompt)"))
            if out.count >= n { break }

            // Rotation: alternates between plain paragraph, markdown
            // variant, and a tool family. Three "lanes":
            //   0 → plain paragraph
            //   1 → markdown variant (heading/code/list/table/blockquote)
            //   2 → tool-use + tool-result pair
            let lane = turn % 3
            switch lane {
            case 0:
                let p = assistantParagraphs[turn % assistantParagraphs.count]
                out.append(assistantTextJSONL("Turn \(turn + 1) reply — \(p)"))
            case 1:
                let md = markdownVariants[turn % markdownVariants.count]
                out.append(assistantTextJSONL(md))
            default:
                let gen = toolGenerators[turn % toolGenerators.count]
                let pair = gen(turn)
                for line in pair {
                    if out.count >= n { break }
                    out.append(line)
                }
            }
            turn += 1
        }
        return Array(out.prefix(n))
    }

    // MARK: - Internals

    private static func resolve(_ dict: [String: Any]) -> Message2 {
        do {
            return try Message2Resolver().resolve(dict)
        } catch {
            fatalError("Message2Fixtures: resolver failed: \(error)\n\(dict)")
        }
    }

    private static func jsonl(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }
}

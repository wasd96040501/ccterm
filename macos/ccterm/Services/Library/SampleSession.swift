#if DEBUG
    import Foundation

    /// A made-up session that shows every kind of row a transcript can hold —
    /// each tool's calls, successes and failures, local commands, background
    /// task news, relayed messages, a compaction — so a Debug build always has
    /// one transcript that exercises every card and document.
    ///
    /// Written as the CLI writes a session, into a session directory of its own
    /// under the temporary directory (never the CLI's), which the Debug build
    /// lists beside the real one. Its project is a directory that doesn't
    /// exist; nothing reads it but the transcript's own rows.
    nonisolated enum SampleSession {
        /// The working directory the session claims to have run in.
        static let projectDirectory = "/Users/Shared/ccterm-sample"
        static let sessionID = "00000000-5a3d-4e00-8000-00000000c0de"
        static let subagentID = "a5a3d1e"

        /// Writes the sample into a fresh session directory under
        /// `temporaryDirectory`, replacing the last launch's, and answers the
        /// directory.
        static func install(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
            let root = temporaryDirectory.appendingPathComponent("ccterm-sample-sessions", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try write(into: root)
            return root
        }

        /// Writes the session — its transcript, and its subagent's with the
        /// sidecar — into the session directory at `root`. Answers the
        /// transcript.
        @discardableResult
        static func write(into root: URL) throws -> URL {
            let project = root.appendingPathComponent(
                projectDirectory.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            let subagents = project.appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            let transcript = project.appendingPathComponent("\(sessionID).jsonl")
            try jsonl(transcriptRows()).write(to: transcript)
            try jsonl(subagentRows()).write(to: subagents.appendingPathComponent("agent-\(subagentID).jsonl"))
            try JSONSerialization.data(withJSONObject: ["description": "Survey the renderer", "agentType": "Explore"])
                .write(to: subagents.appendingPathComponent("agent-\(subagentID).meta.json"))
            return transcript
        }

        private static func jsonl(_ rows: [[String: Any]]) throws -> Data {
            let lines = try rows.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }

        // MARK: - The session

        static func transcriptRows() -> [[String: Any]] {
            var s = Script(sessionID: sessionID, sidechain: false)
            s.meta(["type": "custom-title", "customTitle": "Sample: every transcript row"])

            // Opening: a prompt, thinking, an answer in markdown.
            s.prompt(
                "Tidy up `SourceView`: the gutter is off by a line, and the build is red. Show me what you change.")
            s.assistant([
                ["type": "thinking", "thinking": "Read the view and its gutter first.", "signature": "x"],
                ["type": "text", "text": "I'll look at the view and its gutter before changing anything."],
            ])

            // Reading: files, a range, an image, a search, a listing.
            s.tool(
                "Read", ["file_path": "\(projectDirectory)/Sources/SourceView.swift"],
                result: "(file contents)",
                recorded: [
                    "type": "text",
                    "file": [
                        "filePath": "\(projectDirectory)/Sources/SourceView.swift", "content": swiftFile,
                        "numLines": 24, "startLine": 1, "totalLines": 24,
                    ],
                ])
            s.tool(
                "Read", ["file_path": "\(projectDirectory)/Sources/Gutter.swift", "offset": 40, "limit": 6],
                result: "(file contents)",
                recorded: [
                    "type": "text",
                    "file": [
                        "filePath": "\(projectDirectory)/Sources/Gutter.swift",
                        "content": "    let digits = max(2, String(largest).count)\n    // Room for the bar.\n    return inset + width",
                        "numLines": 3, "startLine": 40, "totalLines": 88,
                    ],
                ])
            s.tool(
                "Read", ["file_path": "\(projectDirectory)/Docs/gutter.png"], result: "(image)",
                recorded: ["type": "image", "file": ["base64": onePixelPNG, "type": "image/png"]])
            s.tool(
                "Grep", ["pattern": "lineNumber", "path": "\(projectDirectory)/Sources", "output_mode": "content"],
                result: "3 matches",
                recorded: [
                    "mode": "content", "numFiles": 2, "filenames": [String](), "numLines": 3,
                    "content":
                        "Sources/Gutter.swift:12:    static let lineNumber = NSColor.tertiaryLabelColor\nSources/Gutter.swift:51:        draw(lineNumber: n)\nSources/SourceView.swift:9:    var lineNumbers = true",
                ])
            s.tool(
                "Glob", ["pattern": "**/*Tests.swift", "path": projectDirectory], result: "2 files",
                recorded: [
                    "filenames": [
                        "\(projectDirectory)/Tests/SourceViewTests.swift", "\(projectDirectory)/Tests/GutterTests.swift",
                    ], "numFiles": 2, "truncated": false, "durationMs": 14,
                ])
            s.say("The gutter counts from zero. Fixing that, and the doc comment while I'm there.")

            // Editing: a hunk with the file, several edits, a new file, a
            // rewrite, a notebook cell, and an edit that failed.
            s.tool(
                "Edit",
                [
                    "file_path": "\(projectDirectory)/Sources/SourceView.swift", "old_string": "var line = 0",
                    "new_string": "var line = 1",
                ],
                result: "The file has been updated.",
                recorded: [
                    "filePath": "\(projectDirectory)/Sources/SourceView.swift", "oldString": "var line = 0",
                    "newString": "var line = 1", "originalFile": swiftFile, "userModified": false,
                    "replaceAll": false,
                    "structuredPatch": [
                        [
                            "oldStart": 9, "oldLines": 6, "newStart": 9, "newLines": 7,
                            "lines": [
                                "     }", " ", "-    /// Draws the numbers.", "+    /// Draws the line numbers, from 1.",
                                "     func drawNumbers() {", "-        var line = 0",
                                "+        var line = 1", "+        let font = Self.numberFont",
                                "         for fragment in fragments {",
                            ],
                        ]
                    ],
                ])
            s.tool(
                "MultiEdit",
                [
                    "file_path": "\(projectDirectory)/Sources/Gutter.swift",
                    "edits": [
                        ["old_string": "inset + width", "new_string": "inset + width + trailing"],
                        ["old_string": "// Room for the bar.", "new_string": "// Room for the change bar."],
                    ],
                ],
                result: "Applied 2 edits.",
                recorded: [
                    "filePath": "\(projectDirectory)/Sources/Gutter.swift",
                    "structuredPatch": [
                        [
                            "oldStart": 40, "oldLines": 3, "newStart": 40, "newLines": 3,
                            "lines": [
                                "     let digits = max(2, String(largest).count)", "-    // Room for the bar.",
                                "+    // Room for the change bar.", "-    return inset + width",
                                "+    return inset + width + trailing",
                            ],
                        ]
                    ],
                ])
            s.tool(
                "Write",
                [
                    "file_path": "\(projectDirectory)/Tests/GutterNumberingTests.swift",
                    "content": testFile,
                ],
                result: "File created successfully.",
                recorded: [
                    "type": "create", "filePath": "\(projectDirectory)/Tests/GutterNumberingTests.swift",
                    "content": testFile, "structuredPatch": [Any](),
                ])
            s.tool(
                "Write", ["file_path": "\(projectDirectory)/README.md", "content": "# Sample\n\nNumbers start at 1.\n"],
                result: "The file has been updated.",
                recorded: [
                    "type": "update", "filePath": "\(projectDirectory)/README.md",
                    "content": "# Sample\n\nNumbers start at 1.\n", "originalFile": "# Sample\n\nNumbers start at 0.\n",
                    "structuredPatch": [
                        [
                            "oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 3,
                            "lines": [" # Sample", " ", "-Numbers start at 0.", "+Numbers start at 1."],
                        ]
                    ],
                ])
            s.tool(
                "NotebookEdit",
                [
                    "notebook_path": "\(projectDirectory)/Notebooks/metrics.ipynb", "cell_id": "c3",
                    "new_source": "df.plot(x='line', y='offset')", "cell_type": "code", "edit_mode": "replace",
                ],
                result: "Updated cell c3.",
                recorded: [
                    "new_source": "df.plot(x='line', y='offset')", "cell_id": "c3", "cell_type": "code",
                    "language": "python", "edit_mode": "replace", "error": "",
                ])
            s.tool(
                "Edit",
                [
                    "file_path": "\(projectDirectory)/Sources/Theme.swift", "old_string": "let spacing = 1.2",
                    "new_string": "let spacing = 1.1",
                ],
                result: "<tool_use_error>String to replace not found in file.\nString: let spacing = 1.2</tool_use_error>",
                isError: true, recorded: "Error: String to replace not found in file.\nString: let spacing = 1.2")
            s.say("Now the build.")

            // Shell: a success with colours, a failure, a background run, its
            // output read two ways, and a stop.
            s.tool(
                "Bash", ["command": "swift build 2>&1 | tail -4", "description": "Build the package"],
                result: "Build complete!",
                recorded: [
                    "stdout":
                        "\u{1B}[1mCompiling\u{1B}[0m SampleKit SourceView.swift\n\u{1B}[1mCompiling\u{1B}[0m SampleKit Gutter.swift\n\u{1B}[32mBuild complete!\u{1B}[0m (4.21s)",
                    "stderr": "", "interrupted": false, "isImage": false,
                ])
            s.tool(
                "Bash", ["command": "swift test --filter GutterNumberingTests", "description": "Run the new tests"],
                result:
                    "Exit code 1\nTests/GutterNumberingTests.swift:9: error: XCTAssertEqual failed: (\"0\") is not equal to (\"1\")",
                isError: true,
                recorded:
                    "Error: Exit code 1\nTests/GutterNumberingTests.swift:9: error: XCTAssertEqual failed: (\"0\") is not equal to (\"1\")"
            )
            s.tool(
                "Bash",
                [
                    "command": "swift test --parallel", "description": "Run the whole suite in the background",
                    "run_in_background": true,
                ],
                result: "Command running in background with ID: bg1",
                recorded: ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "bg1"])
            s.tool(
                "TaskOutput", ["task_id": "bg1", "block": true, "timeout": 60000], result: "(output)",
                recorded: [
                    "retrieval_status": "success",
                    "task": [
                        "task_id": "bg1", "task_type": "local_bash", "status": "completed",
                        "description": "Run the whole suite in the background",
                        "output":
                            "Test Suite 'All tests' started.\nTest Suite 'GutterTests' passed (0.012 seconds).\nTest Suite 'SourceViewTests' passed (0.230 seconds).\n\u{1B}[32mExecuted 42 tests, with 0 failures\u{1B}[0m",
                        "exitCode": 0,
                    ],
                ])
            s.tool(
                "Bash",
                ["command": "npm run watch", "description": "Watch the docs site", "run_in_background": true],
                result: "Command running in background with ID: bg2",
                recorded: ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "bg2"])
            s.tool(
                "BashOutput", ["bash_id": "bg2"], result: "(output)",
                recorded: [
                    "stdout": "> docs@1.0.0 watch\n> eleventy --watch\n\n[11ty] Watching…",
                    "stderr": "[11ty] Warning: no layout for index.md", "status": "running", "command": "npm run watch",
                ])
            s.tool(
                "KillShell", ["shell_id": "bg2"], result: "Successfully killed shell: bg2 (npm run watch)",
                recorded: ["message": "Successfully killed shell: bg2 (npm run watch)", "shell_id": "bg2"])
            s.say("The suite is green. Checking the docs on the gutter's width.")

            // One call on its own.
            s.tool(
                "WebFetch",
                [
                    "url": "https://developer.apple.com/documentation/appkit/nsrulerview",
                    "prompt": "What does ruleThickness default to?",
                ],
                result: "It defaults to 16 points.",
                recorded: [
                    "url": "https://developer.apple.com/documentation/appkit/nsrulerview", "code": 200,
                    "codeText": "OK", "bytes": 48213, "durationMs": 812,
                    "result": "**ruleThickness** defaults to 16 points; a ruler with markers adds `reservedThicknessForMarkers`.",
                ])
            s.say("Let me get a second opinion from a subagent while I look around.")

            // Web search and subagents.
            s.tool(
                "WebSearch", ["query": "Xcode source editor gutter width line numbers"], result: "(results)",
                recorded: [
                    "query": "Xcode source editor gutter width line numbers", "durationSeconds": 1.4,
                    "results": [
                        [
                            "tool_use_id": "srv",
                            "content": [
                                ["title": "Xcode: Editor preferences", "url": "https://developer.apple.com/xcode/"],
                                ["title": "NSRulerView", "url": "https://developer.apple.com/documentation/appkit/nsrulerview"],
                            ],
                        ],
                        "The gutter grows with the widest line number.",
                    ],
                ])
            s.tool(
                "Agent",
                [
                    "description": "Survey the renderer", "subagent_type": "Explore",
                    "prompt": "Find every place the gutter's width is computed and report how each is kept in sync.",
                ],
                result: "(report)",
                recorded: [
                    "status": "completed", "agentId": subagentID, "totalToolUseCount": 6, "totalDurationMs": 41200,
                    "totalTokens": 18342,
                    "content": [
                        [
                            "type": "text",
                            "text":
                                "## Findings\n\nThe width is computed in **one** place, `Gutter.updateThickness()`, and read by:\n\n1. `SourceView.reload()` — sets the width constraint.\n2. `SourceView.restyle()` — only redraws.\n\n```swift\nthickness = ceil(inset + digits * digit + trailing)\n```\n\nNothing else caches it.",
                        ]
                    ],
                ])
            s.tool(
                "Agent",
                [
                    "description": "Benchmark scrolling", "prompt": "Profile scrolling a 50k-line file.",
                    "run_in_background": true,
                ],
                result: "Async agent launched.",
                recorded: [
                    "status": "async_launched", "agentId": "a77", "outputFile": "/tmp/ccterm-sample/a77.output",
                ])

            // Bookkeeping: to-dos, tasks, plan mode, a question, an MCP tool,
            // and a call still waiting.
            s.tool(
                "TodoWrite",
                [
                    "todos": [
                        ["content": "Number lines from 1", "status": "completed", "activeForm": "Numbering"],
                        ["content": "Widen the gutter", "status": "in_progress", "activeForm": "Widening"],
                        ["content": "Update the README", "status": "pending", "activeForm": "Updating"],
                    ]
                ], result: "Todos have been modified successfully.",
                recorded: ["oldTodos": [Any](), "newTodos": [Any]()])
            s.tool(
                "TaskCreate", ["subject": "Profile scrolling", "description": "50k lines, both appearances"],
                result: "Task #1 created", recorded: ["task": ["id": "1", "subject": "Profile scrolling"]])
            s.tool(
                "TaskUpdate", ["taskId": "1", "status": "completed"], result: "Updated task #1",
                recorded: [
                    "success": true, "taskId": "1", "updatedFields": ["status"],
                    "statusChange": ["from": "pending", "to": "completed"],
                ])
            s.tool(
                "EnterPlanMode", [:], result: "Entered plan mode.",
                recorded: ["message": "Entered plan mode. Explore and design before editing."])
            s.tool(
                "ExitPlanMode",
                ["plan": "## Plan\n\n1. Number lines from **1**.\n2. Widen the gutter by the trailing inset.\n3. Test both."],
                result: "User has approved your plan.",
                recorded: [
                    "plan": "## Plan\n\n1. Number lines from **1**.\n2. Widen the gutter by the trailing inset.\n3. Test both.",
                    "isAgent": false, "filePath": "/tmp/ccterm-sample/plan.md",
                ])
            s.tool(
                "AskUserQuestion",
                [
                    "questions": [
                        [
                            "question": "Should the gutter follow the text's font size?", "header": "Gutter",
                            "multiSelect": false,
                            "options": [
                                ["label": "Yes", "description": "Scale the numbers with the text"],
                                ["label": "No", "description": "Keep Xcode's 11 pt"],
                            ],
                        ]
                    ]
                ], result: "User answered: No",
                recorded: ["questions": [Any](), "answers": ["Should the gutter follow the text's font size?": "No"]])
            s.tool(
                "mcp__github__create_issue",
                ["owner": "sample", "repo": "sample", "title": "Gutter numbers start at 0", "labels": ["bug"]],
                result: "{\"number\": 42, \"url\": \"https://github.com/sample/sample/issues/42\"}",
                recorded: [["type": "text", "text": "{\"number\": 42}"]])
            s.tool(
                "Bash", ["command": "rm -rf .build", "description": "Clean the build folder"],
                result:
                    "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
                isError: true, recorded: "User rejected tool use")
            s.prompt("[Request interrupted by user for tool use]")

            // Local commands, with and without output.
            s.prompt(
                "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>",
                meta: true)
            s.prompt("<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>")
            s.prompt("<local-command-stdout>Set model to \u{1B}[1mOpus\u{1B}[22m</local-command-stdout>")
            s.prompt("<command-name>/cost</command-name>\n<command-message>cost</command-message>\n<command-args></command-args>")
            s.prompt(
                "<local-command-stdout>Total cost:            $1.84\nTotal duration (API):  6m 12s\nTotal duration (wall): 41m 3s\nTotal code changes:    38 lines added, 9 lines removed\nUsage by model:\n    claude-haiku:  12.1k input, 1.2k output\n    claude-opus:  402.7k input, 18.9k output</local-command-stdout>"
            )
            s.prompt("<bash-input>git status --short</bash-input>")
            s.prompt(
                "<bash-stdout> M Sources/Gutter.swift\n M Sources/SourceView.swift\n?? Tests/GutterNumberingTests.swift</bash-stdout><bash-stderr></bash-stderr>"
            )
            s.prompt("<bash-input>cat missing.txt</bash-input>")
            s.prompt("<bash-stdout></bash-stdout><bash-stderr>cat: missing.txt: No such file or directory</bash-stderr>")
            s.prompt("<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>")

            // Background tasks' news.
            s.notification(
                "<task-notification>\n<task-id>a77</task-id>\n<task-type>local_agent</task-type>\n<status>completed</status>\n<summary>Agent \"Benchmark scrolling\" completed</summary>\n<result>Scrolling holds **120 fps** up to 50k lines; above that, layout of the gutter dominates.\n\n| Lines | fps |\n|---|---|\n| 10k | 120 |\n| 50k | 118 |\n| 200k | 64 |</result>\n<usage><subagent_tokens>9120</subagent_tokens><tool_uses>11</tool_uses><duration_ms>63000</duration_ms></usage>\n</task-notification>"
            )
            s.notification(
                "<task-notification>\n<task-id>bg3</task-id>\n<task-type>local_bash</task-type>\n<status>failed</status>\n<summary>Background command \"swift test --sanitize=thread\" failed with exit code 1</summary>\n</task-notification>"
            )
            s.notification(
                "<task-notification><task-id>bg2</task-id><status>stopped</status><summary>Background command \"npm run watch\" was stopped</summary></task-notification>"
            )
            s.notification(
                "<task-notification><task-id>m1</task-id><summary>Monitor event: \"deploy\"</summary><event>rollout 3/5 healthy</event></task-notification>"
            )
            s.notification(
                "<task-notification>\n<task-id>w1</task-id>\n<status>failed</status>\n<summary>Workflow \"audit\" failed</summary>\n<usage><agent_count>4</agent_count><agents_done>2</agents_done><agents_error>1</agents_error><agents_skipped>1</agents_skipped><agents_empty_result>0</agents_empty_result></usage>\n<failures>step 3: timed out after 600s</failures>\n<recovery>Resume with the run id w1.</recovery>\n</task-notification>"
            )

            // Messages relayed in from elsewhere.
            s.prompt(
                "<agent-message from=\"\(subagentID)\">\n[Subagent hand-back] The text below is the final report of a subagent. The report follows:\n  The gutter's width is computed once; nothing else caches it.\n</agent-message>"
            )
            s.prompt(
                "Another Claude session sent a message while you were working:\n<cross-session-message from=\"uds:/tmp/s.sock\" from-name=\"lamport\" from-mode=\"prompting\">\nAre you touching `Theme.swift`? I am.\n</cross-session-message>",
                origin: "peer")
            s.prompt(
                "The coordinator sent a message while you were working:\nKeep the change bar 3 pt wide.\n\nAddress this before completing your current task.",
                origin: "coordinator")
            s.prompt(
                "The taskcut plugin sent a message:\nContinue.\n\nThis is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.",
                origin: "plugin")
            s.prompt("<system-reminder>The user opened Gutter.swift.</system-reminder>", meta: true)
            s.assistant([["type": "text", "text": "Understood — the bar stays 3 pt, and I'm not touching `Theme.swift`."]])

            // A compaction, and the conversation after it.
            s.compaction()
            s.prompt(
                "This session is being continued from a previous conversation that ran out of context. The gutter now numbers from 1…",
                meta: true, compactSummary: true)
            s.prompt("Great. Summarise what changed?")
            s.assistant([
                [
                    "type": "text",
                    "text":
                        "## What changed\n\n| File | Change |\n|---|---|\n| `SourceView.swift` | numbers from **1** |\n| `Gutter.swift` | wider by the trailing inset |\n| `README.md` | says so |\n\nThe new test:\n\n```swift\nXCTAssertEqual(gutter.firstNumber, 1)\n```\n\nThe suite is green; one sanitizer run failed in the background and needs a look.",
                ]
            ])
            return s.rows
        }

        /// The subagent's own transcript: its brief, a search, its report.
        static func subagentRows() -> [[String: Any]] {
            var s = Script(sessionID: sessionID, sidechain: true)
            s.prompt("Find every place the gutter's width is computed and report how each is kept in sync.")
            s.tool(
                "Grep", ["pattern": "thickness", "path": "\(projectDirectory)/Sources", "output_mode": "files_with_matches"],
                result: "2 files",
                recorded: [
                    "mode": "files_with_matches", "numFiles": 2,
                    "filenames": ["Sources/Gutter.swift", "Sources/SourceView.swift"],
                ])
            s.assistant([["type": "text", "text": "## Findings\n\nThe width is computed in one place."]])
            return s.rows
        }

        // MARK: - Files the session touches

        private static let swiftFile = """
            import AppKit

            /// A read-only source editor.
            final class SourceView: NSView {
                var lineNumbers = true
                private var fragments: [NSRect] = []
                init() {
                    super.init(frame: .zero)
                }

                /// Draws the numbers.
                func drawNumbers() {
                    var line = 0
                    for fragment in fragments {
                        draw(number: line, in: fragment)
                        line += 1
                    }
                }

                private func draw(number: Int, in rect: NSRect) {
                    let text = "\\(number)" as NSString
                    text.draw(at: rect.origin, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
                }
            }
            """

        private static let testFile = """
            import XCTest
            @testable import SampleKit

            final class GutterNumberingTests: XCTestCase {
                func testNumbersStartAtOne() {
                    let gutter = Gutter()
                    gutter.lines = ["a", "b"]
                    XCTAssertEqual(gutter.firstNumber, 1)
                }
            }
            """

        private static let onePixelPNG =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    }

    /// Rows as the CLI writes them: each chained to the one before, timed a
    /// few seconds apart, an assistant turn one content block per row.
    private nonisolated struct Script {
        let sessionID: String
        let sidechain: Bool
        private(set) var rows: [[String: Any]] = []
        private var parent: String?
        private var serial = 0
        private let start = Date(timeIntervalSinceNow: -3600)

        init(sessionID: String, sidechain: Bool) {
            self.sessionID = sessionID
            self.sidechain = sidechain
        }

        mutating func meta(_ row: [String: Any]) {
            rows.append(row.merging(["sessionId": sessionID]) { $1 })
        }

        mutating func prompt(_ text: String, meta: Bool = false, compactSummary: Bool = false, origin: String? = nil) {
            var extra: [String: Any] = [:]
            if meta { extra["isMeta"] = true }
            if compactSummary { extra["isCompactSummary"] = true }
            if let origin { extra["origin"] = ["kind": origin] }
            chain("user", ["role": "user", "content": text], extra)
        }

        mutating func notification(_ text: String) {
            prompt(text, origin: "task-notification")
        }

        mutating func assistant(_ blocks: [[String: Any]]) {
            let id = "msg_\(serial)"
            for block in blocks {
                chain(
                    "assistant",
                    ["id": id, "model": "claude-opus-5-5", "role": "assistant", "type": "message", "content": [block]],
                    [:])
            }
        }

        mutating func say(_ text: String) {
            assistant([["type": "text", "text": text]])
        }

        /// A call and its result: `recorded` is what the CLI keeps for the app
        /// (`toolUseResult`), `result` what the model was shown.
        mutating func tool(
            _ name: String, _ input: [String: Any], result: String, isError: Bool = false, recorded: Any
        ) {
            let id = "toolu_\(String(format: "%03d", serial))"
            assistant([["type": "tool_use", "id": id, "name": name, "input": input]])
            chain(
                "user",
                [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": id, "content": result, "is_error": isError]],
                ],
                ["toolUseResult": recorded])
        }

        mutating func compaction() {
            serial += 1
            let uuid = uuid(serial)
            rows.append([
                "type": "system", "subtype": "compact_boundary", "uuid": uuid, "parentUuid": NSNull(),
                "logicalParentUuid": parent.map { $0 as Any } ?? NSNull(), "sessionId": sessionID, "isSidechain": sidechain,
                "timestamp": timestamp(), "content": "Conversation compacted", "isMeta": false,
                "compactMetadata": ["trigger": "manual", "preTokens": 142_318],
            ])
            parent = uuid
        }

        private mutating func chain(_ type: String, _ message: [String: Any], _ extra: [String: Any]) {
            serial += 1
            let uuid = uuid(serial)
            var row: [String: Any] = [
                "type": type, "uuid": uuid, "parentUuid": parent.map { $0 as Any } ?? NSNull(), "sessionId": sessionID,
                "isSidechain": sidechain, "timestamp": timestamp(), "cwd": SampleSession.projectDirectory,
                "gitBranch": "main", "entrypoint": "cli", "version": "2.1.0", "userType": "external",
                "message": message,
            ]
            if sidechain { row["agentId"] = SampleSession.subagentID }
            row.merge(extra) { $1 }
            rows.append(row)
            parent = uuid
        }

        private func uuid(_ n: Int) -> String {
            String(format: "%08lx-0000-4000-8000-%012lx", sidechain ? 1 : 0, n)
        }

        private func timestamp() -> String {
            ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(serial) * 7))
        }
    }
#endif

#if DEBUG
import SwiftUI

/// Debug-only gallery for visually testing all chat message components in the WebView.
struct ChatGalleryView: View {

    @State private var contentView = ChatContentView()

    var body: some View {
        WebViewRepresentable(webView: contentView.webView, filterToolbarHits: true)
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { sendMockMessages() }
    }

    // MARK: - Mock Data

    private static let conversationId = "gallery-mock"

    private func sendMockMessages() {
        // Bridge queues calls until WKWebView finishes loading, so these
        // are safe to call immediately — they'll execute once React is ready.
        let bridge = contentView.bridge
        bridge.switchConversation(Self.conversationId)
        bridge.setRawMessages(
            conversationId: Self.conversationId,
            messagesJSON: Self.mockMessages
        )
    }

    // MARK: - Message Builders

    private static func userMessage(text: String, uuid: String) -> [String: Any] {
        [
            "type": "user",
            "uuid": uuid,
            "timestamp": "2026-04-01T12:00:00Z",
            "message": [
                "role": "user",
                "content": text,
            ] as [String: Any],
        ]
    }

    private static func assistantMessage(
        uuid: String,
        content: [[String: Any]]
    ) -> [String: Any] {
        [
            "type": "assistant",
            "uuid": uuid,
            "timestamp": "2026-04-01T12:00:01Z",
            "message": [
                "role": "assistant",
                "content": content,
                "stop_reason": "end_turn",
            ] as [String: Any],
        ]
    }

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func toolUseBlock(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private static func toolResultMessage(
        uuid: String,
        toolUseId: String,
        toolName: String,
        result: [String: Any],
        isError: Bool = false
    ) -> [String: Any] {
        var resultWithTool = result
        resultWithTool["_resolved_tool"] = toolName
        return [
            "type": "user",
            "uuid": uuid,
            "timestamp": "2026-04-01T12:00:02Z",
            "isSynthetic": true,
            "sourceToolUseId": toolUseId,
            "toolUseResult": resultWithTool,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "is_error": isError,
                        "content": [
                            ["type": "tool_reference", "toolName": toolName],
                        ],
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
    }

    // MARK: - All Mock Messages

    private static let mockMessages: [[String: Any]] = {
        var msgs: [[String: Any]] = []
        var toolIdx = 0
        func nextToolId() -> String {
            toolIdx += 1
            return "tool_\(toolIdx)"
        }
        func nextUUID() -> String {
            toolIdx += 1
            return "uuid_\(toolIdx)"
        }

        // 1. User message
        msgs.append(userMessage(text: "帮我检查一下项目的代码质量", uuid: nextUUID()))

        // 2. Assistant with markdown text (code blocks, tables, etc.)
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("""
            好的，我来帮你检查。先看一下项目结构：

            ## 代码示例

            这是一段 TypeScript 代码：

            ```typescript
            interface Config {
              apiUrl: string;
              timeout: number;
              retries: number;
              headers: Record<string, string>;
            }

            export function createClient(config: Config): ApiClient {
              const { apiUrl, timeout, retries, headers } = config;
              return new ApiClient({ baseURL: apiUrl, timeout, retries, headers });
            }
            ```

            还有一段很长的 Bash 脚本：

            ```bash
            #!/bin/bash
            set -euo pipefail

            echo "=== Step 1: Clean ==="
            rm -rf build/ dist/ .cache/ node_modules/.cache/

            echo "=== Step 2: Install ==="
            npm ci --prefer-offline --no-audit

            echo "=== Step 3: Lint ==="
            npx eslint src/ --ext .ts,.tsx --max-warnings 0

            echo "=== Step 4: Type Check ==="
            npx tsc --noEmit --pretty

            echo "=== Step 5: Unit Tests ==="
            npx jest --coverage --ci --maxWorkers=4

            echo "=== Step 6: Build ==="
            npx webpack --mode production
            ```

            以及一个表格：

            | 指标 | 当前值 | 目标值 | 状态 |
            |------|--------|--------|------|
            | 测试覆盖率 | 78% | 80% | ⚠️ |
            | 类型覆盖率 | 95% | 90% | ✅ |
            | Lint 错误 | 0 | 0 | ✅ |
            | Bundle 大小 | 1.2MB | 1.5MB | ✅ |

            让我用工具来检查。
            """),
        ]))

        // 3. Assistant: Bash tool use
        let bashId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("先运行 lint 检查："),
            toolUseBlock(id: bashId, name: "Bash", input: [
                "command": "cd /Users/user/project && npx eslint src/ --ext .ts,.tsx --format compact 2>&1 | head -30",
                "description": "Run ESLint on the project",
            ]),
        ]))

        // Bash result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: bashId,
            toolName: "Bash",
            result: [
                "stdout": """
                /Users/user/project/src/utils/format.ts: line 12, col 5, Warning - Unexpected console statement (no-console)
                /Users/user/project/src/utils/format.ts: line 45, col 1, Warning - Missing return type on function (explicit-function-return-type)
                /Users/user/project/src/services/api.ts: line 23, col 10, Error - 'response' is defined but never used (no-unused-vars)
                /Users/user/project/src/services/api.ts: line 67, col 3, Warning - Unexpected any. Specify a different type (no-explicit-any)
                /Users/user/project/src/components/Header.tsx: line 8, col 15, Warning - React Hook useEffect has a missing dependency (react-hooks/exhaustive-deps)

                ✖ 5 problems (1 error, 4 warnings)
                """,
                "stderr": "",
            ]
        ))

        // 4. Assistant: Grep tool use
        let grepId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("发现一些问题。让我搜索未使用的变量："),
            toolUseBlock(id: grepId, name: "Grep", input: [
                "pattern": "is defined but never used",
                "path": "/Users/user/project/src",
                "glob": "*.ts",
            ]),
        ]))

        // Grep result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: grepId,
            toolName: "Grep",
            result: [
                "filenames": [
                    "/Users/user/project/src/services/api.ts",
                    "/Users/user/project/src/utils/helpers.ts",
                    "/Users/user/project/src/types/config.ts",
                ],
                "numMatches": 3,
                "numFiles": 3,
            ]
        ))

        // 5. Assistant: Glob tool use
        let globId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("看一下测试文件："),
            toolUseBlock(id: globId, name: "Glob", input: [
                "pattern": "**/*.test.ts",
                "path": "/Users/user/project/src",
            ]),
        ]))

        // Glob result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: globId,
            toolName: "Glob",
            result: [
                "filenames": [
                    "/Users/user/project/src/services/api.test.ts",
                    "/Users/user/project/src/utils/format.test.ts",
                    "/Users/user/project/src/utils/helpers.test.ts",
                    "/Users/user/project/src/components/Header.test.tsx",
                    "/Users/user/project/src/components/Footer.test.tsx",
                    "/Users/user/project/src/hooks/useAuth.test.ts",
                    "/Users/user/project/src/hooks/useTheme.test.ts",
                ],
                "numFiles": 7,
                "truncated": false,
            ]
        ))

        // 6. Assistant: Read tool use
        let readId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("读取有问题的文件："),
            toolUseBlock(id: readId, name: "Read", input: [
                "filePath": "/Users/user/project/src/services/api.ts",
            ]),
        ]))

        // Read result (Read blocks typically don't show expanded content)
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: readId,
            toolName: "Read",
            result: [:]
        ))

        // 7. Assistant: Edit tool use
        let editId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("修复未使用变量的问题："),
            toolUseBlock(id: editId, name: "Edit", input: [
                "filePath": "/Users/user/project/src/services/api.ts",
                "oldString": "const response = await fetch(url);",
                "newString": "const data = await fetch(url).then(r => r.json());",
            ]),
        ]))

        // Edit result with structuredPatch
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: editId,
            toolName: "Edit",
            result: [
                "filePath": "/Users/user/project/src/services/api.ts",
                "structuredPatch": [
                    [
                        "oldStart": 20,
                        "oldLines": 7,
                        "newStart": 20,
                        "newLines": 7,
                        "lines": [
                            " import { Config } from '../types/config';",
                            " ",
                            " export async function fetchData(url: string): Promise<Data> {",
                            "-  const response = await fetch(url);",
                            "+  const data = await fetch(url).then(r => r.json());",
                            "   const headers = new Headers();",
                            "   headers.set('Content-Type', 'application/json');",
                        ],
                    ] as [String: Any],
                ] as [[String: Any]],
            ]
        ))

        // 8. Assistant: Write tool use (new file)
        let writeId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("创建一个新的配置文件："),
            toolUseBlock(id: writeId, name: "Write", input: [
                "filePath": "/Users/user/project/src/config/defaults.ts",
                "content": """
                export const DEFAULT_CONFIG = {
                  apiUrl: 'https://api.example.com',
                  timeout: 5000,
                  retries: 3,
                  headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                  },
                } as const;

                export type AppConfig = typeof DEFAULT_CONFIG;
                """,
            ]),
        ]))

        // Write result with structuredPatch (existing file edit)
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: writeId,
            toolName: "Write",
            result: [
                "filePath": "/Users/user/project/src/config/defaults.ts",
                "content": """
                export const DEFAULT_CONFIG = {
                  apiUrl: 'https://api.example.com',
                  timeout: 5000,
                  retries: 3,
                  headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                  },
                } as const;

                export type AppConfig = typeof DEFAULT_CONFIG;
                """,
            ]
        ))

        // 9. Assistant: WebSearch tool use
        let webSearchId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("搜索最佳实践："),
            toolUseBlock(id: webSearchId, name: "WebSearch", input: [
                "query": "TypeScript ESLint best practices 2026",
            ]),
        ]))

        // WebSearch result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: webSearchId,
            toolName: "WebSearch",
            result: [
                "query": "TypeScript ESLint best practices 2026",
                "results": [
                    ["title": "TypeScript ESLint Configuration Guide", "url": "https://typescript-eslint.io/docs/"] as [String: Any],
                    ["title": "ESLint Best Practices for Large Projects", "url": "https://eslint.org/docs/latest/"] as [String: Any],
                ] as [[String: Any]],
            ]
        ))

        // 10. Assistant: WebFetch tool use
        let webFetchId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            toolUseBlock(id: webFetchId, name: "WebFetch", input: [
                "url": "https://api.example.com/v1/health",
            ]),
        ]))

        // WebFetch result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: webFetchId,
            toolName: "WebFetch",
            result: [
                "url": "https://api.example.com/v1/health",
                "code": 200,
                "codeText": "OK",
                "result": "{ \"status\": \"healthy\", \"version\": \"2.4.1\", \"uptime\": \"72h 15m\", \"services\": { \"database\": \"connected\", \"cache\": \"connected\", \"queue\": \"connected\" } }",
            ]
        ))

        // 11. Assistant: Bash error case
        let bashErrId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("运行测试："),
            toolUseBlock(id: bashErrId, name: "Bash", input: [
                "command": "cd /Users/user/project && npm test 2>&1",
                "description": "Run test suite",
            ]),
        ]))

        // Bash error result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: bashErrId,
            toolName: "Bash",
            result: [
                "stdout": "",
                "stderr": "FAIL src/services/api.test.ts\n  ● fetchData › should handle network errors\n    TypeError: Cannot read property 'json' of undefined\n      at fetchData (src/services/api.ts:23:45)\n      at Object.<anonymous> (src/services/api.test.ts:15:20)",
            ],
            isError: true
        ))

        // 12. Agent (Task) tool use
        let agentId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("让我启动一个 agent 来修复剩余问题："),
            toolUseBlock(id: agentId, name: "Task", input: [
                "description": "Fix remaining ESLint warnings",
                "prompt": "Fix all ESLint warnings in the project",
            ]),
        ]))

        // Agent task progress (system messages)
        msgs.append([
            "type": "system",
            "subtype": "task_progress",
            "uuid": nextUUID(),
            "toolUseId": agentId,
            "description": "Analyzing ESLint output",
            "lastToolName": "Bash",
            "usage": ["toolUses": 3, "durationMs": 2500],
        ] as [String: Any])

        msgs.append([
            "type": "system",
            "subtype": "task_progress",
            "uuid": nextUUID(),
            "toolUseId": agentId,
            "description": "Fixing no-console warnings in format.ts",
            "lastToolName": "Edit",
            "usage": ["toolUses": 5, "durationMs": 4200],
        ] as [String: Any])

        msgs.append([
            "type": "system",
            "subtype": "task_notification",
            "uuid": nextUUID(),
            "toolUseId": agentId,
            "status": "completed",
            "summary": "Fixed 4 ESLint warnings across 3 files",
            "usage": ["toolUses": 8, "durationMs": 6500, "totalTokens": 12000],
        ] as [String: Any])

        // Agent result
        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: agentId,
            toolName: "Task",
            result: [
                "description": "Fix remaining ESLint warnings",
                "status": "completed",
                "totalToolUseCount": 8,
                "totalDurationMs": 6500,
            ]
        ))

        // 13. Final summary
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("""
            ## 检查完成

            已完成以下修复：

            1. **未使用变量** — `api.ts` 中的 `response` 变量已重构
            2. **ESLint 警告** — Agent 已修复 4 个警告：
               - `no-console` (2处)
               - `explicit-function-return-type` (1处)
               - `no-explicit-any` (1处)
            3. **新增配置文件** — `config/defaults.ts` 提供类型安全的默认配置

            剩余 1 个测试失败需要手动修复，因为涉及 API 调用的 mock 逻辑变更。
            """),
        ]))

        // 14. Another user message
        msgs.append(userMessage(text: "谢谢！测试那个我自己来修。另外帮我看看 diff 的长内容展示效果", uuid: nextUUID()))

        // 15. Long diff
        let longEditId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("好的，这是一个较大的重构："),
            toolUseBlock(id: longEditId, name: "Edit", input: [
                "filePath": "/Users/user/project/src/services/api.ts",
                "oldString": "// old code",
                "newString": "// new code",
            ]),
        ]))

        // Long edit result
        let longDiffLines: [String] = {
            var lines: [String] = []
            for i in 1...40 {
                lines.append("-  export const config\(i) = { name: 'item\(i)', value: \(i), enabled: true };")
                lines.append("+  export const config\(i) = { name: 'item\(i)', value: \(i * 10), enabled: \(i % 3 != 0), priority: \(i % 5) };")
                lines.append(" ")
            }
            return lines
        }()

        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: longEditId,
            toolName: "Edit",
            result: [
                "filePath": "/Users/user/project/src/services/api.ts",
                "structuredPatch": [
                    [
                        "oldStart": 1,
                        "oldLines": 40,
                        "newStart": 1,
                        "newLines": 40,
                        "lines": longDiffLines,
                    ] as [String: Any],
                ] as [[String: Any]],
            ]
        ))

        // 16. Long bash output
        let longBashId = nextToolId()
        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            toolUseBlock(id: longBashId, name: "Bash", input: [
                "command": "find /Users/user/project/src -name '*.ts' -exec wc -l {} + | sort -rn | head -50",
                "description": "Count lines in all TypeScript files",
            ]),
        ]))

        let longBashOutput: String = {
            var lines: [String] = []
            for i in (1...50).reversed() {
                lines.append("  \(i * 47 + Int.random(in: 0...100))  /Users/user/project/src/\(["services", "components", "utils", "hooks", "types"].randomElement()!)/\(["api", "format", "helpers", "auth", "config", "Header", "Footer", "Modal", "Table", "List"].randomElement()!)\(i > 10 ? "\(i)" : "").ts")
            }
            lines.append("  12847  total")
            return lines.joined(separator: "\n")
        }()

        msgs.append(toolResultMessage(
            uuid: nextUUID(),
            toolUseId: longBashId,
            toolName: "Bash",
            result: [
                "stdout": longBashOutput,
                "stderr": "",
            ]
        ))

        msgs.append(assistantMessage(uuid: nextUUID(), content: [
            textBlock("以上就是所有组件的展示效果。"),
        ]))

        return msgs
    }()
}

#endif

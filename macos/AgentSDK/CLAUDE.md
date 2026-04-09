# AgentSDK

Swift Package，为 ccterm macOS 客户端提供与 Claude Code CLI 的 stdio 通信层。

## 定位

- **做什么**：封装 CLI 子进程的启动、JSONL 消息解析、control request/response 协议、权限/Hook/MCP/Elicitation 回调处理
- **不做什么**：不实现 Python SDK 的便利层（`query()` 简单 API、`@tool` 自定义工具装饰器、session 文件管理、Transport 抽象）。这些由 ccterm app 层按需实现
- **参考对齐**：[claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) 的 CLI 协议和类型定义

## 项目结构

```
Sources/AgentSDK/
├── AgentSDK.swift              # Session 类：子进程管理、消息路由、control request
├── AgentSDKError.swift         # 错误类型
├── MessageParser.swift         # 类型分派（~80 行），不含字段解析逻辑
├── Macros.swift                # @JSONMapped / @JSON macro 声明
├── JSONParseError.swift        # JSON 解析错误类型
├── Process/
│   ├── BinaryLocator.swift
│   └── ShellEnvironment.swift
└── Types/
    ├── ContentBlock.swift      # @JSONMapped：TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock
    ├── Message.swift           # @JSONMapped：所有消息类型 struct + Message enum
    ├── ToolInput.swift         # @JSONMapped：ToolInput enum + 每个工具的 input struct
    ├── SessionConfiguration.swift
    ├── SessionResult.swift
    ├── Requests.swift
    ├── PermissionDecision.swift
    ├── PermissionMode.swift
    ├── HookResult.swift
    ├── MCPResponse.swift
    └── ElicitationResult.swift

Sources/AgentSDKMacros/
└── JSONMappedMacro.swift       # @JSONMapped macro 实现（SwiftSyntax）

Sources/TypeValidator/
├── main.swift                  # 入口
├── SourceAnalyzer.swift        # SwiftSyntax 读 @JSON 标注
├── JSONLScanner.swift          # JSONL 扫描
└── Report.swift                # 报告输出
```

## 编译

AgentSDK 作为 ccterm 的本地 Swift Package 依赖，在项目根目录执行 `make build` 时自动编译。

## 核心用法

```swift
let config = SessionConfiguration(workingDirectory: projectURL)
let session = Session(configuration: config)

// 类型化消息回调（推荐）
session.onMessage = { message in
    switch message {
    case .assistant(let msg):
        for block in msg.content {
            if case .text(let t) = block { print(t.text) }
            if case .toolUse(let t) = block {
                switch t.input {
                case .bash(let bash): print("Running: \(bash.command)")
                case .read(let read): print("Reading: \(read.filePath)")
                default: break
                }
            }
        }
    case .result(let r):
        print("Done: \(r.isSuccess)")
    default: break
    }
}

// 权限回调
session.onPermissionRequest = { request in
    return .allow()
}

try session.start()
session.sendMessage("Fix the bug")
```

## @JSONMapped Macro

数据模型 struct 使用 `@JSONMapped` macro 自动生成 `init(json: [String: Any]) throws` 解析器。

### 基本用法

```swift
@JSONMapped
public struct BashInput {
    @JSON("command") public let command: String            // 必填 String
    @JSON("description") public let description: String?   // 可选 String
    @JSON("timeout") public let timeout: Int?              // 可选 Int（NSNumber 安全解析）
    @JSON("run_in_background") public let runInBackground: Bool?
}
```

- `@JSON("key")` 指定该属性对应的 JSON key
- 省略 `@JSON` 时，默认使用 Swift 属性名作为 JSON key
- Optional 类型生成 `as?` 安全解析，非 optional 类型生成 guard + throw
- `Int` / `Int?` 使用 NSNumber 路径，避免 JSONSerialization 的 Bool/Int 歧义

### 嵌套 struct

嵌套的 `@JSONMapped` struct 自动递归解析：
```swift
@JSONMapped
public struct RateLimitEvent {
    @JSON("rate_limit_info") public let rateLimitInfo: RateLimitInfo    // RateLimitInfo 也是 @JSONMapped
}
```

### 不适用 macro 的场景

以下类型不使用 `@JSONMapped`，因为其 JSON 结构需要特殊分派逻辑：
- `UserMessage` / `AssistantMessage`：嵌套 `message` 层 + content 多态
- `ContentBlock` enum：需要按 `type` 字段分派
- `ToolInput` enum：需要按 `name` 字段分派
- `Message` enum：需要按 `type` + `subtype` 分派

这些类型的解析逻辑保留在 `MessageParser.swift` 中。

## TypeValidator

TypeValidator 扫描 `~/.claude` 下的 JSONL 文件，用 SwiftSyntax 直接读取 `Types/*.swift` 中的 `@JSON` 标注，对比 struct 字段与实际 JSON 数据的差异。

```bash
./scripts/run_type_validator.sh   # build + run
```

**新增/修改 struct 字段时**：在 struct 属性上加 `@JSON("key")` 标注。TypeValidator 自动识别，无需额外配置。

**新增工具 input struct 时**：
1. 在 `Types/ToolInput.swift` 中新增 `@JSONMapped` struct
2. 在 `ToolInput` enum 中添加 case 和 `parse` 分派
3. 在 `Sources/TypeValidator/main.swift` 的 `toolInputStructNames` 中注册映射
4. 运行 TypeValidator 验证

## 代码规范

遵循上层 ccterm 项目的 CLAUDE.md 规范（MVC-C 架构、纯代码布局、Swift API Design Guidelines）。本包作为 Model/Service 层，不涉及 UI。

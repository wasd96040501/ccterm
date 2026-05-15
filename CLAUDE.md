# CCTerm 代码规范

## 架构

纯 SwiftUI + AppKit 架构，最低部署目标 macOS 14（Sonoma）。聊天 transcript 用 `NSTableView` 自绘渲染，其他 UI 走 SwiftUI；通过 `NSViewRepresentable` 桥接。

入口：`@main CCTermApp` → `Window` scene → `RootView2`（`NavigationSplitView`）→ `SidebarView2` + Detail。`RootView2` 本地持有 `selectedSessionId` / `draftSessionId`，不走全局路由。

- **Model**：纯数据结构，`struct` 优先，`Codable` 协议
- **View**：SwiftUI View struct，声明式 UI
- **Service**：`@Observable`，通过 init 注入或 `.environment()` 注入
- **AppState**：极薄全局容器，只持 `SessionManager2` 和 `SyntaxHighlightEngine`，通过 `.environment()` 注入

不使用 XIB / Storyboard / NSHostingController。需要 AppKit 能力时通过 `NSViewRepresentable` 桥接（参考 `NativeTranscript2View`、`InputTextView`）。

### SwiftUI 规范

**状态管理：**
- `@Observable` 持有跨视图的可观察状态（典型：`SessionHandle2`）
- `@State`：View 私有 UI 状态；`@Binding`：父传子可写引用
- Service 通过 init 或 `.environment()` 注入，View 不自行创建 Service
- 通用 SwiftUI 组件放在 `Components/` 目录

**View 编写：**
- body 超 40 行应拆分——有独立状态的提取为子 View struct，纯布局的提取为计算属性或 `@ViewBuilder` 方法
- 有独立状态的子 View 提取为独立文件；无状态的辅助类型（Context、小 enum）可留在主文件中。通用 ViewModifier / 通用组件放 `Components/`
- 禁止在 body 中做昂贵计算；长列表用 NativeTranscript2 而不是 `List` / `LazyVStack`
- `ForEach` 的 `id` 必须稳定
- 数据加载用 `.task { }`，依赖变化用 `.task(id:)` / `.onChange(of:)`，禁止在 body 构建路径中触发副作用

## Chat 架构

聊天界面没有 ViewModel — `RootView2` 是唯一的协调点，下面三块互不知道彼此：

| 组件 | 类型 | 数量 | 职责 |
|------|------|------|------|
| RootView2 | View | 1 | 本地持有 selection / draft sessionId，组合 Sidebar + transcript + input bar |
| SidebarView2 | View | 1 | 读 `SessionManager2.records` 渲染历史会话列表，通过 `@Binding` 回写选中 sessionId |
| ChatHistoryView | View | per-session（`.id(sessionId)`） | 拿 `SessionHandle2`，挂 `Transcript2EntryBridge`，触发 `loadHistory()`，渲染 `NativeTranscript2View` |
| InputBarView2 | View | per-session | 纯 UI（文本框 + send/stop 按钮）；`onSubmit` / `onStop` / `isRunning` 由调用方注入 |
| LoadingPillView2 | View | per-session | running 态指示 pill，浮在 InputBar 左上 |

### 持有关系

```
AppState
├── sessionManager2: SessionManager2 (env)
│   └── handles: [String: SessionHandle2]
└── syntaxEngine: SyntaxHighlightEngine (env)

RootView2
├── @State selectedSessionId, draftSessionId
└── @Environment SessionManager2
    │
    ├── SidebarView2 (selection: $selectedSessionId)
    └── Detail:
        ├── ChatHistoryView(sessionId)
        │   ├── manager.prepareDraft(sessionId) → SessionHandle2
        │   ├── Transcript2Controller + Transcript2EntryBridge.attach(handle)
        │   └── NativeTranscript2View(controller)
        └── InputBarChrome
            ├── LoadingPillView2  (handle.isRunning)
            └── InputBarView2 (onSubmit → handle.send / onStop → handle.interrupt)
```

### 数据流

- **历史加载**：ChatHistoryView 进入 → `manager.prepareDraft(sessionId)` 拿 handle → 绑 `Transcript2EntryBridge` → `handle.loadHistory()` → bridge 把 `TimelineMutation` 翻译成 controller 的 `loadInitial` / `apply` 调用 → NativeTranscript2 diff-render
- **运行态渲染**：`SessionHandle2.isRunning` (`@Observable`) → SwiftUI 自动追踪 → LoadingPillView2 fade、InputBarView2 send↔stop 切换
- **消息推送**：CLI 推消息 → `SessionHandle2.receive` → 更新 `messages` / 推 `onTimelineMutation` → bridge → controller 增量 reload
- **Session 切换**：SidebarView2 onSelect → `selectedSessionId` 变化 → `ChatHistoryView` 的 `.id(sid)` 触发重建，`@State` reset
- **草稿启动**：进入 NewSession tab 时 `RootView2` 懒分配 `draftSessionId`；用户首条消息 → `handle.setCwd(home)` + `handle.send(text)` → 启动后 `manager.refreshRecords()` 并把选中切到具体 sessionId

### 规范

- 禁止在 View 中直接修改 session 的 running / status / messages，必须通过 `SessionHandle2` 方法
- UI 层只读取 handle 上的 `@Observable` 属性，不维护副本
- 新增 session 运行时状态：在 SessionHandle2 加 `@Observable` 字段 → View 直读
- 跨 view 协调通过 `RootView2` 闭包注入（如 InputBarChrome 的 `onSubmit` / `onBarRect`），不引入新的 ViewModel 层

## Session 运行时状态

`SessionHandle2`（`@Observable @MainActor`，`Services/Session/SessionHandle2/`）是单个会话的运行时句柄。多文件分片：

| 文件 | 职责 |
|------|------|
| `SessionHandle2.swift` | 类定义、observable 属性、init |
| `SessionHandle2+Start.swift` | `activate` / `stop` / `send` / bootstrap |
| `SessionHandle2+Messaging.swift` | `interrupt` 等命令 |
| `SessionHandle2+Configuration.swift` | `setCwd` / `setWorktree` / `setModel` 等本地配置 |
| `SessionHandle2+History.swift` | `loadHistory` / JSONL 回放 |
| `SessionHandle2+Receive.swift` | CLI 推送消息的处理路径 |
| `SessionHandle2+Types.swift` | `PendingPermission` / `SlashCommand` 类型 |
| `MessageEntry.swift` | 渲染就绪的消息条目（含 `SingleEntry` / `GroupEntry`） |
| `TranscriptSnapshot.swift` + `TimelineMutation` | 视图层意图枚举与 bridge 信号 |
| `SessionManager2.swift` | `SessionHandle2` 注册表，按 sessionId 懒创建 + 缓存 |

### Observe vs Mutation

| 机制 | 用途 | 消费方式 |
|------|------|----------|
| **Observable 属性** | 连续状态（messages、isRunning、historyLoadState、pendingPermissions） | SwiftUI 自动追踪 / computed 直读 |
| **`onTimelineMutation` 闭包** | 离散 timeline 变更信号（`.reset` / `.append` / `.update`） | `Transcript2EntryBridge.attach(handle)` 内部消费，翻译成 controller 命令 |

**规范：**
- 禁止在 View 中缓存 handle 属性副本作为状态来源 — 通过 computed / 直读
- 本地操作（`send` / `interrupt` / `setPermissionMode`）只发起 stdin 请求或本地状态过渡，不绕过 handle 直写 observable
- 新增运行时状态字段：在 SessionHandle2 加 `@Observable` 属性 → View 直读
- 禁止用 `.onChange` 监听 handle 属性来触发副作用，改用 `onTimelineMutation` 或 handle 上现成的内部钩子
- 新增消息变更类型：在 `TimelineMutation` 加 case → SessionHandle2 相应位置 emit → `Transcript2EntryBridge` 加分支

## 工具渲染（NativeTranscript2）

聊天 transcript 走 `NSTableView` + Core Text 自绘，源码在 `Content/Chat/NativeTranscript2/`，bridge 在 `Content/Chat/NativeTranscript2Bridge/`。详见 `Content/Chat/NativeTranscript2/CLAUDE.md`。

数据流：

```
MessageEntry  →  Transcript2EntryBridge  →  [Block]
                                              ↓
                                      Transcript2Controller
                                              ↓
                                  NativeTranscript2View (NSTableView)
                                              ↓
                                       BlockCellView (override draw(_:))
```

- `MessageEntryBlockBuilder` / `ToolUseToChild` 把 assistant `tool_use` block 与对应 `tool_result` 关联，产出渲染就绪的 `Block.toolGroup(ToolGroupBlock)`
- Tool group 内的 child（Bash / FileEdit / WebFetch 等）每种都有独立的 `Layout` + `Highlight` 文件，集中在 `Content/Chat/NativeTranscript2/Layout/ToolGroupChildren/`
- 折叠 / 展开状态走 `Coordinator.foldStates: [UUID: Bool]`，**不**进 `Block.Kind`
- Tool runtime status 走 `Coordinator.statusStates: [UUID: ToolStatus]`，`Transcript2Controller.setToolStatus(...)` 单行 reload，不重组 Block

新增 tool 渲染：在 `Layout/ToolGroupChildren/<Name>/` 下加 `<Name>Child.swift` + `<Name>ChildLayout.swift`（必要时 `<Name>ChildHighlight.swift`），在 `ToolGroupChildLayout.swift` 派发分支注册。

## 日志

使用 `appLog()`（`Services/Logging/AppLogger.swift`）统一日志。禁止直接使用 `NSLog` / `print`。

**调用方式：** `appLog(.info, "SessionHandle2", "send() queued — status=\(status)")`

| Level | 用途 |
|-------|------|
| `.debug` | 开发调试，仅定位特定问题时有用 |
| `.info` | 正常流程事件（session 启停、导航、状态切换） |
| `.warning` | 可恢复的异常 |
| `.error` | 影响功能的失败 |

**规范：**
- category 使用类名（不含模块前缀），如 `"SessionHandle2"`、`"ChatHistoryView"`
- 禁止在日志中输出敏感信息（token、密码、API key）
- 日志窗口：Window → Logs（Cmd+Shift+L）
- 底层同时写入 `os.Logger`，可通过 Console.app 查看历史日志

## 目录结构

```
ccterm/
├── macos/                    # macOS 平台
│   ├── ccterm.xcodeproj/
│   ├── ccterm/               # 应用源码
│   │   ├── App/              # CCTermApp, AppState, RootView2
│   │   ├── Sidebar/          # SidebarView2
│   │   ├── Components/       # 通用 SwiftUI / AppKit 组件
│   │   │   └── Markdown/     # GFM parse → 内部 IR（NativeTranscript2 复用）
│   │   ├── Content/          # 主内容区各页面
│   │   │   ├── Chat/         # ChatHistoryView / InputBarView2 / LoadingPillView2
│   │   │   │   ├── NativeTranscript2/        # NSTableView 自绘 transcript
│   │   │   │   └── NativeTranscript2Bridge/  # MessageEntry → Block 翻译
│   │   │   ├── TranscriptDemo/   # 离线 demo 与压测 tab
│   │   │   ├── Settings/         # 应用设置
│   │   │   └── LogViewer/        # 日志窗口
│   │   ├── Models/           # 数据模型（SyntaxToken、PermissionMode 等）
│   │   ├── Services/         # 服务层
│   │   │   ├── Session/      # SessionHandle2 / SessionManager2 / SessionRepository / Worktree
│   │   │   └── Logging/      # AppLogger / MainThreadWatchdog
│   │   ├── Extensions/       # Foundation / AppKit 通用扩展
│   │   └── Resources/        # Assets.xcassets, 其他资源文件
│   ├── AgentSDK/             # Swift SDK 包
│   ├── Config.xcconfig
│   └── scripts/              # build.sh
├── thirdparty/
│   └── fzf/                  # git submodule
└── Makefile                  # 统一构建入口
```

按功能模块组织，不按文件类型组织。新增功能模块时创建对应目录。

Xcode 项目使用文件夹同步（`PBXFileSystemSynchronizedRootGroup`），文件系统中新增 / 删除 / 移动文件会自动反映到构建中。不需要手动编辑 `project.pbxproj` 来添加文件引用。

## 国际化（i18n）

使用 Xcode String Catalog（`Localizable.xcstrings`），英文为 source language，zh-Hans 为翻译语言。系统 locale 自动切换，兜底英文。

**判断规则——哪些字符串需要本地化：**

| 需要本地化 | 不需要本地化 |
|-----------|------------|
| 用户可见的 UI 文案（按钮、标题、提示、占位符、菜单项、空状态、确认对话框） | 日志、断言消息、内部标识符 |
| 用户可见的枚举 display name（如 `PermissionMode.title`） | 传给 CLI/API 的 rawValue、key |
| NSOpenPanel.message、.help() tooltip | 代码注释、Preview 标题 |

**怎么写——按上下文选 API：**

| 上下文 | 写法 | 说明 |
|--------|------|------|
| SwiftUI 字面量：`Text("…")`、`Button("…")`、`Label("…", systemImage:)`、`.navigationTitle("…")`、`.confirmationDialog("…")` | 直接写英文字面量 | 编译器推断为 `LocalizedStringKey`，自动查 String Catalog |
| 返回 `String` 的 computed property / 传给 `String` 参数的调用点 | `String(localized: "…")` | 如 `PermissionMode.title` |
| 带插值 | `String(localized: "\(count) items")` | xcstrings key 自动变为 `"%lld items"` |
| 条件表达式传给 String 参数 | 两侧都 wrap | `state.isTempDir ? String(localized: "Temporary Session") : path` |

**key 规范：**
- key = 英文原文，不用 snake_case ID
- 首字母大写用于标题/按钮（"New Conversation"），小写用于句子/描述（"Select primary directory and additional directories"）

**新增字符串流程：**
1. 代码中用英文 key（按上表选 API）
2. 在 `Localizable.xcstrings` 中添加 key + zh-Hans 翻译
3. 两步必须同时完成，禁止只加代码不加翻译

## 命名

遵循 Swift API Design Guidelines，项目额外约定：View / Service / Delegate / Coordinator 后缀，数据模型无后缀。

## 前置依赖

- **macOS 14（Sonoma）** 或更高版本
- **Xcode**：安装后首次使用需运行 `xcodebuild -runFirstLaunch` 初始化命令行工具
- **Go**：`thirdparty/fzf` submodule 在 Xcode build phase 里从 Go 源码编译出 `fzf` binary。装 `brew install go` 或 <https://go.dev/dl/>
- **Git submodules**：首次 `make build` 会自动初始化（fzf），也可手动 `git submodule update --init --recursive`

## 构建

统一走 `make`，不要直接调 `macos/scripts/*.sh`。

```bash
make build                                  # 构建 ccterm（Debug）
make release                                # 构建 ccterm（Release）
make clean                                  # 清理所有构建产物
make fmt                                    # 格式化代码（xcstrings 等）
```

- 提交 PR 之前必须执行 `make fmt`，确保格式一致
- 脚本（`macos/scripts/*.sh`）已经通过 `excludedCommands` 配置了 sandbox 豁免，直接通过 make 调用即可，不需要 `dangerouslyDisableSandbox`
- `make build` 的终端输出仅包含成功 / 失败和两个日志路径（full log + summary）。构建失败时先读 summary 文件诊断，不要 `tail` / `cat` full log。summary 不够时再读 full log

## 测试

本项目用 XCUITest 做端到端 UI 测试，不维护 unit test（`cctermTests/` 只放占位文件）。

**默认走 GitHub PR 跑 CI，不要本地跑**——UI test 会唤起 ccterm.app 抢用户焦点、操控键盘鼠标，本地跑会打扰你正在用的桌面。push PR 后 `ui-test` workflow（`.github/workflows/test.yml`）自动跑全量,日志和 xcresult artifact 都在 Actions 页面。

只有在 CI 反映出问题需要本地复现、或者你正在专门 debug UI test 本身时，再用 `make test FILTER=...` 在本地针对性跑。**严禁默认全量本地跑**——单测试 10-30s，全量很慢。

```bash
# 本地复现单个用例
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState

# 本地复现 class 内所有方法
make test FILTER=InputBar2StopButtonUITests

# 本地全量(只在 PR 合并前临门一脚自验时)
make test-all
```

**输出格式（渐进式）：**
- 成功：一行结果 + xcresult 路径，结束。
- 失败：先打"失败 case + 关键 assertion + crash 报告路径"等核心信息，再列 `summary` / `full log` / `xcresult` 三个 detail 文件路径。LLM 想看细节自己 Read 那些文件，不要 `tail` / `cat` 全 log。
- xcresult bundle 含 screenshots 和 video，定位"按钮没出现"这类问题最直接。Finder 打开或 `open /tmp/ccterm-test-.../result.xcresult` 自动用 Xcode 加载。
- crash log（macOS DiagnosticReports）会在测试结束后被自动扫描并列在输出里 — 进程崩了不会只表现为 "test failed" 而藏掉根因。

**UI test 隔离基建（DEBUG only）：** 测试通过 `launchEnvironment` 切到隔离模式 —— 不污染主 CoreData store，不依赖真 Claude CLI。

- `CCTERM_TEST_MODE=1` → `AppState` 切到 `InMemorySessionRepository`（永远不写 `CDSessionRecord`），并把 `SessionHandle2.mockCLIOverride` 装好。
- `CCTERM_MOCK_CLI_SCENARIO=<name>` → 选用 `MockCLIRegistry` 里的 scenario。后续 `ensureStarted` spawn 的 CLI 子进程实际是当前 ccterm 二进制（`AppEntryPoint` 在 `CCTERM_RUN_AS_MOCK_CLI=1` 时转发到 `MockCLIRunner`），跑指定 scenario，通过 stdin/stdout JSONL 与父进程交互——协议与真 Claude CLI 一致。
- 新增测试时**不**加 launch arg / 不加 `forceXxxForTest()` 方法。要触发某种 CLI 行为（hang turn / refuse permission / stream chunks）就**写一个 scenario**实现 `MockCLIScenario` 协议并在 `MockCLIRegistry` 注册。详见 [cctermUITests/CLAUDE.md](macos/cctermUITests/CLAUDE.md)。
- 需要交互的 SwiftUI 控件加 `.accessibilityIdentifier("ComponentName.ElementName")`（约定 `<View>.<Role>`，如 `InputBar2.SendButton`）。**加在子元素上**，不要加在外层容器（SwiftUI 容器 id 传染覆盖子元素的 id）。
- NSViewRepresentable 包的 NSTextView 无法直接 a11y query — 点击外层容器让焦点落到 NSTextView，再 `app.typeText(...)`。
- 一条测试只验证一条 invariant，不串多个 user journey。

## PR 规范

PR title 和 body 一律用英文。

## Worktree 规范

在 worktree 中工作时，默认读取和操作 worktree 路径下的文件。不要读取主仓库目录的文件，除非用户主动要求。

## 脚本执行

临时 Bash / Python / JavaScript 脚本超过 **5 行**时，**必须**先写入文件再执行（写入项目根目录或 `/tmp`，命名如 `tmp_analyze.py`），执行后删除。禁止在命令行中内联长脚本。

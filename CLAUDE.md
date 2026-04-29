# CCTerm 代码规范

## 架构

纯 SwiftUI 架构，最低部署目标 macOS 14（Sonoma）。

入口：`@main CCTermApp` → `Window` scene → `RootView`（`NavigationSplitView`）→ Sidebar + Content。

- **Model**: 纯数据结构，`struct` 优先，`Codable` 协议
- **View**: SwiftUI View struct，声明式 UI
- **ViewModel**: `@Observable` 类，持有页面状态和业务逻辑
- **AppState**: `@Observable` 全局状态容器，持有 Services、ChatRouter 和 ViewModels，通过 `.environment()` 注入

不使用 XIB / Storyboard / NSHostingController。需要 AppKit 能力时通过 `NSViewRepresentable` 桥接。

### SwiftUI 规范

**状态管理：**
- MVVM：`@Observable` ViewModel 持有页面状态和业务逻辑，View 只负责声明式渲染和用户交互回调
- `@State`：View 私有 UI 状态；`@Binding`：父传子可写引用
- Service 通过 init 注入，View 不自行创建 Service
- 通用 SwiftUI 组件放在 `Components/` 目录

**View 编写：**
- body 超 40 行应拆分——有独立状态的提取为子 View struct，纯布局的提取为计算属性或 `@ViewBuilder` 方法
- 有独立状态的子 View 提取为独立文件；无状态的辅助类型（Context、小 enum）可留在主文件中。通用 ViewModifier / 通用组件放 `Components/`
- 禁止在 body 中做昂贵计算；长列表用 `List` / `LazyVStack`；`ForEach` 的 `id` 必须稳定
- 数据加载用 `.task { }`，依赖变化用 `.task(id:)` / `.onChange(of:)`，禁止在 body 构建路径中触发副作用

## Swift↔React Bridge

聊天渲染使用 WKWebView 内嵌 React（源码在 `web/`）。双端通过 `WebViewBridge` 通信。

| 层 | 职责 |
|----|------|
| Swift (SessionHandle + MessageFilter) | 数据处理：AgentSDK 消息解析、会话状态管理、生成渲染就绪的 ChatMessage |
| Bridge (WebViewBridge + bridge.ts) | 传输：callAsyncJavaScript + JSON 双向传递，不含业务逻辑 |
| React | 纯渲染：收到 string 就渲染，不做数据处理 |

**通信方向：**
- Swift → React：`callAsyncJavaScript` 调用 `window.__bridge(type, json)`，JSON string 作为参数
- React → Swift：`window.webkit.messageHandlers.bridge.postMessage(event)`，JSON 对象

**类型定义：**
- Swift + React：消息类型（Message2 enum, Message2User, Message2Assistant）由 schema 自动生成至 `AgentSDK/Sources/AgentSDK/Generated/` 和 `web/src/generated/types.generated.ts`
- Bridge 类型：Swift `Services/WebViewBridge.swift` + React `types/bridge.ts`
- 修改共享类型时**必须同步更新两侧**（自动生成的类型修改 schema 即可）

**规范：**
- 消息用 enum（Swift）/ discriminated union（TS）区分 user/assistant，不用 role 字段
- 禁止手工拼接 JS 字符串或转义，必须用 callAsyncJavaScript 传递 JSON 参数
- 禁止在 React 侧暴露 store 函数到 window，外部入口统一通过 bridge.ts
- React 不做数据处理，Swift 预处理文本，React 收到 string 直接渲染
- 新增 Swift→React 交互：Bridge 加 typed 方法 + React 侧 onNativeEvent 加分支

## Chat 架构

Chat 模块采用 ChatRouter + per-session InputBarViewModel 架构。InputBarViewModel 持有 3 个子 ViewModel（InputViewModel / PermissionViewModel / PlanReviewViewModel），对应 InputBar 的 3 个互斥 UI 模式。

### 核心实体

| 实体 | 类型 | 数量 | 职责 |
|------|------|------|------|
| ChatRouter | @Observable | 1 | session 生命周期路由和协调：切换 session、消息提交路由（新建/恢复/直发）、per-session ViewModel 缓存管理。不持有 UI 状态 |
| InputBarViewModel | @Observable | N（per-session） | InputBar 路由层：桥接 handle 运行时状态，持有子 VM，处理模式路由和事件分发。`onSend` 闭包由 ChatRouter 创建时注入 |
| InputViewModel | @Observable | N（per-session） | 文本输入/补全/draft 管理 |
| PermissionViewModel | @Observable | N（per-session） | 权限卡片列表管理 |
| PlanReviewViewModel | @Observable | N（per-session） | Plan 评论/搜索/执行 |
| CompletionViewModel | @Observable | N（per-session） | 补全列表状态管理（InputViewModel 持有） |

### 持有关系

```
AppState
├── sessionService: SessionService
│   └── handles: [String: SessionHandle] ×N
│       ├── agentSession: AgentSDK.Session?
│       └── bridge: WebViewBridge?（创建时绑定，归档/删除时解绑，stop 不动）
├── sidebarViewModel: SidebarViewModel
│   └── 依赖: sessionService（观察 allHandles，自驱动 rebuild）
│   └── ❌ 不认识 ChatRouter，不持有选中状态
├── chatRouter: ChatRouter
│   ├── currentViewModel: InputBarViewModel（当前活跃实例）
│   ├── viewModels: [String: InputBarViewModel]（per-session 缓存）
│   ├── chatContentView: ChatContentView
│   │   └── bridge: WebViewBridge
│   └── 依赖: sessionService
└── todoSessionCoordinator: TodoSessionCoordinator

InputBarViewModel
├── inputVM: InputViewModel
│   └── completionVM: CompletionViewModel
├── permissionVM: PermissionViewModel
└── planReviewVM: PlanReviewViewModel
```

### 数据流

- **状态渲染**：SessionHandle.status 变化 → InputBarViewModel.barState（computed 直读）→ SwiftUI 自动追踪 → InputBar 重渲染。无手动 observation，无逐字段拷贝
- **消息推送**：所有 handle（包括后台）实时推送消息到 bridge → React 按 conversationId 分存
- **Session 切换**：SidebarView onSelect → chatRouter.activateSession(id) → 整体替换 currentViewModel 实例 → bridge.switchConversation(id)。选中状态 source of truth 是 `chatRouter.currentViewModel.sessionId`
- **消息提交**：InputBarView → viewModel.handleCommandReturn() → InputBarViewModel 内部按模式路由 → onSend 闭包（ChatRouter 注入）→ ChatRouter.submitMessage 路由

### UI 层胶水

RootView 是唯一同时知道 SidebarViewModel 和 ChatRouter 的地方。SidebarView 通过 `selection` 参数只读获取当前选中 ID，通过 `onSelect` / `onArchive` 闭包回调 ChatRouter。ChatView 只依赖 ChatRouter。

### 规范

- 禁止在 View/ViewModel 中直接修改 session 的 processing/interrupting 状态，必须通过 SessionHandle 方法触发
- UI 层只读取和映射状态，不维护独立的 session 状态
- InputBar 的操作（interrupt、selectModel、queueMessage 等）直调 `viewModel.method()`，`onSend` 在 InputBarViewModel 内部闭环（由 ChatRouter 注入）
- 需要 ChatRouter 协调的操作通过 `onRouterAction` 回调传递 `ChatRouterAction` enum，不用瞬态属性 + `.onChange` 中转
- 新增 session 运行时状态：在 SessionHandle 加字段 → InputBarViewModel 加 computed 直读（SwiftUI 自动追踪）
- 子 ViewModel 之间零交互，跨模式协调通过 InputBarViewModel 的 init 注入闭包完成
- View 接收 ViewModel 参数一律命名为 `viewModel`，子 VM 数据通过属性路径访问（如 `viewModel.inputVM.text`）

## Session 运行时状态

`SessionHandle`（`@Observable`，定义在 `Services/Session/SessionHandle.swift`）是单个会话的运行时句柄，持有可观察状态和交互命令。

`SessionService`（定义在 `Services/Session/SessionService.swift`）管理 SessionHandle 的生命周期（创建/缓存/start/stop/remove），是 handles 字典的 owner。

### Observe vs Event

SessionHandle 的对外接口严格区分两种机制：

| 机制 | 用途 | 消费方式 | 示例 |
|------|------|----------|------|
| **Observe**（`@Observable` 属性） | 连续状态 → 驱动 UI 渲染 | SwiftUI 自动追踪 / computed 直读 | status、branch、contextUsedTokens、pendingPermissions |
| **Event**（`SessionEvent` + `AsyncStream`） | 离散事件 → 触发副作用 | ViewModel `Task { for await event in handle.eventStream() }` | statusChanged、permissionsChanged、processExited |

**判断标准：** 如果消费者需要「当前值是什么」→ Observe；如果消费者需要「刚刚发生了什么」→ Event。

**规范：**
- 禁止在 View/ViewModel 中缓存 SessionHandle 属性副本作为状态来源，通过 computed 直读 handle 属性
- 本地操作（send/interrupt/setPermissionMode）只写 stdin 请求 CLI 变更，不直接改 observable 值
- 新增运行时状态字段：在 SessionHandle 加 `@Observable` 属性 → InputBarViewModel 加 computed 直读
- 禁止用 View `.onChange` 监听 handle 属性变化来触发副作用，改用 ViewModel 订阅 `handle.eventStream()`
- 新增事件类型：在 `SessionEvent` 加 case → SessionHandle 相应位置 `emit()` → 消费者 `handleEvent()` 加分支

## 工具渲染

ChatMessage union 包含工具渲染消息。工具消息由 Swift 侧预处理：

- `MessageFilter`（`Services/Session/MessageFilter.swift`）负责消息过滤和渲染数据生成（纯函数，live/replay 共用）
- assistant 消息中的 tool_use blocks 与 user 消息的 tool_result 通过 `tool_use_id` 关联，解析后生成渲染就绪的 ChatMessage
- React 收到完整的渲染就绪数据，不做关联或解析
- 新增工具组件的展开/折叠必须使用 `CollapsibleMotion` 组件（`web/src/components/CollapsibleMotion/`），不自行实现动画

## 日志

使用 `appLog()`（`Services/Logging/AppLogger.swift`）统一日志。禁止直接使用 `NSLog` / `print`。

**调用方式：** `appLog(.info, "SessionHandle", "send() queued — status=\(status)")`

| Level | 用途 |
|-------|------|
| `.debug` | 开发调试，仅定位特定问题时有用 |
| `.info` | 正常流程事件（session 启停、导航、状态切换） |
| `.warning` | 可恢复的异常 |
| `.error` | 影响功能的失败 |

**规范：**
- category 使用类名（不含模块前缀），如 `"SessionHandle"`、`"ChatRouter"`
- 禁止在日志中输出敏感信息（token、密码、API key）
- 日志窗口：Window → Logs（Cmd+Shift+L）
- 底层同时写入 `os.Logger`，可通过 Console.app 查看历史日志

## 目录结构

```
ccterm/
├── macos/                    # macOS 平台
│   ├── ccterm.xcodeproj/
│   ├── ccterm/               # 应用源码
│   │   ├── App/              # CCTermApp, AppState, RootView
│   │   ├── Sidebar/          # SidebarView, SidebarViewModel
│   │   ├── Components/       # 通用 SwiftUI 组件
│   │   ├── Content/          # 主内容区各页面
│   │   │   ├── Chat/         # 会话消息展示
│   │   │   ├── Todo/         # 任务管理
│   │   │   ├── Archive/      # 已归档会话视图
│   │   │   ├── Project/      # 项目创建和管理
│   │   │   ├── PlanReview/   # Plan 审阅与评论
│   │   │   ├── Settings/     # 应用设置
│   │   │   └── PermissionCard/
│   │   ├── Models/           # 数据模型
│   │   ├── Services/         # 网络请求、本地存储、会话管理等服务
│   │   ├── Extensions/       # Foundation/AppKit 通用扩展
│   │   └── Resources/        # Assets.xcassets, 其他资源文件
│   ├── cctermTests/
│   ├── AgentSDK/             # Swift SDK 包
│   ├── Config.xcconfig
│   └── scripts/              # build.sh, run-tests.sh
├── web/                      # 共享 React 前端（聊天渲染）
├── protocol/                 # 跨平台 Bridge 协议定义
├── thirdparty/
│   └── fzf/                  # git submodule
└── Makefile                  # 统一构建入口
```

按功能模块组织，不按文件类型组织。新增功能模块时创建对应目录。

Xcode 项目使用文件夹同步（`PBXFileSystemSynchronizedRootGroup`），文件系统中新增/删除/移动文件会自动反映到构建中。不需要手动编辑 `project.pbxproj` 来添加文件引用。

## 国际化（i18n）

使用 Xcode String Catalog（`Localizable.xcstrings`），英文为 source language，zh-Hans 为翻译语言。系统 locale 自动切换，兜底英文。

**判断规则——哪些字符串需要本地化：**

| 需要本地化 | 不需要本地化 |
|-----------|------------|
| 用户可见的 UI 文案（按钮、标题、提示、占位符、菜单项、空状态、确认对话框） | 日志、断言消息、内部标识符 |
| 用户可见的枚举 display name（如 `PermissionMode.title`、`TodoGroup.title`） | 传给 CLI/API 的 rawValue、key |
| NSOpenPanel.message、.help() tooltip | 代码注释、Preview 标题 |

**怎么写——按上下文选 API：**

| 上下文 | 写法 | 说明 |
|--------|------|------|
| SwiftUI 字面量：`Text("…")`、`Button("…")`、`Label("…", systemImage:)`、`.navigationTitle("…")`、`.confirmationDialog("…")` | 直接写英文字面量 | 编译器推断为 `LocalizedStringKey`，自动查 String Catalog |
| 返回 `String` 的 computed property / 传给 `String` 参数的调用点 | `String(localized: "…")` | 如 `PermissionMode.title`、`FolderPickerPopover(title:)` |
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

遵循 Swift API Design Guidelines，项目额外约定：View / ViewModel / Service / Delegate 后缀，数据模型无后缀。

## 前置依赖

- **macOS 14（Sonoma）** 或更高版本
- **Xcode**：安装后首次使用需运行 `xcodebuild -runFirstLaunch` 初始化命令行工具
- **bun**：web 前端构建必需，安装方式：`curl -fsSL https://bun.sh/install | bash`
- **Git submodules**：首次 `make build` 会自动初始化（fzf），也可手动 `git submodule update --init --recursive`

## 构建与测试

统一走 `make`，不要直接调 `macos/scripts/*.sh`。

```bash
make build                                  # 构建 ccterm（Debug）
make release                                # 构建 ccterm（Release）
make test                                   # 全部单元测试
make test TEST=cctermTests/FooTests         # 只跑单个测试类
make test TEST=cctermTests/FooTests/testBar # 只跑单个测试方法
make web                                    # 仅构建 web 前端
make clean                                  # 清理所有构建产物
make fmt                                    # 格式化代码（xcstrings 等）
```

- 提交 PR 之前必须执行 `make fmt`，确保格式一致
- **默认只跑相关测试**：改动 NativeTranscript → `make test TEST=cctermTests/TranscriptXxxTests`；只有大范围重构或临近提交时再跑 `make test` 全量
- 脚本（`macos/scripts/*.sh`）已经通过 `excludedCommands` 配置了 sandbox 豁免，直接通过 make 调用即可，不需要 `dangerouslyDisableSandbox`
- `make build` 的终端输出仅包含成功/失败和两个日志路径（full log + summary）。构建失败时先读 summary 文件诊断，不要 `tail` / `cat` full log。summary 不够时再读 full log
- 单元测试使用 XCTest 框架（不用 Swift Testing），测试中使用 `NSLog` 输出调试信息（`print` 会被 xcodebuild 吞掉）

## Worktree 规范

在 worktree 中工作时，默认读取和操作 worktree 路径下的文件。不要读取主仓库目录的文件，除非用户主动要求。

## 脚本执行

临时 Bash/Python/JavaScript 脚本超过 **5 行**时，**必须**先写入文件再执行（写入项目根目录或 `/tmp`，命名如 `tmp_analyze.py`），执行后删除。禁止在命令行中内联长脚本。

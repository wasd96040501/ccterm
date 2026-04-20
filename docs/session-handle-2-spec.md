# SessionHandle2 Spec（临时）

> **⚠️ 工作稿，不入 main**：本文档为 SessionHandle2 重构设计过程中的讨论稿，仅用于设计收敛与分支内协作。合并前必须从本分支移除，不进入 main。

对外 API = `@Observable` 字段（`private(set)`）+ 命令方法。无 event、无 delegate、无 publisher。消费者皆为 render 函数。

---

## 字段

| 域 | 字段 | 类型 | 备注 |
|---|---|---|---|
| Lifecycle | `lifecycle` | `Lifecycle` | 状态机，见下 |
| Lifecycle | `historyLoadState` | `HistoryLoadState` | `{ notLoaded, loading, loaded, failed }` |
| Config | `cwd` | `String?` | |
| Config | `isWorktree` | `Bool` | |
| Config | `model` | `String?` | |
| Config | `effort` | `Effort?` | |
| Config | `permissionMode` | `PermissionMode` | |
| Runtime | `messages` | `[MessageEntry]` | session timeline 全集；含 queued / inflight / failed user message。见下节 |
| Runtime | `pendingPermissions` | `[PendingPermission]` | 含 plan 请求 |
| Runtime | `contextUsedTokens` | `Int` | |
| Runtime | `contextWindowTokens` | `Int` | |
| Runtime | `slashCommands` | `[SlashCommand]` | CLI 能力 |
| Runtime | `availableModels` | `[ModelDescriptor]` | CLI 能力；UI 选择候选来自 service 级 `ModelCatalog`，此字段只反映当前 CLI 暴露的集合 |
| Presence | `isFocused` | `Bool` | UI 写入 |
| Presence | `hasUnread` | `Bool` | handle 派生 |

---

## 对外函数

使用方无需感知 lifecycle 状态。同一方法在不同状态下行为由 handle 内部路由。

| 类别 | 方法 | 说明 |
|---|---|---|
| Lifecycle | `start()` | `.notStarted` / `.stopped` → `.starting` |
| Lifecycle | `stop()` | active → `.stopped(nil)` |
| Messaging | `send(text:attachments:)` | 唯一发送入口。append 一条 user MessageEntry 到 messages，state 初始 `.queued`；handle 内部按 lifecycle 推进 |
| Messaging | `interrupt()` | `.responding` → `.interrupting` |
| Messaging | `cancelMessage(id:)` | 对 `.queued` / `.failed` 态 user message 生效 |
| Config | `setModel(_:)` | non-active 本地写入、attached 走 RPC；observable 由 CLI init 回包确认 |
| Config | `setEffort(_:)` | 同上 |
| Config | `setPermissionMode(_:)` | 同上 |
| Config | `setCwd(_:)` / `setWorktree(_:)` | 仅非 active（`.notStarted` / `.stopped`）|
| Permissions | `respond(to:decision:)` | 回应 pending permission |
| Presence | `setFocused(_:)` | UI 写入 |

**写操作内部路由（使用方不 care）**

- **Local**：立即改 observable（`cancelMessage` / `setFocused` / `respond` / non-active 下的 `set*`）
- **Optimistic**：立即改 observable + 发 CLI，失败体现为消息 `.failed` state（`send` / `interrupt`）
- **Request**：仅发 RPC，observable 等 CLI init 回包更新（attached 下的 `set*`）

---

## 状态流转

### Lifecycle

```
.notStarted
.starting
.idle
.responding
.interrupting
.stopped(ProcessExit?)   // nil = 手动 stop；abnormal = 异常退出
```

```
.notStarted    -- start()             -->  .starting
.starting      -- sdk ready           -->  .idle
.starting      -- sdk failed          -->  .stopped(abnormal)
.idle          -- send()              -->  .responding
.responding    -- turn end            -->  .idle
.responding    -- interrupt()         -->  .interrupting
.interrupting  -- sdk ack             -->  .idle
active         -- stop()              -->  .stopped(nil)
active         -- sdk exit            -->  .stopped(exit)
.stopped       -- start()             -->  .starting     // 可重启
```

### Presence

```
messages 追加 / pendingPermissions 新增 / lifecycle 进入 .stopped(abnormal):
    hasUnread = hasUnread || !isFocused

setFocused(true):
    hasUnread = false
setFocused(false):
    // 不动 hasUnread
```

### Send / Delivery（handle 内部；使用方只调 `send`）

```
send(text, attachments):
    append MessageEntry(message: user Message2, delivery: .queued) -> messages
    if lifecycle == .idle: flush()

flush():
    合并所有 delivery == .queued 的 entry 发 CLI
    其 delivery -> .inFlight
    lifecycle -> .responding

lifecycle 进入 .idle 时:
    若仍有 delivery == .queued -> flush()

CLI ack turn end:
    对应 .inFlight 的 entry.delivery -> .delivered

CLI / send 失败:
    .inFlight 的 entry.delivery -> .failed(reason)

stop():
    .inFlight -> .failed("session stopped")
    .queued 保留（重启后 flush）
```

### Messages DeliveryState（只对 user message 有意义）

```
.queued      // 已入 timeline，未发 CLI
.inFlight    // 已发 CLI，未确认
.delivered   // CLI 已回包，turn 推进
.failed(reason)
```

### MessageEntry 结构

Envelope 模式：保留 Message2 原样，外挂 runtime 信息。不做 discriminated enum。

```swift
struct MessageEntry: Identifiable {
    let id: UUID                                  // 本地 UI identity，永不变
    let message: Message2                         // 原始 wire 消息（schema 生成）
    var delivery: DeliveryState?                  // 仅 user message envelope 有值
    var toolResults: [ToolUseID: ToolResult]      // key = assistant content 里 tool_use block 的 id；仅含 tool_use 的 assistant envelope 有值
}

typealias ToolUseID = String                      // schema: tool_use.id == tool_result.tool_use_id，形如 "toolu_xxx"
typealias ToolResult = <AgentSDK schema 生成的 tool_result block 结构>   // 不自定义，复用 schema 类型
```

**id 策略（双 id 职责分离）：**

| id | 来源 | 用途 |
|---|---|---|
| `entry.id` | 本地 `UUID()`，envelope 创建时生成 | SwiftUI `ForEach` identity；贯穿 `.queued → .delivered` 永不变 |
| `entry.message.id` | schema 字段，来自 CLI 回包 | 业务关联（日志、debug、跨端引用） |
| tool_use block id | Message2 内部 schema 字段，CLI 生成 | `toolResults` 字典 key |

UI identity 不用 CLI id：queued user envelope 在 CLI 回包前就要渲染，此时无 CLI id；且 CLI id 从 nil 变真值会被 SwiftUI 当作不同 item 导致 cell 闪烁重建。

### 原位更新（tool_use → tool_result 关联）

- assistant Message2 携带 tool_use block → 生成 MessageEntry，`toolResults` 初始为空
- 后续一条 user Message2 携带 tool_result block → handle ingest 时查找发起该 tool_use 的 assistant entry，写入 `toolResults[useID] = result`；触发 `messages[i] = updatedEntry`
- 原 tool_result 的 MessageEntry 仍 append 进 messages 数组（保 wire 数据完整）；UI 渲染时若 entry 内只含 tool_result block 则不出 View
- 效果：assistant 卡片 identity 不变，`toolResults` 字段从空变满 → SwiftUI 只 re-render 该 cell，"原位更新"达成

### 消息解析直接在 handle

**不要 MessageFilter，不要 MessageEntryBuilder，不要任何中间转换层。** handle 单一 ingest 入口吞 Message2，内部完成：

- 包 Message2 为 MessageEntry（生成本地 UUID），append 进 `messages`
- 识别 tool_result block，写入对应 assistant entry 的 `toolResults`（原位更新）
- 副作用应用：contextUsedTokens / contextWindowTokens / cwd / lifecycle 推进 / slashCommands 等 handle 字段
- streaming 更新末项 entry 的 `message` 字段（原地 `messages[last] = ...`）

live 与 replay 走同一路径（mode 标志），不抽共享组件。代码组织用 `extension SessionHandle2` 拆文件，不拆成独立类型。

### Configuration（handle 内部；使用方只调 `set*`）

```
non-active（.notStarted / .stopped）  -> 直接写字段；下次 start() 时作为启动参数
attached（.idle / .responding / ...） -> 发 RPC；字段由 CLI init 消息回包覆盖
```

---

## Repository 位置

**在 handle 之外**。Repository 语义（git root、branch、remote、worktree 清单）是多 session 共享资源，由 `RepositoryService` 持有，按 root path 去重。

handle 只存 `cwd` + `isWorktree`。UI 需要分支 / 仓库元数据时按 `cwd` 查 RepositoryService。

---

## Messages 与性能

### 结论

`messages: [MessageEntry]` 做成 `@Observable` 字段。新增消息不会导致 ChatView 完全重绘。

### 规则

1. `MessageEntry` 带稳定 `id`（`UUID` 或 CLI 消息 id）。
2. ChatView 用 `List` 或 `LazyVStack` + `ForEach(messages, id: \.id)`。
3. 新消息用原地 `messages.append(_)`，禁止 `messages = messages + [x]`（复制整数组）。
4. Streaming 更新最后一条：`messages[lastIndex] = updated`；`MessageEntry` 是 struct，单项替换会触发 `messages` keypath 通知。
5. 历史 replay 用 `messages.append(contentsOf: batch)` 一次性 mutation，只发一次通知。
6. MessageEntry 所有字段都是值类型。

### 性能模型

- `messages` 变化 → ChatView.body 重新求值（便宜）。
- `ForEach` 按 `id` diff → SwiftUI 只 render 新增 / 变化的 cell；未变化 cell 的子树保持不变（不重绘）。
- `List` / `LazyVStack` 虚拟化，屏幕外 cell 不参与 render。
- Streaming 场景：只有末尾 cell 的 body 重新执行，其他 cell 不动。
- 长对话（数千条）：ForEach identity diff O(n)，可接受；若成瓶颈再引入分页。

### 红线

- 消息列表禁止放中间状态 enum（如 `.loading`, `.failed`），通过 `MessageEntry.delivery` / `MessageEntry.toolResults` 等字段表达，保持数组身份稳定。
- 禁止为"某条消息变了"单独对外暴露字段或事件；依赖 SwiftUI 对 `messages[i]` 的追踪。
- 禁止 View 持有 `messages` 的副本；任何派生视图（按 role 分组、搜索结果）用 computed。

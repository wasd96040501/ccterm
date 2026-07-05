# Transcript 重构 —— 仅历史、会话无关（v6）

状态：提案（实施前），v10.1（v10 + 移除语法高亮回填 —— 本 PR 不做，留给后续）。

范围：按顶层 `CLAUDE.md` 的 MVVM-C 约定重写历史 transcript 查看器。**v5 交付的 Store↔VC 耦合泄漏了大量异步管道（Combine subject + 串行 apply chain + 行数镜像 + `isReleased` 保护位）—— 这些全是自找的复杂度，AppKit 和 SDK 都不要求。** v6 把数据路径改写为一个原语：VC 里的 for-await 循环，等待 `Task.detached` 完成排版，并在同一个 MainActor tick 里提交 row inserts。无镜像、无 chain、无 Combine、无保护位。

从 v5 保留：布局对齐（460..780 居中）、命名合规、§ 2 性能项、`RowLayout` + `BlockCellView` 代码原样保留（只做 delegate 小改名）、attach § 2.19 契约形状。

重写内容：SDK 历史 API（新增 sync + cursor）、Store 形状（无事件 subject、无 loader —— 纯数据 + 缓存）、VC（拥有 loader Task，直接驱动 commit）。

不在范围内：把旧 renderer 栈从 `Session.swift` 里拆出来（单独 PR）；用户气泡 / 图像预览 sheet；transcript 内 ⌘F 搜索；跨行**选择**（单独 PR —— 样式对齐是本 PR 的重点）；顶部 / 底部 scrim overlay。

## 0. 万物皆从此一条不变式导出

> **数据 mutation 和 `tableView.insertRows` 必须落在同一个 MainActor tick。**

只要该条成立，v5 的每一个"辅助"机制都不再必要：

- 因为 mutation 和 `insertRows` 共 tick，`store.blocks.count` 和 `tableView.numberOfRows` 在每次 dataSource 查询时都一致 → **无需 `visibleBlocks` 镜像**。
- 因为 for-await 循环的 body 在两次 await 之间同步执行 —— 而 `await Task.detached { … }.value` 返回到同一个 actor —— 一页的 commit 在下一次 `stream.next()` 返回前完成 → **无需 `applyChain`**。
- 因为没有跨 tick 的 delta 要传播，Store 不需要 publish 事件 → **无需 Combine subject、无需 `.receive(on:)`**。
- 因为 `Task.cancel()` 会让下一个 `try await`（以及围绕 detached 工作显式调用的 `Task.checkCancellation()`）抛出 `CancellationError`，循环会在 VC 拆除时干净退出 → **无需在每个 commit 路径上加 `isReleased` 位**。

**违反该不变式就会把上述四样都重新引入。** v5 就违反了 —— Store 在 `events.send(...)` 里同步 mutate `blocks[]`，VC 在 off-main 排版 hop-back 之后再 apply `insertRows`。为了给由此产生的不一致窗口打补丁，v5 长出了镜像、chain、subject 和位。**下面每个小节都对着这条规则检查。**

## 1. 目标

1. **Session 无关的 transcript。** 用 `transcriptId: String` 读取；跟 `Session` / `SessionRuntime` 无关。状态放在 app 域的 registry 里，侧边栏切换回来能瞬间绘制。
2. **首屏同步、后续页异步。** SDK 暴露 **sync** `loadPage` + **async** `stream`，都基于 cursor。首页在 main 读（本地文件、~64 KB、典型 <10 ms），在 main 排版，数据到位时才 hit table —— 零空白闪现。旧页通过 cursor 从 stream 里过来，off-main 排版，main commit。
3. **按顶层 `CLAUDE.md` 分层。** Store 拥有数据 + 缓存 + cursor；VC 拥有生命周期 + dataSource + delegate + loader Task；Registry 放在 composition root。数据向下、事件向上。**不引入 ViewModel** —— 在 `Block` 与 cell 渲染之间没有派生步骤（那一步就是 `RowLayout.make`，一个纯函数，delegate 在查询时调用）。这里加 VM 只是为了分层而分层。
4. **性能对齐** 老 renderer 每一项 § 2 —— 见 § 11。
5. **布局对齐。** 内容 clamp 到 `[BlockStyle.minLayoutWidth, BlockStyle.maxLayoutWidth] = [460, 780]`，水平居中于全宽 scroll view；旧的 `TranscriptScrollViewFactory.contentInsets` —— `top: 56, bottom: 112` —— 原样复用。
6. **样式的交互对齐。** hover 标题变亮、tool 组 / 子项折叠。选择推迟到后续 PR（§ 14）。语法高亮回填不在本 PR 范围（§ 7）。
7. **命名合规。** 每个新类型都要带列出的角色后缀（`View` / `Controller` / `Store` / `Delegate`）。新栈里不允许 `Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Adapter` / `Coordinator`。（旧的 `Transcript2Coordinator` 名字不被任何新东西继承 —— 它是一个我们不再向下传播的历史误命名。）

## 2. 组件 —— 仅新增

| 组件 | 角色 | 功能 | 向下依赖 |
|---|---|---|---|
| `TranscriptStore` | Store | 纯数据 + 缓存持有者。拥有 `blocks: [Block]`、`layouts: [UUID: RowLayout]`、`layoutsWidth: CGFloat`、`folds: [UUID: Bool]`、`statuses: [UUID: ToolStatus]`、`nextCursor: SessionHistory.Cursor?`、`didLoadFirstPage: Bool`、`didFinishLoad: Bool`、`builder: MessageBlockBuilder`。**无 loader Task**、**无事件 subject**、**无 Combine**。同步 mutation API —— 每个动词命名一个动作，而非实现细节（§ 3 命名规则）：`loadFirstScreenSync(viewportHeight:width:)`（§ 5.1.1）、`prependOlderBlocks(_:nextCursor:)`（前置 blocks + 设置 cursor；`nextCursor == nil` 自动翻转 `didFinishLoad`）、`setLayoutWidth(_:)`（幂等：宽度未变则 no-op；否则清空缓存并更新 `layoutsWidth`）、`cacheRowLayouts(_:atWidth:)`（从 off-main 排版结果批量填充缓存；宽度守卫 + 反投毒）、`invalidateRowLayout(id:)`、`toggleFold(id:) -> UUID?`。读 API：`layout(for:width:folds:statuses:) -> RowLayout`（get-or-compute），以及直接读 `blocks` / 缓存。 | `SessionHistory`（仅类型）/ `MessageBlockBuilder` / `RowLayout.make` / `Block` / `RowLayout` |
| `MessageBlockBuilder` | Builder（临时的有状态转换器） | **单一 builder，单向（正向）。** `Message2` → `[Block]`。`mutating ingest(_:) -> [Block]`、`mutating finish() -> [Block]`。内部状态 = `openGroupItems`（缓存中的可分组 assistant 连续段）。**无 `withheld` tool_result 缓冲 —— SDK 负责配对**（§ 2 SDK 行）。**`nonisolated struct`** —— 无 `@MainActor`，无 UI 类型。可在任意 executor 上跑：Phase 1 通过 `Task.detached`（§ 5.2）走 off-main。**遍历方向是 stream 层关心的事，不是 builder 关心的**  —— v9 的 `Reverse*Builder` 名字是本末倒置。历史路径喂给 builder 的每一页都是正序（每页内部已正序、tool-pairs 完整）；未来 live 路径重构可以用完全相同的 builder，随 CLI stream 一条条喂消息。 | `Message2` / `Block` / `isGroupableAssistant` 谓词 |
| `TranscriptRegistryStore` | Store | App 域的 `[transcriptId: TranscriptStore]`；`store(for:) -> TranscriptStore` get-or-create；`discard(_:)` 通过 `onSessionArchived` 闭包接到 `SessionManager.archive`。 | `TranscriptStore` |
| `TranscriptClipView` | View | `NSClipView` 子类。`constrainBoundsRect(_:)` 在 documentView 比 clip 窄时居中（`origin.x = floor((proposedBounds.width - docWidth) / -2.0)`；否则直通）。`setFrameSize(_:)` 对负宽度做 clamp（§ 2.9）。垂直方向直通。 | — |
| `BlockCellViewDelegate` | Delegate | `@MainActor` class-only 协议。`BlockCellView*.swift` 里现存每一处 `coordinator?.…` 都对应一个方法 —— 见 § 8。 | — |
| `TranscriptViewController` | Controller | `NSViewController` + `NSTableViewDataSource` + `NSTableViewDelegate` + `BlockCellViewDelegate` + `DetailContainerChild`。**拥有后台 loader Task**。dataSource 回调**直接**读 `store.blocks`（无镜像 —— mutation 和 `insertRows` 在同一次 `await` 返回 tick 落地）。两步 attach：`viewDidLoad` 装 delegate；`viewDidLayout` 首次运行 `layoutSubtreeIfNeeded` → seed 宽度 → **首页同步** → `dataSource = self` → 预热 tile → `scrollRowToVisible` 到 tail → 启动后台 loader。在 `prepareForRemoval` 上：`loaderTask?.cancel()` —— for-await 循环的下一个 `await` 抛 `CancellationError`，循环退出；不需要销毁后守卫。 | `TranscriptStore` / `TranscriptClipView` / `BlockCellView` / `BlockCellViewDelegate` / `Block` / `RowLayout` / `BlockStyle` / `SessionHistory` |
| **`AgentSDK.SessionHistory`（扩展）** | SDK | 基于 cursor 的 API。`Cursor` = 不透明的字节偏移。`Page { messages: [Message2]; nextCursor: Cursor? }`。**Sync** `loadPage(id:cursor:) throws -> Page` 同步读一个块（~64 KB）、解码、返回**页内正序**的消息（SDK 在页边界把反向字节游走的次序翻转，让 app 永远看不到"每页反向"的次序）。`nextCursor` 是下一（更旧）的字节位置，或文件顶时为 nil。**Async** `stream(id:cursor:) -> AsyncThrowingStream<Page, Error>` —— 通过 `AsyncStream(unfolding:)` 风格的迭代器做需求驱动的 producer；`next()` 恰好触发一次 `loadPage`；producer 轮询 `Task.checkCancellation()`。**SDK 负责跨页 tool-result 配对**（v10 修正 —— v6 把这个推给 app 是错的）：当反向字节游走遇到一个孤儿 `tool_result` 而它的 `tool_use` 还没被读到时，SDK 把它 withhold 在 `_WithheldTools: [String: Message2]` 里（key 是 `tool_use_id`）；当稍后（更旧的）页里出现匹配的 `tool_use`，SDK 会把 withheld 的 `tool_result` 插到该页正序消息列表的紧跟在它的 `tool_use` 之后。**每个 yield 出来的页都是自成完整、正序、tool 对完备的切片。** App 侧收到的是干净数据 —— 无 `withheld` 状态、无方向感知。v5 的 `SessionHistory.load(id:order:)` **被移除**。 | 现存 SDK 内部（`_ReverseLineReader` / `Message2Resolver`）|

明确**不**在新栈里的：

- **无 `visibleBlocks` 镜像。** dataSource 返回 `store.blocks.count`。Loader 在与 `tableView.insertRows` 同一个 MainActor tick 里 mutate `store.blocks` —— 见 § 5。
- **无 `applyChain: Task<Void, Never>?`。** loader 的 for-await 循环本身就是串行化 —— 一页的 commit（main）在下一页排版的 `await` 返回前完成。
- **Store→VC 路径无 `Combine.PassthroughSubject` / `.receive(on:)`。** loader 是 VC 拥有的 Task；commit 是循环 body 里对 `self` 的直接方法调用。
- **无 `isReleased: Bool` 位。** `prepareForRemoval` 里取消 loader Task 会让下一个 `for-await` 步骤抛 `CancellationError`；循环干净退出。此时正在飞行中的 Task.detached 排版会跑完但返回值被丢弃 —— 等 await 之后的 `Task.checkCancellation()` 处理排版结束后的关卡（§ 5.2）。
- **无 `ViewModel` 层。** `RowLayout.make(for:width:…)` 就是派生步骤。塞一个 VM 要么变成透传壳（毫无价值），要么就复制一份 layout 函数（引入 bug）。

原样复用（不搬代码）：`Block`、`RowLayout`、所有 `XxxLayout.make`、`BlockCellView`（仅做下面的 `coordinator → delegate` 改名）、`BlockStyle`、`AppContext.transcriptRegistry` 槽位、`AppDelegate` 里 registry 构造、`DetailContext.transcriptRegistry` 传播、`DetailFlowCoordinator.makeChild(.history)` 短路、`isGroupableAssistant` 谓词（`Message2` 的扩展）。

**历史路径不复用（但 live 路径仍编译）：** `ReverseEntryBuilder`、`MessageEntryBlockBuilder`、`MessageEntry` 类型。Live 路径继续用它们；历史路径一次性只用新的 `MessageBlockBuilder`。

## 3. 命名合规

- **只用角色后缀。** `View` / `Controller` / `Store` / `Delegate`。禁止 `Adapter` / `Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Coordinator`。`Storage` → `Store`。`Builder` 允许用于临时的有状态转换器（是 Swift 惯用、匹配现存用法 —— 但**必须**有结构性理由，不是"我们本来就有一个"）。
- **新类型不带数字后缀。** 不允许 `Transcript2Xxx`。
- **数据类型无后缀。** `Block`、`RowLayout`、`HighlightValue`、`Message2` 是已有的无后缀类型；保留。
- **目录 = 功能。** 所有新文件放 `macos/ccterm/Content/Chat/Transcript/` 下。

### 3.1 按结构命名，不要按 caller / 上下文 / 出处命名

本文档经历过的三个最糟糕的重命名（`ReverseEntryBuilder → HistoryBlockBuilder → ReverseMessageBlockBuilder → MessageBlockBuilder`；`applyFirstPage → loadFirstScreenSync`；VC 里的 `visibleBlocks` 镜像）都是从**谁调用它**或**我从哪里抄来的**开始命名，等设计尘埃落定后才不得不重命名。写的时候就能拦住这三个的规则是：

> **名字必须描述这个东西孤立地"是"什么，而非它当前 caller 期望它"做"什么。删掉它周围的代码后名字仍然应有意义。**

具体来说：

| ❌ 按…命名 | 真正的答案 | ✅ 按…命名 |
|---|---|---|
| `HistoryBlockBuilder` | 转换 `Message2 → [Block]`；方向是 caller 关心的事 | `MessageBlockBuilder` |
| `ReverseMessageBlockBuilder` | 遍历方向住在 SDK（字节游走），不是 builder | `MessageBlockBuilder` |
| VC 里的 `visibleBlocks` 镜像 | 第二个真相源；存在的唯一原因是 Store 的 mutation 和 VC 的 insertRows 落在不同 tick | 什么也没有 —— mutation 和 insertRows 共 tick（§ 0），镜像不存在 |
| `applyFirstPage(_:)` | "apply" 是没有直接宾语的动词 —— apply 什么？一页？一批？往哪里？ | 归并到 `loadFirstScreenSync` 里，它描述这个动作 |
| `seedWidth(_:)` / `retargetWidth(_:)` | 两者都是"设置 layout 宽度并在变化时清掉陈旧缓存" | 合并到 `setLayoutWidth(_:)` |
| `cacheRowLayouts(_:width:)` | "write" 是管道动词（写到磁盘？写到内存？）。实际动作 = 填充 layout 缓存 | `cacheRowLayouts(_:atWidth:)` |
| `prependOlder(_:newCursor:)` + `advanceCursor(to:)` + `markFinished()` | 三个名字对应三种"我们处理了一些（或零个）更旧的块，这是下一个 cursor（nil = 到文件顶）"的情况 | 一个名字：`prependOlderBlocks(_:nextCursor:)` |
| `applyOlderBatch(blocks:nextCursor:)`（v10 首版） | "apply" 是模糊动词（§ 3.2 嗅探）；"batch" 描述大小而非内容 | `prependOlderBlocks(_:nextCursor:)` |
| `startBackgroundLoader()` | "background" 是运行时属性（线程 / tick），不是动作描述 | `startOlderPagesLoader()` |
| `commitOlder(blocks:pairs:width:newCursor:)`（VC 方法） | "commit" 是数据库动词；实际的 UI 动作是往 table 顶部 insert rows | `insertOlderBlocksAtTop(_:cachedLayouts:atWidth:nextCursor:)` |
| `runStructuralUpdate(_:)` | "structural" 是类别名而非动作；藏起了实际发生的事（关掉隐式动画） | `withoutImplicitAnimations(_:)` |
| `performLiveResizeFrame(newWidth:)` | "perform...frame" —— 窗口 frame？runloop 帧？两种都说得通 | `handleLiveResizeTick(newWidth:)` |
| `performWidthChange(newWidth:)` | "perform" 是模糊套壳动词 | `retileAtNewWidth(_:)` |
| `cacheLayouts` / `invalidateLayout` / `layout(for:width:...)` | "layouts" 不够具体 —— 什么的 layout？ | `cacheRowLayouts` / `invalidateRowLayout` / `rowLayout(for:...)` |

### 3.2 加名字前的两条嗅探测试

- **删掉上下文。** 我把这个类型 / 函数的签名交给一个新读者，他能说出它做什么吗？如果名字只在其调用点旁才成立，改。
- **动词优先，对象在后。** 方法名的动词是**动作**（`cache`、`set`、`apply`、`refresh`、`invalidate`、`toggle`、`load`），永远不是实现细节（`write`、`seed`、`retarget`、`commit`、`handle`）。对象是被作用的东西（`Layouts`、`LayoutWidth`、`OlderBatch`、`Fold`）。

## 4. 布局 —— 460..780 带全宽 scroll 里居中

### 4.1 为什么用 `TranscriptClipView`（而不是只靠 Auto Layout）

只用 Auto Layout 在 documentView 上**无法**居中。`NSClipView.constrainBoundsRect(_:)` 会在 documentView 比 clip 窄时把 `bounds.origin.x` 夹到左对齐 —— 这是 Apple 有文档记载的行为。子类化 `NSClipView` 反转这个 clamp 是规范解法（对照 Apple 官方文档 + 社区书写记录已验证）。这不是 trick —— 是官方推荐模式。

### 4.2 视图层级

在 `TranscriptViewController.loadView()` 里构造：

```
TranscriptViewController.view                NSView         全窗格
 └ NSScrollView (host)                       原样
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              § 2.3
    · hasVerticalScroller = true; autohidesScrollers = true
    · hasHorizontalScroller = false
    · scrollerStyle = .overlay
    · drawsBackground = false; borderType = .noBorder
    · automaticallyAdjustsContentInsets = false
    · contentView = TranscriptClipView()                              必须在 contentInsets 之前赋值
    · contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
    约束：四边贴到 view
 └ TranscriptClipView (contentView)          子类
    · wantsLayer = true
    · layerContentsRedrawPolicy = .never                              § 2.3
    · constrainBoundsRect：documentView 更窄时水平居中
    · setFrameSize：max(0, w), max(0, h)                              § 2.9 负宽度 clamp
 └ NSTableView (documentView)                原样
    · headerView = nil
    · backgroundColor = .clear
    · style = .plain
    · selectionHighlightStyle = .none                                 （§ 14 真正的选择延到下一个 PR）
    · gridStyleMask = []
    · usesAutomaticRowHeights = false; rowSizeStyle = .custom
    · intercellSpacing = .zero
    Auto Layout：
      · widthAnchor ≤ BlockStyle.maxLayoutWidth (780)          required
      · widthAnchor ≥ BlockStyle.minLayoutWidth (460)          required
      · widthAnchor == clip.widthAnchor priority .defaultLow   在带内贴着 clip
      · topAnchor == clip.topAnchor
      · 高度由 intrinsic content size（行合计）驱动 —— 无底边 pin
    单列：
      · identifier = "block"
      · resizingMask = [.autoresizingMask]
      · minWidth = 0; maxWidth = .greatestFiniteMagnitude
 └ NSTableRowView                            原样，但通过 reuse identifier 池化 —— 见下
 └ BlockCellView                             复用。Reuse identifier: "TranscriptBlockCell"
    (bounds.width ∈ [460, 780])

VC 还实现 `tableView(_:rowViewForRow:) -> NSTableRowView?`（v7 review #4 修复 —— 对应 § 2.17）：

    let id = NSUserInterfaceItemIdentifier("TranscriptBlockRow")
    if let v = tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView { return v }
    let v = NSTableRowView()
    v.identifier = id
    return v

没有它，NSTableView 每一次 scroll tick 都会新分配 row view（§ 2.17 回归）。row view 本身是原样 —— 内部的 `BlockCellView` 负责绘制。
```

### 4.3 BlockCellView 无需改居中

`BlockCellView.layoutOrigin.x = BlockStyle.cellOriginX(forRowWidth: bounds.width) + blockHorizontalPadding`。当 `bounds.width ∈ [460, 780]` 时，`cellOriginX` 返回 0（不做逐 cell 居中 —— clip 已经把 table 居中了）。`layoutOrigin.x` 塌缩成常量 `blockHorizontalPadding`。

### 4.4 Live resize 行为

- Clip < 460 → `widthAnchor ≥ 460` 生效；table 保持 460；水平 scroller 关 → 边缘裁掉（接受；匹配旧行为）。
- Clip ∈ [460, 780] → `widthAnchor == clip.widthAnchor` 低优先级生效；table 贴着 clip。
- Clip > 780 → `widthAnchor ≤ 780` 生效；table 保持 780；clip 通过子类再次居中。

## 5. 数据流

```
~/.claude/projects/<id>.jsonl                    (CLI 写的文件)
    │
    │  cursor = nil（首页）→ cursor = page.nextCursor → …
    ▼
SessionHistory.loadPage(id:cursor:order:.reverse)  SYNC —— 仅首屏
    · 无 Task；阻塞 main；单个 64 KB 页典型 ≤ 10 ms
    · 返回 Page { messages, nextCursor }
    ▼
Store.loadFirstScreenSync(viewportHeight:width:)  MainActor sync —— 视口高度为界（§ 5.1.1）
    · 对每个 SessionHistory.loadPage 返回的页：
        - 正序消息喂给 store.builder（MessageBlockBuilder）
        - builder 吐出 Blocks（nonisolated、方向无关）
        - 逐 block 同步排版 via store.rowLayout(for:width:...) —— 预热缓存、累加高度
    · 每个页边界做跨页组合并（§ 5.1.2）
    · 当 Σ 高度 ≥ viewportHeight 或 page.nextCursor == nil（文件顶）时终止
    ▼
TranscriptViewController.viewDidLayout —— 首次
    · setLayoutWidth → dataSource = self → layoutSubtreeIfNeeded → scrollRowToVisible(last)
    · startOlderPagesLoader()   ── 仅当 store.nextCursor != nil 才触发
    │
    ▼
SessionHistory.stream(id:, cursor: store.nextCursor)   ASYNC（SDK 内部 Task.detached）
    · yield AsyncThrowingStream<Page, Error>
    · Task.detached：每次迭代 = 一次 loadPage off-main 同步执行
    │  · SDK 的 _WithheldTools 保证 yield 出的每一页都有完整 tool_use↔tool_result 对
    ▼
VC 的 loader Task = for try await page in stream { … }        MainActor
    Phase 1  · for m in page.messages { blocks += store.builder.ingest(m) }   (main)
             · blocks += store.builder.flushOpen()                           (main；页边界)
             · 需要时在边界做组合并（§ 5.1.2）                                  (main)
    Phase 2  · let pairs = await Task.detached { blocks.map … RowLayout.make(…) }.value   (off-main)
    Commit   · withoutImplicitAnimations {                                   (main，一个 runloop tick)
                  captureAnchor()
                  store.prependOlderBlocks(blocks, nextCursor: page.nextCursor)
                  store.cacheRowLayouts(pairs, atWidth: w)
                  tableView.beginUpdates()
                  tableView.insertRows(at: 0..<n, withAnimation: [])
                  tableView.endUpdates()
                  restoreAnchor()
              }
    （下一次迭代；loader Task 一直跑到 stream 结束或 Task.cancel()）
```

该形状的关键不变式：

- **串行化**来自 for-await 循环自身。一页 commit 完成后，下一次 `await stream.next()` 才返回。不需要 `applyChain`。
- **VC-Store-Table 一致性于同一 tick。** `store.prependOlderBlocks` 与 `tableView.insertRows` 在同一 MainActor tick 里执行，都在 `withoutImplicitAnimations` 内。`store.blocks.count` 和 `tableView.numberOfRows` 在每次 dataSource 查询时都一致。不需要 `visibleBlocks` 镜像。
- **取消**是自然产物：`prepareForRemoval` 里的 `loaderTask?.cancel()` 会让下一个 `try await stream.next()` 抛 `CancellationError`。detached 排版之后的 `Task.checkCancellation()` 关掉"排版完成但 VC 已拆除"的窗口（§ 5.2）。不需要 `isReleased` 守卫。
- **无 Combine。** VC 直接拥有 Task 和 commit 闭包。

### 5.1 首屏同步 —— 基于高度终止

v5 计划要求 Phase 1 排版走 off-main 以保 § 2.6（"回填由 off-main 构建"）。v9 拆成两条路径：

**首页（main 同步）：**
1. `SessionHistory.loadPage(cursor: …)` —— 文件读 + JSON 解码。本地文件，一个 64 KB 页 → 典型读 + 解码 3–8 ms。
2. `store.builder.ingest(_:)` —— nonisolated 调用（builder 方向无关、无 MainActor 要求），~50 条消息 block 构建约 1 ms。
3. **循环内逐 block 同步排版** —— 对每个新构建的 block，调用 `store.layout(for: b, width: w, …)`。它既填 layout 缓存，也给出该 block 的总高。累加 `heightSoFar`，`heightSoFar >= viewportHeight` 时（或到达文件顶时，谁先谁停）终止。
4. `dataSource = self` + `tableView.layoutSubtreeIfNeeded()` —— tile 可见行。此时 `heightOfRow` 按构造是缓存命中（step 3 已经预热了它们）。**tile pass 里零 on-main 排版** —— 最干净的 § 2.19 attach 契约。

**旧页（异步 off-main 排版）：**
旧 renderer § 2.6 规则（"回填由 off-main 构建"）在这里生效。旧页来自 `stream`，由 VC loader Task 迭代；排版跑在 `Task.detached`，commit 在 main。同样的 off-main-built + main-sync-applied 契约。

#### 5.1.1 基于高度终止 —— 整个循环

```swift
func loadFirstScreenSync(viewportHeight: CGFloat, width: CGFloat) throws {
    guard !didLoadFirstPage else { return }
    setLayoutWidth(width)                                            // 幂等 —— 未变则 no-op
    var cursor: SessionHistory.Cursor? = nil
    var accumulated: [Block] = []
    var heightSoFar: CGFloat = 0

    while heightSoFar < viewportHeight {
        // SDK 内部返回页内正序、tool 对完整的页（§ 2 SDK 行）。
        // App 侧 builder 方向无关。
        let page = try SessionHistory.loadPage(id: transcriptId, cursor: cursor)
        var pageBlocks: [Block] = []
        for m in page.messages { pageBlocks.append(contentsOf: builder.ingest(m)) }
        if page.nextCursor == nil {
            pageBlocks.append(contentsOf: builder.finish())          // 到文件顶：flush 未闭合组
            didFinishLoad = true
        }

        // 跨页组合并（§ 5.1.2）：如果较新页的最新 block（accumulated[0]）
        // 与该较旧页的最旧 block（pageBlocks.last）同属一个未闭合组，则合并。
        if !pageBlocks.isEmpty, !accumulated.isEmpty {
            mergeGroupAtBoundary(older: &pageBlocks, newer: &accumulated)
        }

        // 逐 block 同步排版 —— 填缓存并累加终止条件。
        if !pageBlocks.isEmpty {
            let inserted = pageBlocks
            accumulated.insert(contentsOf: inserted, at: 0)
            for b in inserted {
                let l = layout(
                    for: b, width: width,
                    folds: folds, statuses: statuses)
                let pad = BlockStyle.blockPadding(for: b.kind)
                heightSoFar += pad.top + l.totalHeight + pad.bottom
            }
        }

        if page.nextCursor == nil { break }                          // 文件顶
        cursor = page.nextCursor
    }
    blocks = accumulated
    nextCursor = didFinishLoad ? nil : cursor
    didLoadFirstPage = true
}
```

#### 5.1.2 跨页组合并

一段可分组 assistant 运行可能跨页。SDK 不按组边界对齐页（那样会把 app 的渲染语义泄进按字节的 reader）。在 app 侧的 prepend 时处理：

```swift
private func mergeGroupAtBoundary(older: inout [Block], newer: inout [Block]) {
    guard case .toolGroup(var olderTail)  = older.last?.kind,
          case .toolGroup(let newerHead)  = newer.first?.kind,
          !olderTail.children.isEmpty, !newerHead.children.isEmpty
    else { return }
    // 较旧页的尾 block（页内最旧：正序最后一个）与较新页的头 block（页内最新：正序第一个）
    // 都是子 id 相邻的 toolGroup，说明它们是同一未闭合运行被缝口切成两半。
    olderTail.children.append(contentsOf: newerHead.children)
    older[older.count - 1] = Block(id: older.last!.id, kind: .toolGroup(olderTail))
    newer.removeFirst()
}
```

**合并检查的正确性**基于一条不变式：**一个组是连续 `isGroupableAssistant` 消息的极大运行**（`ReverseEntryBuilder` 和 `SessionRuntime.appendToTimeline` 都共享这个谓词）。因此若较旧页的最后一个 block 和较新页的第一个 block 都是 `.toolGroup`，它们必然是同一运行的一部分（相邻 + 都可分组 ⇒ 按极大运行定义就是同一段）。任一边界处的不可分组消息会产生单条项或关闭前面的组，合并检查的"两边都是 .toolGroup"门槛会正确跳过这些场景。

builder 的 `finish()` 在每一页 `ingest` 循环结束时都被调用 —— 但**仅**在真正文件顶时用它唯一的"final flush 任何残留的未闭合组"目的。在中间页边界，我们**不**调用 `finish()`；而是让 builder 的内部 `openGroupItems` 通过显式合成排空：在切到下一页前调用 `builder.emitOpenGroupSoFar() -> [Block]`，它 emit（但不重置内部状态 —— 见下段）。不 —— 其实更简单：**builder 每一次 ingest 序列结束通过一个每页 `flushOpen() -> [Block]` 调用把所有未闭合组 emit 出去。** 它在下一页前重置内部状态。跨页合并在 `mergeGroupAtBoundary` 里从已 emit 的 blocks 重建连续性。这让 builder 本身保持简单（无跨页状态）。

紧凑的 builder 形状：

```swift
struct MessageBlockBuilder {                            // nonisolated, Sendable
    private var openGroupItems: [Message2] = []
    mutating func ingest(_ m: Message2) -> [Block] { … }   // 可 emit 前一个未闭合组 + m
    mutating func flushOpen() -> [Block] { … }              // 页边界：emit 残留 open，重置
    mutating func finish() -> [Block] { flushOpen() }       // 文件顶：同上
}
```

**终止条件来自实际目标**，而非启发式：
- `heightSoFar >= viewportHeight` —— 已构建足够填满可见窗格的量。
- `page.nextCursor == nil` —— 文件顶；没有更多可构建。

两个分支都天然终止。**无 `maxPages` 上限。无 `deadline` 启发式。** v7/v8 草案带这两个作为"安全"边界；v9 明确否决 —— 病态会话形态（整个文件是一段未闭合的可分组 assistant 运行、无 closer）会让 main 冻结数秒来同步走完整个文件，但另一个选项（在 N 页时 bail-out 交给 async）同样糟 —— 用户等待的时间是一样的，交给 async 意味着先看到空白然后延迟绘制，而不是一次更长的等待换来完整绘制。移除上限意味着：罕见最坏情况是一次更长的等待；典型情况更快（无过度读）；逻辑更简单（一个终止标准而不是三个）。

**实用范围：**
- 典型会话（首页填满屏幕）：读 1 页 + 排版 ~15–20 blocks ≈ **20–50 ms**。
- Tool-heavy 尾部（需要 2–3 页找足可见高度的内容）：~40–80 ms。
- 首条消息很高（500 行 fileEdit diff）：读 1 页 + 1 block 排版 ≈ **10–30 ms** —— 单个 diff 已经超过 `viewportHeight`，我们在一个 block 后停下，tile pass 时该行的 `heightOfRow` 是缓存命中。
- 罕见最坏情况（整个文件是一段未闭合的组运行）：同步走到文件顶。在 10 MB 文件上可能秒级。接受；加 bail-out 也不改善 UX。

同步在 main 的理由：§ 2.6 的目标是"长冷启动不冻结 UI"；这担心适用于旧页追赶（可能遍历数千 blocks）。首屏被视口界定，不被文件界定 —— 无论当前窗口高度对应多少 blocks，都是一屏。开会话冻结 ~30 ms 好于晚一帧绘制。且因为逐 block 排版在 `dataSource = self` 之前就写入缓存，§ 2.19 attach 契约按构造成立 —— 第一次 `heightOfRow` 调用是纯缓存查找。

### 5.2 Loader Task —— off-main 排版 + main-tick commit

```swift
private func startOlderPagesLoader() {
    guard loaderTask == nil,
        let startCursor = store.nextCursor
    else { return }
    let tid = store.transcriptId
    loaderTask = Task { @MainActor [weak self] in
        do {
            let stream = SessionHistory.stream(id: tid, cursor: startCursor, order: .reverse)
            for try await page in stream {
                try Task.checkCancellation()
                guard let self else { return }

                // Phase 1：MainActor 构建。
                var blocks: [Block] = []
                for m in page.messages { blocks.append(contentsOf: self.store.builder.ingest(m)) }
                blocks.append(contentsOf: self.store.builder.flushOpen())   // 页边界 flush
                self.mergeGroupAtBoundary(older: &blocks, newer: &self.headSnapshot())
                guard !blocks.isEmpty else {
                    self.store.prependOlderBlocks([], nextCursor: page.nextCursor)
                    continue
                }

                // Phase 2：off-main 排版。dispatch 前在 MainActor 上快照状态。
                let w = self.store.layoutsWidth
                let folds = self.store.folds
                let statuses = self.store.statuses
                let pairs = await Task.detached(priority: .userInitiated) {
                    blocks.map { b in
                        (b.id, RowLayout.make(
                            for: b, width: w,
                            folds: folds, statuses: statuses))
                    }
                }.value

                try Task.checkCancellation()
                // Commit —— 与 await 返回在同一 MainActor tick。
                self.insertOlderBlocksAtTop(
                    blocks: blocks, pairs: pairs, width: w, newCursor: page.nextCursor)
            }
            self?.store.prependOlderBlocks([], nextCursor: nil)   // nextCursor==nil 自动翻转 didFinishLoad
        } catch is CancellationError {
            return
        } catch {
            appLog(.error, "TranscriptViewController", "loader: \(error)")
        }
    }
}
```

**取消** —— 三个关卡对齐 Task 取消到 VC 拆除：
1. `for try await page in stream` —— 当外层 Task 被取消时 `stream.next()` 抛 `CancellationError`。
2. Phase 1 之前的 `try Task.checkCancellation()` —— 覆盖"已 yield 页但 Task 中间被取消"的窄窗口。
3. Phase 2 await 之后的 `try Task.checkCancellation()` —— 覆盖"off-main 排版已完成但 VC 已被拆除"的窗口；抛出以在触碰 tableView 前退出循环。

v5 的 `isReleased` 位是每个闭包 body 重入处的第四个关卡 —— Task-cancel 设计不用布尔就达到相同效果，因为取消是一等退出路径。

### 5.3 commit —— 捕获锚点、mutate、insertRows、恢复锚点

```swift
private func insertOlderBlocksAtTop(
    blocks: [Block], pairs: [(UUID, RowLayout)],
    width: CGFloat, newCursor: SessionHistory.Cursor?
) {
    let clip = scrollView.contentView
    let originBefore = clip.bounds.origin
    let visibleRange = tableView.rows(in: clip.documentVisibleRect)
    let hasVisible = visibleRange.length > 0                          // ← v5 bug：曾经写 `!= NSNotFound`
    let firstVisibleRow = hasVisible ? visibleRange.location : 0
    let firstVisibleRect: NSRect =
        hasVisible ? tableView.rect(ofRow: firstVisibleRow) : .zero

    withoutImplicitAnimations {
        // 顺序至关重要（v7 review #1 修复）：先 prepend blocks 再 cacheRowLayouts。
        // cacheRowLayouts 按 `live = Set(store.blocks.map { $0.id })` 过滤 `pairs`——
        // 若先写后 prepend，新 blocks 还不"活"，每个 pair 都会被静默丢弃，
        // 于是 heightOfRow 会在 main 上懒排版。
        store.prependOlderBlocks(blocks, nextCursor: newCursor)
        store.cacheRowLayouts(pairs, width: width)
        tableView.beginUpdates()
        tableView.insertRows(
            at: IndexSet(integersIn: 0..<blocks.count), withAnimation: [])
        tableView.endUpdates()

        if hasVisible {
            let newRow = firstVisibleRow + blocks.count
            let newRect = tableView.rect(ofRow: newRow)
            let delta = newRect.minY - firstVisibleRect.minY
            clip.scroll(to: NSPoint(x: originBefore.x, y: originBefore.y + delta))
            scrollView.reflectScrolledClipView(scrollView.contentView)  // 文档要求的成对调用
        }
    }
}
```

注：
- **顺序重要** —— `prependOlderBlocks` 优先，`cacheRowLayouts` 其次，`insertRows` 最后。`cacheRowLayouts` 按 `Set(store.blocks.map { $0.id })` 过滤 `pairs`（§ 5.4 stale-block 守卫）；若在 `prependOlderBlocks` 之前跑，每个 pair 都过不了过滤而被静默丢弃，然后 `heightOfRow` 会对每个新行在 main 上懒排版（§ 2.6 违反）。两次写都在 `insertRows` 之前发生，以便 NSTableView 首次对新行的 `heightOfRow` 命中已预热缓存。
- `NSTableView.rows(in:)` 在 rect 无行时返回 `NSRange(0, 0)` —— **不是** `NSNotFound`。v5 用 `visibleRange.location != NSNotFound` 守卫，永远为真；用 `.length > 0` 的 `hasVisible` 检查才正确。
- `rect(ofRow:)` 在 `endUpdates` 之后立刻返回有效值 —— 新行几何在 `endUpdates` 内同步落定（§ 2.11，无估计高度）。读留在 `withoutImplicitAnimations` 内，以便滚动调整搭上和 row insert 相同的禁用事务（避免 clip origin 的隐式动画交叉溶解）。
- `withoutImplicitAnimations` = `CATransaction.setDisableActions(true)` + `NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false; body() }`（§ 2.10）。

### 5.4 `cacheRowLayouts` —— 宽度守卫 + 反投毒

```swift
func cacheRowLayouts(_ pairs: [(UUID, RowLayout)], width: CGFloat) {
    guard width == layoutsWidth else { return }   // 陈旧批 → 整批丢（§ 5.5）
    let live = Set(blocks.map { $0.id })          // 陈旧块守卫
    for (id, l) in pairs where live.contains(id) {
        if layouts[id] != nil { continue }         // § 2.14 反投毒
        layouts[id] = l
    }
}
```

**这修的 v5 bug：** `layoutsWidth` 起始为 0。v5 代码在有人填充 `layoutsWidth` 之前就调 `cacheRowLayouts(pairs, width: w)`，于是守卫静默丢弃了首批每个 pair；`heightOfRow` 接着在 main 上懒排版每一行（§ 2.6 违反，也是一个隐藏的性能回归）。

**v7 修复（v10 改名）：** VC 在**首次** `cacheRowLayouts` 之前调 `store.setLayoutWidth(w)` —— 在 `viewDidLayout` 首次内部、`view.layoutSubtreeIfNeeded()` 之后立即调。`setLayoutWidth` 是**有条件的**：

```swift
func setLayoutWidth(_ w: CGFloat) {
    guard w != layoutsWidth else { return }   // 热重入无操作
    layouts.removeAll(keepingCapacity: true)
    layoutsWidth = w
}
```

在相同窗口宽度下的热重入现在**保留** layout 缓存（匹配 § 1 目标 #1"侧边栏切回瞬间绘制"）；真正的宽度变更清空并重新播种。该方法在首次 attach 和宽度变更路径（§ 5.5）都会调用 —— 同一 body，一个名字。

### 5.5 宽度过渡 —— 通用宽度变更触发器（v7 review #5 + v8 review-2#3 修复）

**不只是 `viewDidEndLiveResize`。** 程序化宽度变更（⌥⌘S 切换侧边栏、程序化设置 split-view 分隔、进入全屏、动画器 `setFrame`）会触发 `viewDidLayout` 但**没有** live-resize 钩子。v6 规格里 live-resize-only 的接线会在所有这些情形下留下陈旧的 `layoutsWidth`。

**但 —— 不要在拖拽的每个 drift 帧都重定位。** live-resize 拖拽每帧触发 `viewDidLayout`；重定位路径取消 loader、清缓存、启动新的 detached 排版 —— 每帧跑一遍就是拖拽抖动。解法：**在 live resize 期间，只让可见行的高度失效**（§ 2.8 形状）；把全面的重定位 + loader 重启推迟到 `viewDidEndLiveResize`。

**触发面：**

```swift
override func viewDidLayout() {
    super.viewDidLayout()
    let w = tableView.bounds.width
    if !didInitialAttach {
        performFirstAttach(width: w)              // § 5.6
        didInitialAttach = true
        return
    }
    guard w != store.layoutsWidth else { return }
    if tableView.inLiveResize {
        handleLiveResizeTick(newWidth: w)       // 便宜：只让可见失效（§ 2.8）
    } else {
        retileAtNewWidth(newWidth: w)           // 完整重定位（下方这节的 body）
    }
}

override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    let w = tableView.bounds.width
    if w != store.layoutsWidth {
        retileAtNewWidth(newWidth: w)           // 延后的完整重定位
    }
}
```

`handleLiveResizeTick` 读 `tableView.rows(in: tableView.visibleRect)` 并**仅**做 `noteHeightOfRows(withIndexesChanged:)` —— 无缓存清空、无 loader 重启、无 Phase 2 排版。失效行的 `heightOfRow` 会在 main 上懒排版（§ 2.6 在此可接受 —— 拖拽是用户主动、仅可见行、短命的）。

**`retileAtNewWidth` body** —— 匹配 v5 § 5.5：
1. `store.setLayoutWidth(newWidth)` —— 条件清空（§ 5.4）+ 设置 `layoutsWidth`。
2. **取消 + 重启 loader**（v7 review #7 修复）：`loaderTask?.cancel(); loaderTask = nil; startOlderPagesLoader()`。飞行中的 Phase 2 排版结果被 await 之后的 `Task.checkCancellation()` 丢弃；新 loader 从 `store.nextCursor` 重启（只有 commit 才前进它，所以未消费的页会在新宽度下重放）。
3. 在 MainActor 上快照状态（`folds`、`statuses`）。
4. 找到可见 + 屏幕外行索引（`tableView.rows(in: visibleRect)`、`tableView.rows(in: overdrawRect)`）。
5. `Task.detached(priority: .userInitiated)` 用 `newWidth` 排版可见 AND 屏幕外 blocks。
6. hop 回 main；`store.cacheRowLayouts(pairs, width: newWidth)`；在 `withoutImplicitAnimations` 内：`tableView.noteHeightOfRows(withIndexesChanged: visibleIndexes)` + `tableView.layoutSubtreeIfNeeded()`（按 § 2.7 强制 in-tick tile flush）+ 为视觉顶部行恢复锚点。

### 5.6 Attach 契约 —— § 2.19 合规

```
loadView()
    构建 scroll + TranscriptClipView + table + column（无 dataSource）
    加到层级；激活约束

viewDidLoad()
    tableView.delegate = self
    （dataSource 仍为 nil —— 不查询任何行）
    （还没有 loader Task）

viewDidLayout()                                          ← 首次调用：真实 frame 已定
    super.viewDidLayout()
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    view.layoutSubtreeIfNeeded()
    // contentWidth（v7 review #9 修复）—— 定义为 tableView.bounds.width，
    // 在 layoutSubtreeIfNeeded 让约束求解稳定后再读。
    // 不是 view.bounds.width（含窗格），也不是 clipView.bounds.width
    // （不反映 460..780 锚点在 table 上的 clamp）。
    let contentWidth = tableView.bounds.width

    // 后续 viewDidLayout 调用处理宽度过渡 —— 见 § 5.5。
    guard !didInitialAttach else {
        if contentWidth != store.layoutsWidth { retileAtNewWidth(newWidth: contentWidth) }
        return
    }
    didInitialAttach = true

    store.setLayoutWidth(contentWidth)                   ← 任何排版之前

    if !store.didLoadFirstPage {
        // v9：基于高度终止。viewportHeight 是窗格的有效可见高度减去
        // contentInsets（顶部 + 底部 scrim）；在禁用事务内从稳定的
        // scrollView contentSize 里读。循环读页直到累加行高填满
        // viewportHeight 或到达文件顶 —— 无 maxPages / deadline 启发式。
        // 循环内逐 block 同步排版预热缓存，让后续 layoutSubtreeIfNeeded
        // tile pass 纯粹是缓存命中。
        let viewportHeight = max(
            0, view.bounds.height - scrollView.contentInsets.top
                - scrollView.contentInsets.bottom)
        do { try store.loadFirstScreenSync(viewportHeight: viewportHeight, width: contentWidth) }
        catch {
            appLog(.error, "TranscriptViewController", "sync first-page: \(error)")
        }
    }

    tableView.dataSource = self                          ← 此刻绑定；第一次 heightOfRow 在稳定宽度上
    if !store.blocks.isEmpty {
        tableView.layoutSubtreeIfNeeded()                ← 强制 dataSource-set 后的 tile
        tableView.scrollRowToVisible(store.blocks.count - 1)
    }

    startOlderPagesLoader()                              ← 旧页追赶开始
```

**热重入：** `store.didLoadFirstPage == true`；跳过同步页读取。`store.blocks` 已填充（可能被先前 loader Task 在取消前继续填充）。`dataSource = self` 绑定到完整 block 列表；`layoutSubtreeIfNeeded` 从热 `layouts` 缓存中 tile。`startOlderPagesLoader` 从 `store.nextCursor` 恢复，前提是文件顶尚未到达。

**无 pendingDeltas 队列** —— v5 有一个；v6 不需要。没有事件要排队：Store 从不 emit，VC 直接驱动 loader。

## 6. 折叠 / hover / 状态

Store 拥有状态（§ 2 表）。VC 把用户动作分派给 store：

- **Hover。** `BlockCellView.mouseEntered/Exited` → `delegate.hoveredBlockId = id`。VC setter 记录旧 + 新 id，然后对每一受影响的行调用 `tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? BlockCellView` 并**直接**设 `cell.needsDisplay = true`（v7 review #8 修复 —— 匹配旧 renderer 的 `markGutterRedraw` 成本档次）。**不**走 `reloadData(forRowIndexes:)`，那会为光标经过的每个 cell 重跑 `viewFor`。也**不**做 `noteHeightOfRows`（只是颜色，§ 2.12）。
- **折叠。** `BlockCellView.mouseDown` → `HitAction.toggleFold(id)` → `delegate.toggleFold(id)` → VC 调 `store.toggleFold(id)`。返回宿主 `Block.id` 或 `nil`。**解析规则**（v7 review #11 修复）：输入的 `id` 可能是组宿主 `Block.id` **或** `Block.Kind.toolGroup(group).children` 里的 `Child.id`。`store.toggleFold(id:)` 必须两处都搜：
  ```swift
  func toggleFold(id: UUID) -> UUID? {
      if let idx = blocks.firstIndex(where: { $0.id == id }) {
          folds[id, default: false].toggle()
          invalidateRowLayout(id: id)
          return id
      }
      for host in blocks {
          if case .toolGroup(let group) = host.kind,
             group.children.contains(where: { $0.id == id })
          {
              folds[id, default: false].toggle()
              invalidateRowLayout(id: host.id)
              return host.id
          }
      }
      return nil
  }
  ```
  折叠标志按输入 id（宿主或子）存；layout 逐出针对宿主 block id（那是要 reload 的行）。若输入 id 不认识，返回 `nil`，VC no-op。VC 随后在 `withoutImplicitAnimations` 内：`tableView.noteHeightOfRows(withIndexesChanged: [hostRow])` + `tableView.reloadData(forRowIndexes: [hostRow], columnIndexes: [0])`。匹配 § 2.10。
- **状态。** 仅历史；此处无人写。`statuses` 保持空；子项按 `.completed` 标签渲染。（Live 路径会写；那条路径不在本文档范围内。）

### 6.1 RowLayout.make 签名（v5 保留）

```swift
nonisolated static func make(
    for block: Block,
    width: CGFloat,
    folds: [UUID: Bool] = [:],
    statuses: [UUID: ToolStatus] = [:]
) -> RowLayout
```

薄薄一层壳套在 `Transcript2Coordinator.makeLayout`（已有）上。RowLayout 其它不改。

## 7. 语法高亮回填 —— 本 PR 不做

代码块和 fileEdit diff 的语法高亮回填**不在**本次重构范围内。老 renderer 的 `Transcript2HighlightStorage` 及其 JS engine 回填链路留在 live 路径上不动；新历史 VC 首屏渲染时代码块保持无着色。作为后续 PR 补齐，届时它可以作为一个纯粹的、cell 局部的重绘 concern 接入（不进 Store、不进 `RowLayout`），因为高亮只改颜色不改度量（§ 2.12）。

## 8. `BlockCellViewDelegate`

现存每一处 `coordinator?.…` 变成一个 delegate 方法：

```swift
@MainActor
protocol BlockCellViewDelegate: AnyObject {
    var hoveredBlockId: UUID? { get set }        // BlockCellView.swift:222,223,558,574,575
    var isLiveScrolling: Bool { get }            // BlockCellView.swift:549,556,566
    func toggleFold(id: UUID)                    // BlockCellView.swift:724
    func requestUserBubbleSheet(id: UUID)        // BlockCellView.swift:712（v8 只 log；sheet 在 § 14）
    func requestImagePreview(image: NSImage)     // BlockCellView.swift:720（v8 只 log）
    func handleGutter(_ spec: GutterSpec, blockId: UUID)  // BlockCellView+Gutter.swift:171
}
```

**改名**：`BlockCellView.swift:92` —— `weak var coordinator: Transcript2Coordinator?` → `weak var delegate: BlockCellViewDelegate?`。~10 处调用点 `s/coordinator/delegate/`。

**旧 coord 增量实现协议。** 现存的 `Transcript2Coordinator`（还被 `Session.swift` 的 live 路径构造）已经有全部六个方法；一行 `extension Transcript2Coordinator: BlockCellViewDelegate {}` 搞定。新 `TranscriptViewController` 实现同样六个。两条路径永远不会共享 cell 实例。

## 9. 层边界 —— 什么不删

- `Session.swift` 的所有 render 侧接线（`controller`、`bridge`、`backfillPipeline`）不动。`Transcript2Controller`、`Transcript2Coordinator`、`Transcript2EntryBridge`、`TranscriptBackfillPipeline`、`Transcript2Search/Selection/SheetPresenter`、`Transcript2Scroll/Clip/TableView`、`TranscriptScrollViewFactory`、`CenteredRowView`、`Transcript2HighlightStorage`（仍服务于 live 路径的语法高亮，历史 VC 不使用）—— 全都继续编译并被 live 路径使用。
- `BlockCellView` 里一个必要的 delegate 改名（§ 8）。旧栈的其余部分不动。
- `Content/Chat/NativeTranscript2Bridge/` 里的 `TranscriptBackfillPipeline` 和 `JSONLReversePageSource` 继续服务 `Session.swift` 的 live/backfill 路径。新历史 VC 不用它们；它走 AgentSDK 里的 `SessionHistory.loadPage` / `.stream`。
- SDK：`SessionHistory.load(id:order:)`（v5 加的仅异步 API）删除；`_ReverseBatchPairer` 删除；`_ReverseLineReader` 保留。新 API 面是 `loadPage` + `stream`，都基于 cursor。

## 10. DI 与生命周期

### 10.1 Composition root

`AppDelegate.applicationWillFinishLaunching`：
```swift
let transcriptRegistry = TranscriptRegistryStore()
let appContext = AppContext(..., transcriptRegistry: transcriptRegistry)
sessionManager.onSessionArchived = { [transcriptRegistry] sessionId in
    transcriptRegistry.discard(sessionId)
}
```

### 10.2 Registry `discard(_:)` 接线

`SessionManager.archive(_:)` 在 body 末尾触发 `onSessionArchived?(sessionId)`。`AppDelegate` 把闭包接到 `TranscriptRegistryStore.discard(_:)`。discard 从 dict 里删掉那个 Store —— Store 释放、blocks/layouts 释放。

### 10.3 VC init

`TranscriptViewController(store: TranscriptStore)`。从 `DetailFlowCoordinator.makeChild(.history)` 里的 `DetailContext` 注入。

### 10.4 生命周期

| Owner | 生命周期 | Cancel/dealloc 触发 |
|---|---|---|
| `TranscriptRegistryStore` | 进程 | AppDelegate deinit（实际从不触发）|
| `TranscriptStore`（每 id）| registry 里的它的槽 | archive/delete 时的 `discard(_:)` |
| `TranscriptViewController` | 一次挂载 | Container 移除 → `prepareForRemoval` |
| `loaderTask` | ≤ VC | `prepareForRemoval` 调 `loaderTask?.cancel()` |
| Detached 排版 Task（每次 commit）| 绑定到它的 `await` 返回 | 外围 `loaderTask` 取消 → 下一个 `Task.checkCancellation()` 抛 → detached Task 本身正常跑完（它的 `blocks.map` 不检查取消 —— 直跑到底；结果被丢弃）|

detached 排版闭包本身不可取消 —— `blocks.map { RowLayout.make(…) }` 不是关卡。这没问题：最坏情况是 VC 拆除后有一页量的排版继续跑，然后 `Task.checkCancellation()` 在 `await` 之后抛出时其结果被丢弃。总浪费 CPU：一页量（≤ ~50 blocks × 1–3 ms）。

## 11. 性能对齐 —— 对着 `NativeTranscript2/CLAUDE.md § 2` 逐项

| 旧不变式 | v6 如何保持 |
|---|---|
| § 2.1 缓存命中时同步 `heightOfRow` | `store.layout(for:width:…)` 是 get-or-compute。热缓存 = 命中。首页同步 tile miss（§ 5.1）后写缓存，后续 scroll 命中。 |
| § 2.2 cell `wantsLayer + .onSetNeedsDisplay` | `BlockCellView` 不动。 |
| § 2.3 scroll + clip 上的 `.never` 图层 | 在原样 `NSScrollView` **和** `TranscriptClipView` 上都设。 |
| § 2.4 `[UUID: CachedLayout]` 无 LRU | `TranscriptStore.layouts: [UUID: RowLayout]`；宽度在 store 上；宽度变更时整体失效。 |
| § 2.5 `nonisolated static makeLayout` | `RowLayout.make` 是 `nonisolated static`；loader 的 Phase 2 Task.detached 调它。 |
| § 2.6 回填 off-main 构建 + 同步应用 | 旧页：Phase 2 off-main 排版 → main-hop commit。首页：**main 上同步** —— 见 § 5.1 论证（bounded 到一个 64 KB 页）。 |
| § 2.7 resize 用 in-tick 锚点 | § 5.5 `viewDidEndLiveResize` 在禁用事务内 `noteHeightOfRows` 之后强制 `layoutSubtreeIfNeeded`。 |
| § 2.8 live-resize 只碰可见行 | § 5.5。 |
| § 2.9 负宽度 clamp | `TranscriptClipView.setFrameSize` clamp 到 `max(0, w), max(0, h)`。 |
| § 2.10 抑制隐式动画 | 每一条 commit 路径（loader commit、fold、hover、live-resize refill）都包在 `withoutImplicitAnimations` 里。 |
| § 2.11 无 `reloadData()` | VC 从不调 `reloadData()`。 |
| § 2.12 highlight refill 跳过 `noteHeightOfRows` | 本 PR 不做高亮回填（§ 7）；后续 PR 引入时需保持该规则。 |
| § 2.13/b search / status | 搜索超范围（§ 14）。状态保留为稀疏 dict。 |
| § 2.14 `cacheRowLayouts` 反投毒 | § 5.4。 |
| § 2.15 每 scope 去重 + 世代守卫 | 本 PR 不做高亮回填（§ 7）；后续 PR 保持该不变式。 |
| § 2.16 shimmer overlay | `BlockCellView` 不动。 |
| § 2.17 稳定 row-reuse key | VC 实现 `tableView(_:rowViewForRow:)`，reuse identifier `"TranscriptBlockRow"`；`BlockCellView` reuse identifier `"TranscriptBlockCell"`。两者在 scroll tick 间都稳定。 |
| § 2.18 稳定 `Block.id` | `MessageEntryBlockBuilder` 不动。 |
| § 2.19 每次 attach 一个宽度 | § 5.6 attach 契约 —— 同步首页在 `dataSource = self` 之前填充 blocks，所以首次 `heightOfRow` 在稳定宽度上跑并命中热缓存。Loader 自身的 for-await commit 发生在 attach tick 之后 —— 后续批次搭同一宽度契约。 |

### 11.1 首帧时序

**v9 首帧：** 点击会话 → attach VC → `viewDidLayout` 首次 → `loadFirstScreenSync(viewportHeight:, width:)`（读页 + 逐 block 排版直到视口填满）→ `dataSource = self` → `layoutSubtreeIfNeeded`（纯缓存命中）→ 绘制。**总计：典型 ~20–50 ms（1 页填满窗格）；tool-heavy 尾部 ~40–80 ms（2–3 页）；首消息很高 ~10–30 ms（一个巨大 diff block 超过视口，排完一行后停）。罕见最坏情况：整个会话文件是一段未闭合的可分组 assistant 运行、无 closer —— 秒级；见 § 5.1.1 对该边界的接受。所有非病态情况都零空白闪现。**

**v5 首帧**（如果 v5 没被 revert 会是）：点击 → attach → `viewDidLayout` → 挂订阅 → 等 SDK 第一个 stream yield（~5 ms + Task hop）→ Combine hop 到 main → Task chain 调度 → detached 排版（~10 ms）→ hop 回 → commit → 绘制。**~30–50 ms + 两个 hop 之间一空白帧（16 ms）。**

同步首页折衷：v6 花了些 main 时间但消除了那一空白帧。开会话时的感知响应显著更好，尤其是"点击到首字符"这个指标。

## 12. 测试

单元测试住在 `cctermTests/`，遵循 CLAUDE.md 规则（无 `forceXxxForTest`、不放宽访问；驱动 public 面）。

基线套件：

- **新增**：`TranscriptStoreFirstPageTests` —— 通过临时 URL 注入假 JSONL；断言 (1) `loadFirstScreenSync(viewportHeight: 800, width: 720)` 按文档顺序（旧→新）填充 `blocks`；(2) 累加 block 高度 ≥ 800 pt（视口填满）或到达文件顶（`didFinishLoad == true`）；(3) 调用后 `store.layouts.count == store.blocks.count` —— 每个 block 都被同步排版并缓存；(4) 短文件变体 —— 文件小于一屏 → `nextCursor == nil` AND `didFinishLoad == true`。
- **新增**：`TranscriptStorePrependTests` —— 从已填充的 store 开始，驱动 `prependOlder([b1, b2, b3], newCursor: nil)`；断言 `blocks[0..3] == [b1, b2, b3]` 且 `didFinishLoad == true`。驱动 `cacheRowLayouts` 带不匹配宽度；断言缓存不变；带匹配宽度；断言项已安装。
- **新增**：`TranscriptViewControllerAttachOrderTests` —— 挂载 VC 到 stub Store，驱动 `loadView` + `viewDidLoad` + `viewDidLayout`，断言 `viewDidLoad` 后 `dataSource` 为 nil，`viewDidLayout` 后已设。注入返回 canned Page 的 stub `SessionHistory.loadPage`；断言 `viewDidLayout` 首次返回后 `store.blocks == cannedFirstPageBlocks`。
- **新增**：`TranscriptClipViewCenteringTests` —— 把宽度 500 的 documentView 装到 `TranscriptClipView`，在 proposed 宽度 800 / 500 / 300 处驱动 `constrainBoundsRect`，分别断言 `origin.x = -150 / 0 / 0`。垂直直通。
- **新增**：`SessionHistoryCursorTests` —— 合成 JSONL fixture；断言 `loadPage(cursor: nil)` 返回带 `nextCursor` 的第 1 页；`loadPage(cursor: nextCursor)` 返回第 2 页；迭代到文件顶；最后一页 `nextCursor == nil`。同一 fixture 通过 `stream` —— yield 相同的页序列。
v7 review #12 补充（对 review 标记的形状做显式守卫）：

- **新增**：`TranscriptStoreOpenGroupFirstPageTests` —— fixture：一个 JSONL，其最新 20 条消息是一段未闭合的 `isGroupableAssistant` 运行，紧接一条较旧的文本轮次 close 它。断言 `loadFirstScreenSync(viewportHeight: 800, width: 720)` 走页直到找到 closer（或文件顶），返回时 `blocks.count >= 1`（通常是 1 个组条目包含全部 20 个 tool_uses），累加高度 ≥ viewportHeight 或 `didFinishLoad == true`。病态变体（整个文件是一段可分组运行、无 closer）：循环走到文件顶；`builder.finish()` 把该运行作为一个组条目 flush；返回时至少一个 block。
- **新增**：`TranscriptStoreCommitOrderTests` —— review #1 的回归网。用已填充 store 驱动 `insertOlderBlocksAtTop(blocks: [b1, b2], pairs: [(b1.id, l1), (b2.id, l2)], width: w, newCursor: nil)`。断言 (1) commit 后 `store.layouts[b1.id] == l1` AND `store.layouts[b2.id] == l2` —— 若代码在 prepend 之前写 layouts 会失败（`layouts[bN.id] == nil`），因为 stale-block 过滤 `Set(store.blocks.map { $0.id })` 会排除新 id 并丢每个 pair。断言 (2) —— 验证"没有懒重排版" —— 从本测试删掉；测量"没有 `RowLayout.make` 调用发生"需要一个调用计数接缝，CLAUDE.md 禁止为测试加这种接缝。断言 (1) 是充分的回归网：若 layouts 已缓存，`heightOfRow` 按构造返回缓存高（它是 `layouts[id] ?? make(…)`）；若 layouts 被丢，`heightOfRow` 排版。就 store 的公共契约而言，缓存填充与 heightOfRow 行为在功能上等价。
- **新增**：`TranscriptStoreWarmCacheTests` —— review #3 的回归网。填充 store；模拟 VC 卸载（registry 保留 store）；模拟同宽度重挂；断言 `setLayoutWidth(sameW)` 后 `layouts.count` 不变。驱动 `setLayoutWidth(differentW)`；断言 `layouts.count == 0`。
- **新增**：`TranscriptViewControllerCancellationTests` —— 构造 VC + yield 缓慢 stream 的 stub loader；stream 中途驱动 `prepareForRemoval`；断言 `loaderTask?.isCancelled == true` 在一个 main tick 内且拆除后无 `insertRows` 触发。
- **新增**：`TranscriptViewControllerAnchorMathTests` —— prepend 锚点 delta 计算。给定稳定高 fixture（每行 60pt），视口在 clip.origin.y=1200、首可见行 = 20 rect.minY=1200；驱动 `insertOlderBlocksAtTop` 5 行批次。断言 commit 后 clip.origin.y = 1200 + 5×60 = 1500（视觉顶部行保持）。用可变高度重复。
- **新增**：`TranscriptViewControllerProgrammaticWidthTests` —— review #5 的回归网。模拟初次 attach 后带 `tableView.bounds.width` 改变的 `viewDidLayout` 调用；断言 `retileAtNewWidth` 触发（layout 缓存清空并重播种；loader 重启）。模拟未变宽度的第二次 `viewDidLayout`；断言 no-op（缓存不动、loader 不动）。

## 13. Rollout

1. **SDK**：加 `SessionHistory.Cursor` + `Page` + `loadPage(sync)` + `stream(async)`。删旧的 `load(id:order:)`。删 `_ReverseBatchPairer`。Cursor 测试。
2. 加 `TranscriptClipView` + `BlockCellViewDelegate`。
3. 扩宽 `RowLayout.make` 签名（§ 6.1）—— 与 v5 相同的壳。
4. 重构 `BlockCellView`（`coordinator → delegate`）；一行 `extension Transcript2Coordinator: BlockCellViewDelegate {}`。
5. 按本文档重写 `TranscriptStore` + `TranscriptViewController`。
6. 接 `discard(_:)`（§ 10.2）—— `SessionManager.onSessionArchived` 闭包。
7. Clean build；跑新测试；手动验证 (a) 开会话响应快、无空白闪现；(b) 滚到顶部加载旧页；(c) 侧边栏切走/回来保持位置和缓存；(d) 窗口 resize 重新缩放 460..780 带并重排 tile 可见行。
8. 后续 PR：跨行**选择**（把 `Transcript2SelectionCoordinator` 等价物作为新 `TranscriptSelectionStore` 拉回 —— API 草图见 § 14）。
9. 后续 PR：把旧 renderer 栈从 `Session.swift` 里拆出来。
10. 后续 PR：顶部/底部 scrim overlay。
11. 后续 PR：用户气泡 sheet + 图像预览 sheet + transcript 内 ⌘F 搜索。

## 14. 范围外

以下每项都是后续 PR。相互不阻塞。

- **选择**（跨行文本拖 + ⌘C 复制）。样式对齐是本 PR 重点；选择与 loader/store 形状正交。后续草图：新 `TranscriptSelectionStore`（`TranscriptStore` 拥有，因为选择状态应像折叠那样在侧边栏切走时存活），由从 `BlockCellView` 通过 delegate 协议转发的鼠标事件驱动。渲染路径用旧 renderer 用的同一个 `SelectionAdapter`；store 的 `snapshot()` 喂给 `viewFor` 的 `cell.selection = …` 写。
- 用户气泡全文 sheet 和图像预览 sheet（`BlockCellViewDelegate.requestUserBubbleSheet` / `requestImagePreview` `.info` log 并 no-op）。
- Transcript 内 ⌘F 搜索。
- 把旧 renderer 栈从 `Session.swift` 里移除。
- 顶部/底部 scrim overlay。

## 15. 本计划明确拒绝的（v5 → v9 事后分析）

为后世记录 —— 早期版本尝试过、v9 不会采用的形状：

| v5（被拒绝）| 原因 | v6 替换 |
|---|---|---|
| `store.events: PassthroughSubject<BlockDelta, Never>` + VC 里 `.receive(on: .main).sink` | 多一次调度 hop + 一 runloop tick 延迟。`AsyncThrowingStream.next()` 已经在等待的 task 的 actor 上 yield。 | VC 拥有 for-await 循环；直接 commit。 |
| VC 里的 `visibleBlocks: [Block]` 镜像 | 两个真相源。只在 Store 的 `blocks[]` 被在与 VC 的 `insertRows` 不同 tick 里 mutate 时才需要。 | Store 在与 `insertRows` **同一** MainActor tick 里 mutate；dataSource 直接读 `store.blocks`。 |
| `applyChain: Task<Void, Never>?` —— 每次新 apply 等前一个 | 只在 Combine 可能在一 tick 里递交两个 delta 且无背压时才需要。 | for-await 循环本身天然串行。 |
| 每 commit 路径守卫的 `isReleased: Bool` | 防止 detached Task 在拆除后落到已 nil 的 dataSource 上。 | `Task.cancel()` + 三个循环关卡的 `Task.checkCancellation()`。 |
| `SessionHistory.load(id:order:)` 仅异步、无 cursor | 无法支持首屏同步；无法从保存位置恢复。 | `loadPage(sync)` + `stream(async)` 都基于 cursor；同步用于首屏。 |
| SDK 的 `_ReverseBatchPairer`（重复了 app 侧的 `ReverseEntryBuilder.withheld`）| tool_use↔tool_result 配对不变式有两个实现。 | SDK yield 原始页；app 侧 `ReverseEntryBuilder` 配对。 |
| 通过 detached 排版强制 tail 的 Phase 1 走 off-main | 对旧页追赶正确，对首屏错误 —— 在开会话时引入一空白帧。 | 首屏在 main 排版（bounded）；旧页 detached。 |
| Layout 宽度守卫静默丢弃首个 `cacheRowLayouts`（`layoutsWidth == 0`）| 隐藏性能 bug —— 本应作为缓存预热的调用变成 no-op，`heightOfRow` 反而懒排版。 | VC 在任何排版之前调 `store.seedWidth(w)`。 |
| `insertOlderBlocksAtTop` 里滚动锚的 `firstVisibleRow != NSNotFound` | `NSTableView.rows(in:)` 空时返回 `(0, 0)`，不是 `NSNotFound`。守卫永远为真。 | `visibleRange.length > 0`。 |
| §14 悄悄把选择列为范围外而未经用户同意 | 选择在旧 renderer 里能用；悄悄延后是功能回归。 | 选择**明确**留在本 PR 之外（§ 14）并附一份后续草图。 |
| v6 `insertOlderBlocksAtTop` 在 prepend blocks **之前**写 layouts | `cacheRowLayouts` 按 `Set(store.blocks.map { $0.id })` 过滤 —— 新批次 id 还不"活"，每个 layout pair 被静默丢弃，`heightOfRow` 在 main 上懒排版 | § 5.3 —— 换序：`prependOlder` 先，`cacheRowLayouts` 次，`insertRows` 后 |
| v6 `applyFirstPage` 可能返回零个 blocks（未闭合组没在头 64 KB 里 close）| `ReverseEntryBuilder` 从不投机 emit 未闭合的可分组 assistant 运行；tail-heavy 会话会以空白窗格开会话直到 async loader 首次 commit | § 5.1.1 —— bounded 循环（`maxPages: 8`、`deadline: 100 ms`），持续读同步页直到较旧的非可分组消息 close 该运行 OR 到达文件顶（`builder.finish()`）OR 预算耗尽 |
| v6 `seedWidth` 无条件清缓存 | 相同宽度的热重入会在 main 上重排每个可见行，破坏"瞬时切回"目标 | § 5.4 —— `seedWidth` 用 `if w != layoutsWidth { … }` 守卫；同宽度重入 no-op |
| v6 丢掉了 `rowViewForRow` reuse identifier | § 2.17 回归 —— NSTableView 每 scroll tick 分配新 row view | § 4.2 —— VC 实现 `tableView(_:rowViewForRow:)` 用 identifier `"TranscriptBlockRow"` |
| v6 只在 `viewDidEndLiveResize` 处理宽度变更 | ⌥⌘S / 侧边栏折叠 / split-view 程序化 resize 会留下陈旧 `layoutsWidth`；下次 scroll 会在 main 上懒排版每个可见行 | § 5.5 —— 每次 attach 后的 `viewDidLayout` 都比较 `tableView.bounds.width` 与 `store.layoutsWidth`；漂移触发 `retileAtNewWidth`（`viewDidEndLiveResize` 仅作为优化信号保留）|
| v6 `AsyncThrowingStream` 使用默认（无界）缓冲 | 快速磁盘读会在缓冲里累积整个文件、跑在稳步 consumer 前面 | § 2 SDK 行 —— stream 通过 `AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))` 构建 |
| v6 loader 在宽度已经变更并丢弃 layouts 后仍继续 commit | `prependOlder` 仍安装 blocks，`cacheRowLayouts` 被宽度守卫丢，`heightOfRow` 在 resize 时对每新行在 main 上懒排版 | § 5.5 —— 宽度变更触发器 `cancel()` 当前 `loaderTask` 并调用 `startOlderPagesLoader()`，它在新宽度下从 `store.nextCursor` 重新 await |
| v6 hover 通过 `reloadData(forRowIndexes:)` 重绘 | 为光标经过的每个 cell 重跑 `viewFor` + 调和 SubviewPlan —— 每个 hover 事件一次 viewFor 往返 | § 6 —— hover 路径用 `tableView.view(atColumn: 0, row: r, makeIfNecessary: false)` + `cell.needsDisplay = true` 直接；匹配旧 renderer 的 `markGutterRedraw` 成本 |
| v6 未拼写 `contentWidth` | 实现者可能选 `view.bounds.width` 或 `clipView.bounds.width` —— 两个都错；会静默重新引入 v5 layoutsWidth 不匹配 bug | § 5.6 —— `contentWidth = tableView.bounds.width`，在 `view.layoutSubtreeIfNeeded()` 之后读 |
| v6 `toggleFold(id:)` 返回语义模糊 | 若实现者忘了把 `id` 对 `Block.Kind.toolGroup.children` 解析，子标题点击会静默 no-op | § 6 —— 完整解析算法内联；同时搜 `blocks[*].id` 与 `blocks[*].kind.toolGroup.children[*].id`，返回宿主 block id |
| v7 attach 契约在 § 5.1.1 定义了 `loadFirstScreenSync` 但 § 5.6 仍直接调 `loadPage(cursor: nil)` | 防止未闭合组空首屏的 bounded 循环没接上 —— 死代码 | § 5.6 attach 路径调用 `try store.loadFirstScreenSync()` |
| v7 SDK stream buffering 声明（`.bufferingNewest(1)`"producer 等 consumer"）是错的 | `.bufferingNewest(1)` 是**静默丢弃**溢出的页，而不是阻塞 producer；会在反向游走里引入间隙并在页缝处静默损坏 transcript | § 2 SDK 行 —— stream 使用 `AsyncStream(unfolding:)` 风格的需求驱动迭代器 OR 显式 await consumer 需求的成对 continuation producer；producer 轮询 `Task.checkCancellation()` 让 consumer 取消终止 producer |
| v7 `retileAtNewWidth` 在每次 `viewDidLayout` 宽度漂移时无条件触发 | 即使 1 像素抖动的 live-resize 拖拽也会取消+重启 loader，并每帧生成一个 Task.detached 排版 —— 拖拽抖动 + producer 泄漏 | § 5.5 —— `viewDidLayout` 路由：`inLiveResize` 路径 → 便宜的 `handleLiveResizeTick`（仅让可见失效）；非拖拽漂移 → 完整 `retileAtNewWidth`。`viewDidEndLiveResize` 跑延后的完整重定位 |
| v7 `loadFirstScreenSync` deadline 描述为硬 100 ms 上限 | Deadline 只在循环头检查；一个页的 fileEdit-diff 构建可能超到 ~200 ms | § 5.1.1 —— deadline 老实地标为软；`maxPages`（8）是硬边界；§ 11.1 首帧表更新 |
| v7 `TranscriptStoreCommitOrderTests` 断言 (2) 试图观察"没有重排版发生" | RowLayout 是纯值；缓存命中和懒重排版产出相等的 struct —— 没有 `RowLayout.make` 调用计数器接缝就没有可观测差别，而 CLAUDE.md 禁止为测试加这种接缝 | § 12 —— 断言 (2) 删掉；断言 (1) 足够（缓存已填充 ⇒ heightOfRow 按构造是命中）|
| v7 § 2 store API 列表缺 `advanceCursor(to:)` 和 `markFinished()` | § 5.2 loader body 引用了两者；API 面不完整 | § 2 store 行 —— 两者加到同步 mutation API 列表 |
| v7 只 log 的 delegate 方法被文档为"v6 只 log" | 前一版遗留标签 | § 8 —— 更新到 v8 |
| v7 `SessionHistory.stream` 的 detached producer 未检查取消 | Consumer 取消会让 producer 继续走到文件顶，每次宽度抖动都生成新 producer —— 累计泄漏 | § 2 SDK 行 —— producer 在 yield 循环内轮询 `Task.checkCancellation()`；consumer 取消让它终止 |
| v8 `loadFirstScreenSync(minBlocks:maxPages:deadline:)` —— 三个魔法数、没一个对应实际目标 | 目标是"填一次可见窗格"；三个启发式都没表达它。典型情况过读（1 页填屏时读 8 页），病态情况欠填（8 页 bail 出剩空白）| § 5.1.1 —— 签名是 `loadFirstScreenSync(viewportHeight:width:)`。一个终止标准（`heightSoFar >= viewportHeight` 或文件顶）；循环内逐 block 同步排版在 `dataSource = self` 之前预热缓存 |
| v8 首屏路径依赖 `layoutSubtreeIfNeeded` 懒排版可见行 | 两步预热：循环里构建 blocks，然后 tile pass 排版。§ 2.19 attach 契约的歧义 —— "tile 到底在什么宽度上跑？" | § 5.1.1 —— 排版通过 `store.layout(for:width:…)` 在循环内发生。到 `dataSource = self` 触发时，每个相关行都在完全相同宽度上有缓存 layout。Attach tile 100% 缓存命中 |
| v8 尝试为病态未闭合组运行做"安全 bail-out"（首屏空 → 交给 async）| 两种替代都在开会话时冻结用户。bail-out 意味着"用户看空白然后延迟绘制"；同步走到顶意味着"用户等一次得到真绘制"。UX 上无胜者；工程上简单胜出 | § 5.1.1 —— 无安全上限。循环仅在视口填满或文件顶时终止。罕见最坏情况（巨型未闭合组文件多秒冻结）接受 |
| v9 因为 live 路径用而在历史路径保留 `MessageEntry` + `MessageEntryBlockBuilder` | 因为它在就复用，而非"新架构需要它吗？" MessageEntry 是没人读的透传；两步 builder 管线不必要地强制 Phase 1 走 `@MainActor` | § 2 —— 新 `MessageBlockBuilder`（nonisolated、正向、方向无关）。直接 `Message2 → [Block]`。Phase 1 后续可移出 main。历史路径去掉 `MessageEntry` 引用；live 路径分别保留自己 |
| v9 在 v6 误判 SDK 的 `_ReverseBatchPairer` 为重复后把跨页 tool-result 配对推给 app 侧（`ReverseEntryBuilder.withheld`）| 配对是 stream 层不变式（页 yield 孤儿 tool_result 而无它的 tool_use 是不完整数据）；推给上层意味着 app builder 必须反向以推理 withheld 状态 | § 2 SDK 行 —— `_WithheldTools` 恢复到 SDK 内。SDK 保证 yield 出的每一页正序且 tool 对完整。App 侧 builder 可以只正向 |
| v9 名字 `ReverseMessageBlockBuilder` | 遍历方向是 stream 层关心的事（SDK 里的字节游走），不是 builder 关心的。按 SDK 实现细节命名会上泄 | § 2 —— `MessageBlockBuilder`。同一个 builder 被 live 路径复用（自然是正向）|
| v10 首版名 `applyOlderBatch` / `startBackgroundLoader` / `runStructuralUpdate` / `commitOlder` / `performLiveResizeFrame` / `performWidthChange` | 都模糊 —— "batch"什么、"background"什么、"structural"什么、"commit"什么、"perform frame"什么。§ 3 嗅探：删掉周围上下文后名字还有意义吗？没有 | § 3.1 改名表 —— `prependOlderBlocks` / `startOlderPagesLoader` / `withoutImplicitAnimations` / `insertOlderBlocksAtTop` / `handleLiveResizeTick` / `retileAtNewWidth`。动词 = 动作；对象 = 被作用的东西 |
| v9 名字 `cacheLayouts` / `invalidateLayout` / `layout(for:...)` | "Layouts"不够具体 | `cacheRowLayouts` / `invalidateRowLayout` / `rowLayout(for:...)` |
| v10 初始 `HistoryBlockBuilder` 提案 | 按 caller（历史路径）命名，而非按它是什么（Message2→Block）命名 | `MessageBlockBuilder`。本次会话同一反模式的第三例（在 `visibleBlocks` 镜像和 `MessageEntry` 复用之后）—— 由此把 § 3.1 规则提升 |

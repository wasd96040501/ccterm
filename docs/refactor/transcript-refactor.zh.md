# Transcript 重构 —— history load，完全重构 transcript view

## 总纲

**完全重构 transcript view，本次仅涉及 history load。**

- **完全重构**：不复用老栈的架构、类型、trick 逻辑。老栈（`Block` / `BlockCellView` / `Transcript2*` / `Session.swift` render 侧接线 / `MessageEntry*` / `NativeTranscript2Bridge`）**只用作事实性信息参照**（比如 tool_use↔tool_result 配对是什么语义、`isGroupableAssistant` 谓词判什么），不作为形状 / 命名 / 状态机的参考。老栈本 PR 不动，作为 live 路径的现役实现继续存活；下一 PR 才拆。
- **本次仅 history load**。不涉及 live、不涉及 `SessionManager`、不涉及会话生死。VM 不留 live 入口，Store 不留 `appendNewItems`，不提"未来源无关"。
- **`RowLayout` 复用，只允许小改**（切除掉对老 `Block` 的依赖，改成看新 `TranscriptItem`）；老 `BlockCellView` 的绘制逻辑**参考迁移**到新 row view 类里（因 tableView→outlineView，绘制部分需要新的容器载体），但**不保留** `BlockCellView` 类本身。除此以外老栈不复用。
- **完全按顶层 `CLAUDE.md` 规范**。本文档每处组件、每处流程都对应到一条或多条具体规范；出现"规范上应该 A 但 B 更好写"的场景，答案永远是 A。**不允许 trick**、**不允许妥协**。
- **不允许功能降级**（相对老 renderer 现有可见能力）：tool 组 fold、tool 内 body fold、hover 反馈、markdown 各 kind 渲染、user bubble、image attachments、每种 tool body 样式与复制按钮、锚点保持的旧页追加 —— 全部等价可用。
- **"Deferred" ≠ "downgraded"**：语法高亮回填、⌘F 搜索、跨行选择、user bubble / image preview sheet 在老栈里是可开关的独立 concern；本 PR 只搬 history 渲染主干；接口位置留好（Delegate 面上有 stub 方法、Store/VM 上无绑死点），后续 PR 补齐时不改本 PR 交付类。

## 0. 一条不变式

> **VM 是幂等的纯派生函数 `f(store.items) -> outlineTree`。** outline tree 结构完全由 `items` 决定；`folds` 只影响 view 展开态，不影响 tree 结构。派生、apply、几何 tile 都在同一 runloop 的 source phase 里落地，beforeWaiting 时统一 flush。

结论：
- **Store 是唯一真值源** —— items（消息序列）+ folds（展开态）+ cursor（分页位）+ `lastKnownScrollAnchor`（滚动位）都在 Store。VM 无独立可变状态：`deriveOutline` 期间的 `pending` map 一次扫完即弃；outline node 复用池随 VM 释放。
- **VM 生命周期 = VC 生命周期**（顶层规范："One VC's presentation state → that VC's ViewModel's `@Published`"）。跨 mount 的状态（items / folds / cursor / 滚动位）都在 Store 里（Store 属 Session 域，registry 只加不减）。**VM 不能被缓存**。
- **Controller 订阅两个 publisher**：`store.$items` → 经 VM 派生变成 `viewModel.$outline` → `applyOutline`；`store.$folds` → 直接 `applyFolds`。fold 事件从 outline view 上来时 Controller 直接写 `store.setFold(...)`，不再经 VM 转发（VM 在 fold 面上无派生职责）。
- 无 `visibleItems` 镜像、无 `applyChain`、无 `isReleased` 位、无 `Combine.PassthroughSubject` 桥接 —— 都不需要。

## 1. 目标

1. **按 `transcriptId: String` 读**；Store 住 app 域 registry；侧边栏切走再回来 items + folds + 滚动位完整保留（跨 mount 的状态住 Store）。
2. **数据类型不 `import AppKit`**：`TranscriptItem` / `TranscriptOutlineNode` / `ToolGroupHeader` / `ImageRef` 都在不 import AppKit 的文件里。
3. **一条 `TranscriptItem` = 一个 outline view item**。**不允许 enum case 塞列表** —— markdown block（heading / paragraph / codeBlock / list / table / blockquote / thematicBreak）每种独立 case，每条一 outline row；user attachments 每张图独立一条；group 也是独立一条（`TranscriptItem.toolGroup(ToolGroupHeader)`）。**Builder 不产 group** —— builder 把 SDK 消息拆成"平的" `TranscriptItem` 序列；**VM 在派生 outline 时插入 group items**、生成 header、组织父子关系。
4. **首屏同步、旧页异步**：SDK 提供 `Cursor` + sync `loadPage` + async `stream`。首屏在 `viewDidLayout` 首次的 source phase 里完成"读页 + 建 items + VM 派生 outline + 可见行高度入缓存 + attach dataSource + apply"；beforeWaiting flush 时首帧就绘完，零空白闪现。
5. **两级 native fold**：group 和 tool 都是 `NSOutlineView` 的 expandable node，走 `expandItem` / `collapseItem`。fold 状态住 Store，跨 mount 生存。
6. **性能 ≥ 老 renderer**：老 `NativeTranscript2/CLAUDE.md § 2` 的每一条不变式在新形状下都有映射，见 § 10。
7. **布局对齐**：460..780 clamp 中央 clip、`contentInsets top: 56 / bottom: 112` 原样。

## 2. 组件

每一行给出：组件名 · 角色 · 覆盖范围 · 对应的 CLAUDE.md 规范条目 · 关键依赖。

### 2.1 `TranscriptItem`（Model）
- **范围**：`struct`（值语义）。**一条 `TranscriptItem` = 一个 outline view item**。字段：`let id: TranscriptItem.ID`（`struct ID: Hashable` wrap `String`）+ `let kind: Kind`。
- **`Kind` case 一一对应"一个 outline row 该显示什么"**，**不允许**在 case 里塞列表 / 子结构。case（按类别）：
  - **User 侧**：`.userMarkdownHeading(level: Int, inlines: [Inline])` / `.userMarkdownParagraph([Inline])` / `.userMarkdownCodeBlock(language: String?, code: String)` / `.userMarkdownList(ListPayload)` / `.userMarkdownTable(TablePayload)` / `.userMarkdownBlockquote([Inline])` / `.userMarkdownThematicBreak` / `.userAttachmentImage(ImageRef)`（**每张图独立一条**，不 `[ImageRef]`）/ `.userToolResult(toolUseID: String, ToolResultPayload)`
  - **Assistant 侧**：`.assistantMarkdownHeading(level: Int, inlines: [Inline])` / `.assistantMarkdownParagraph([Inline])` / `.assistantMarkdownCodeBlock(language: String?, code: String)` / `.assistantMarkdownList(ListPayload)` / `.assistantMarkdownTable(TablePayload)` / `.assistantMarkdownBlockquote([Inline])` / `.assistantMarkdownThematicBreak` / `.assistantThinking(String)` / `.assistantToolUse(ToolInvocation)`
  - **VM 生成的**：`.toolGroup(ToolGroupHeader)`（VM 在派生时插入 outline tree —— 见 § 6.1；builder 不产此 case）
  - **透明**：`.systemMeta(SystemMetaKind)`（VM 在派生时**跳过**，不产 outline node、不影响 group 合并 —— 见 § 6.1 skip 语义）
- **`ID` 派生（三元组）**：`ID = "\(stableMessageID)#\(contentIndex)#\(blockIndex)"`。
  - `stableMessageID` = `Message2Assistant.uuid` / `Message2User.uuid`，若为 nil 则 fallback `"page@\(pageCursor.rawValue)/msg\(indexInPage)"`（页级稳定，跨会话 open 无需保持）。
  - `contentIndex` = `Message2` `content` 数组的下标（同一条 message 内不同 content block 区分）。
  - `blockIndex` = 该 content 展开出的 markdown block 序号（`.text` 一条 content 展开成 N 个 markdown block 时 blockIndex 0..N-1；非 markdown content case `blockIndex = 0`）。**三元组确保**：markdown 拆多 block 时 id 互不碰撞。
- **`ToolGroupHeader` 的 id 派生**：VM 派生时用 `"group#\(group 内最新一条 assistantToolUse item.id)"`（即 wall-clock 最后一条 —— **尾锚定**）。理由：跨页合并只在 group 头部加入更旧 tool_use，group 尾不变，所以尾锚定 id 跨页合并保持稳定；用第一条（头锚定）会因跨页合并让 id 漂移，展开态丢失。
- **规范**：MVVM Model；`struct` 值语义（顶层 `CLAUDE.md`："Data → Model. A value type (`struct`/`enum`)"）；不 import AppKit；数据类型无后缀；不含 `NSImage`（`ImageRef` 是外部资源 handle：URL / asset id）。**明确不含**：group children / title 派生 / status / layout / height —— 分别是 VM 关注 / VM 派生 / runtime 状态 / View 层 / Controller 缓存。

### 2.2 `TranscriptItemBuilder`（Builder，无状态）
- **范围**：`enum` + `static func makeItems(from message: Message2, pageCursor: SessionHistory.Cursor, indexInPage: Int) -> [TranscriptItem]`。一次调用只看一条 `Message2`；无实例字段、无跨消息记忆；输出 0..N 条。
- **拆分规则**：
  - `.text(Message2AssistantMessageContent.Text)` 里的 markdown source 走 `Components/Markdown` 解析成 GFM block 序列，**每 markdown block 一条 `TranscriptItem`**（heading / paragraph / codeBlock / list / table / blockquote / thematicBreak 分别对应一个 `.assistantMarkdown*` case），`blockIndex` 从 0 递增。
  - `.thinking(...)` → 一条 `.assistantThinking`（`blockIndex = 0`）。
  - `.toolUse(...)` → 一条 `.assistantToolUse`（`blockIndex = 0`）。
  - user `.text` markdown 同上、`.image` 每张一条 `.userAttachmentImage(ImageRef)`（每张图独立 `contentIndex`）、`.toolResult` 一条 `.userToolResult`。
  - 系统类消息（`.system` / `.result` / `.progress` / `.streamEvent` / `.customTitle` / `.fileHistorySnapshot` / `.lastPrompt` / `.promptSuggestion` / `.queueOperation` / `.rateLimitEvent` / `.worktreeState` / `.unknown`）→ 一条 `.systemMeta(SystemMetaKind)`。VM 侧对 `.systemMeta` 走 **skip 语义**（不产 outline node、不参与 group 合并判定 —— 见 § 6.1）。
- **不做**：tool_use↔tool_result 配对（VM 做）、group 合并（VM 做）、`.toolGroup` item 生成（VM 做）。
- **规范**：`Builder` 后缀允许 —— 顶层 `CLAUDE.md` 命名规范里明列，仅当无状态时使用；`enum` + `static` 从类型层强制无状态契约；不 import AppKit；单元可测（喂 `Message2` fixture、断言输出）。

### 2.3 `TranscriptStore`（Store）
- **范围**：`@MainActor final class`。**是 Session 域的 state holder** —— 跨 mount 生存（存 registry 里）。字段：
  - `@Published private(set) var items: [TranscriptItem]`（wall-clock 正向 —— `items[0]` 最旧、`items.last` 最新）
  - `@Published private(set) var folds: [TranscriptItem.ID: Bool]`（fold 状态住 Session 域，跨 mount 保留 —— 顶层 `CLAUDE.md`："State lives at the lowest scope shared by all its readers"；folds 的 readers 是"这次 mount 的 VM" + "未来 mount 的 VM"，lowest scope = Session）
  - `var lastKnownScrollAnchor: (nodeID: TranscriptItem.ID, offsetFromClipTop: CGFloat)?` —— 侧边栏切走再回来时恢复滚动位所用。Controller 在 `prepareForRemoval` 写入；attach 时读取。
  - `private(set) var nextOlderCursor: SessionHistory.Cursor?`
  - `private(set) var didLoadFirstScreen: Bool` —— 首次 mount 时 Controller 的 `viewDidLayout` 里 `if !store.didLoadFirstScreen { runSyncFillLoop() }`。二次 mount（同一 transcriptId 再进）时 `didLoadFirstScreen == true`，Controller 跳过 sync loop 直接 attach + reload。
  - `private(set) var didFinishLoad: Bool` —— 到达文件顶。loader 早退用。
  - `let transcriptId: String`
- API（都是 `@MainActor` 同步方法）：
  - `prependOlderItems(_ new: [TranscriptItem], nextCursor: SessionHistory.Cursor?)` —— 前置到 items 头部（首屏首批 = 空 store 上 prepend；旧页追加 = 已有 store 上 prepend）；首次调用后置 `didLoadFirstScreen = true`；`nextCursor == nil` 自动翻 `didFinishLoad = true`
  - `setFold(itemID: TranscriptItem.ID, expanded: Bool)` —— 更新 folds dict；Controller 从 outline view 事件回写此处
  - `setScrollAnchor(nodeID: TranscriptItem.ID, offsetFromClipTop: CGFloat)` —— Controller 拆除时调
- **明确不含**：`appendNewItems`（无 live）、`discard()`（无 SessionManager 接线，Store 生存到进程末尾 —— 见 § 9）、layouts、highlights、group 树 —— 分别对应本 PR 无 live / registry 只加不减 / Controller 缓存 / 下一 PR / VM 派生。
- **规范**：Store 后缀 —— 顶层 `CLAUDE.md` state holder（noun-oriented），"cache holds a body of state and publishes its changes"；不含 UI；不 import AppKit；由 initializer 注入构造依赖（`transcriptId`、SDK entry 是 `enum` 静态方法，直接调不注入）；`@Published` 是它对外唯一事件面。

### 2.4 `TranscriptRegistryStore`（Store）
- **范围**：`@MainActor final class`。字段：`private var stores: [String: TranscriptStore]`。API：`store(for transcriptId: String) -> TranscriptStore` —— get-or-create。**只加不减** —— 本 PR 不接 `SessionManager` 或任何 session 销毁事件。一个 `TranscriptStore` 内存量小（items 数组 + folds dict），进程存活期累积可忽略；若日后 registry 需要淘汰，走 LRU cap，是**下一 PR 的事**。
- **规范**：Store 后缀；进程级 state holder（app scope）；不是单例 —— 从 composition root 装配、通过 `AppContext` 注入到 `DetailFlowCoordinator`；不 import AppKit。**明确不做**：discard、和 SessionManager 挂钩、监听任何外部事件。

### 2.5 `TranscriptOutlineNode`（VM 域 presentation node，class）
- **属于 VM 域**（**不是** Model 桶）—— 这个类型的形状由 View 层需求（`NSOutlineView` 需要对象身份记 expand state）决定，塞进 Model 桶会破坏"Model 不知 View 存在"的规范。本 PR 把它明确定位为 **VM 派生输出的 presentation node**，与 `TranscriptOutlineTree` 一起构成 VM 对 outline view 的公共面。
- **范围**：`final class`。字段：
  - `let id: TranscriptItem.ID` —— 直接沿用所载 `TranscriptItem` 的 id；VM 无需另造一层 id
  - `let item: TranscriptItem` —— 该 node 显示的内容
  - `internal(set) var children: [TranscriptOutlineNode]` —— VM 在 `deriveOutline` 里写；跨文件（VM 在自己的文件里写）需要非 `fileprivate`；对外呈 read-only 语义（Controller / row view 只读，不改）。
- **`Equatable` / `Hashable` 按 `id`**；`NSOutlineView` API 侧作 `Any` 用，比较靠对象身份即可。
- **class 而非 struct 的理由**：`NSOutlineView.expandItem(_:)` 记录展开态用**对象身份**；跨 `deriveOutline` 若同一 item id 每次都是新实例 → outline view 认不出，展开态每次 reload 丢。VM 内部维护一张按 `id` 复用实例的池（见 § 2.7 `outlineNodePool`），保证同一 id 的 node 引用稳定。
- **规范**：**不 import AppKit**（"outline" 是通用 tree 语义，class-ness 由 VM 域的 outline view 需求驱动但类型本身不看 AppKit 类型）；数据类型无后缀；VM 拥有；View 层只读。

### 2.6 `ToolGroupHeader`（Model）
- **范围**：`struct`。字段：`let activeTitle: String`、`let expandedActiveTitle: String`、`let completedTitle: String`、`let toolCount: Int`、`let representativeToolKind: String`（数量最多的 tool kind，用来选 icon）。
- **派生规则**：VM 在 `deriveOutline` 里收拢一段可分组连续段后，用其中 `.assistantToolUse` 的 `ToolInvocation.name` 频次分布 + 数量派生。history 场景下所有 tool 都 completed，`completedTitle` 是唯一展示（比如 "3 tool calls"）；`activeTitle` / `expandedActiveTitle` 字段保留以对齐老 renderer 视觉结构（避免降级），本 PR 派生时置为与 `completedTitle` 相同值。
- **规范**：`struct` 值语义 Model；无后缀；`Equatable`；不 import AppKit；VM 派生产出；user-visible 字符串走 `String(localized: …)` + `Localizable.xcstrings`（顶层 `CLAUDE.md` 国际化规范）。

### 2.7 `TranscriptViewModel`（ViewModel）
- **范围**：`@MainActor final class`。**生命周期 = VC 生命周期**（每次 mount 新建，`prepareForRemoval` 时随 VC 释放）—— 顶层 `CLAUDE.md`："One VC's presentation state → that VC's ViewModel's `@Published`"，VM 不允许被 registry / Store 缓存。
- 构造：`init(store: TranscriptStore)`（strong hold —— VM 生存期内 Store 不会被释放，`AppContext` 生存期覆盖）。
- 字段：
  - `let store: TranscriptStore` —— 数据源引用
  - `@Published private(set) var outline: TranscriptOutlineTree` —— 派生输出
  - `private var outlineNodePool: [TranscriptItem.ID: TranscriptOutlineNode]` —— 按 id 复用 outline node 实例的"池"（不是 cache）：每次 `deriveOutline` 从头到尾都要给每个到达的 id 走一遍取/建，扫描末尾对未 reach 的 id 做 `pruneOutlineNodePool`。目的是让同一 id 跨 `deriveOutline` 调用返回**同一个对象引用**，使 `NSOutlineView.expandItem` 的展开态记忆有效。
  - `private var cancellables: Set<AnyCancellable>`
- 内部：`private func deriveOutline(items: [TranscriptItem], pool: inout [TranscriptItem.ID: TranscriptOutlineNode]) -> TranscriptOutlineTree` —— **纯函数**，forward-scan + pending map（详 § 6.1）。调用者传自己的池；VM 自身派生用 `&outlineNodePool`；旧页 loader 的 dry-run preview 传一个 local 空 dict（不污染真池）。同一段代码两种池模式，无重复实现（**没有** `previewOutline` 孪生方法 —— 直接调 pure fn 即可）。
- **构造流程**（初始 derive + 订阅）：
  ```swift
  init(store: TranscriptStore) {
      self.store = store
      // 立即用 store 当前 items 做一次派生 —— 覆盖二次 mount（pre-populated store）与
      // 单元测试（inject fixture 后构造）两条真实使用路径
      self.outline = Self.emptyTree
      _ = self.recomputeOutline()
      // 订阅后续变化。不 dropFirst：@Published 会立即回放当前值 —— 但那与
      // 上面 recomputeOutline 的结果相等（deriveOutline 是幂等 pure fn），
      // 重复一次调用的成本 O(N)、可接受、不会造成误行为
      store.$items
          .sink { [weak self] newItems in
              guard let self else { return }
              self.outline = Self.deriveOutline(items: newItems, pool: &self.outlineNodePool)
          }
          .store(in: &cancellables)
  }

  private func recomputeOutline() -> TranscriptOutlineTree {
      let tree = Self.deriveOutline(items: store.items, pool: &outlineNodePool)
      outline = tree
      return tree
  }
  ```
- **对 folds 变化的处理**：VM **不** 订阅 `store.$folds`、**不**暴露 fold API。fold 只影响 view 展开态、不影响 outline tree 结构；Controller 直接订阅 `store.$folds` 走 `applyFolds`，直接调 `store.setFold(...)` 写回 —— VM 在 fold 面上无派生职责，中间加一层 pass-through 是空转。
- **规范**：`ViewModel` 后缀；不 import AppKit；不持 `NSView`；单元可测（构造后直接 push items 到 stub Store、读 `outline` 断言）；Combine sink `[weak self]` + `.store(in: &cancellables)` —— 顶层 `CLAUDE.md` 内存约束；**不 `.receive(on:)`** —— Store 是 `@MainActor`、VM 是 `@MainActor`、`@Published` 同 actor 同步 send，插 receive-on 是把简单情况伪装复杂；`nonisolated deinit`（顶层 `CLAUDE.md`：`@MainActor` 类型必须 nonisolated deinit）。

### 2.8 `TranscriptClipView`（View）
- **范围**：`NSClipView` 子类。override `constrainBoundsRect(_:) -> NSRect`：documentView 比 clip 窄时把 `bounds.origin.x` 置为 `floor((proposed.width - docWidth) / -2.0)` 实现水平居中；否则原样返回。override `setFrameSize(_:)`：`super.setFrameSize(NSSize(width: max(0, size.width), height: max(0, size.height)))` clamp 负宽度。垂直方向直通。
- **规范**：`View` 后缀；只显示不业务；`wantsLayer = true` + `layerContentsRedrawPolicy = .never`；`init(coder:)` `@available(*, unavailable) + fatalError`。**为什么必要**：`NSClipView` 默认把窄 documentView flush-left 是 Apple 文档记载行为；子类反转是 Apple 官方推荐的居中 pattern。**不是** hack。

### 2.9 `TranscriptRowViewDelegate`（Delegate）
- **范围**：class-only 协议 —— row view 向 Controller 报告用户意图（顶层 `CLAUDE.md` state-flow 表：`delegate` = 1:1 + talks back + intent reporting，**不是**共享状态槽）：
  ```swift
  @MainActor
  protocol TranscriptRowViewDelegate: AnyObject {
      // Hover 上报（方法上报，非 property；Controller 决定"谁在被 hover"是它的状态）
      func rowViewDidEnterHover(itemID: TranscriptItem.ID)
      func rowViewDidExitHover(itemID: TranscriptItem.ID)

      // 自绘 chevron 点击 → toggle fold
      func rowViewDidClickChevron(itemID: TranscriptItem.ID)

      // Gutter 上的 copy 按钮点击
      func rowViewDidClickGutter(_ action: GutterAction, itemID: TranscriptItem.ID)

      // Row view 查询上下文（read-only）
      var isLiveScrolling: Bool { get }

      // 后续 PR stub —— 本 PR 只 log
      func requestUserMessageInspectSheet(itemID: TranscriptItem.ID)
      func requestImagePreview(itemID: TranscriptItem.ID)
  }
  ```
  **无 `toggleFold`** —— fold 通过 chevron click 上报，Controller 内部决定 toggle 方向再调 `store.setFold`。**`requestImagePreview` 传 itemID 而非 `NSImage`**：Controller 从 store 拿到真正的 `ImageRef` 再交 preview presenter，row view 不做图像权威源。
- **规范**：`Delegate` 后缀；`AnyObject` class-only；`weak var delegate` 持有（顶层 `CLAUDE.md`：delegate 永远 weak，protocol 是 `AnyObject`）；上报 intent 用方法调用，不用 `get set` property；`GutterAction`（enum）替代早期 `GutterSpec` —— action 直接表意"用户做了什么"，spec 语义模糊。

### 2.10 `TranscriptOutlineController`（Controller）
- **范围**：`NSViewController` + `NSOutlineViewDataSource` + `NSOutlineViewDelegate` + `TranscriptRowViewDelegate` + `DetailContainerChild`。**Session 域 mount 一次一个**。
- 构造：`init(viewModel: TranscriptViewModel)`（VM 由 Coordinator 现场 new，见 § 9.2）。
- 字段：
  - `let viewModel: TranscriptViewModel`
  - `private var loaderTask: Task<Void, Never>?`
  - `private var rowHeightsByID: [TranscriptItem.ID: CGFloat]` —— 每 outline node 的高度（key 是 node.id）
  - `private var heightCacheWidth: CGFloat` —— 当前缓存对应的 `outlineView.bounds.width`；宽度变时整表 invalidate
  - `private var cancellables: Set<AnyCancellable>`
  - `private var hoveredItemID: TranscriptItem.ID?` —— hover 状态**住 Controller**（不进 delegate 面）
- 订阅（两条，都在 `viewDidLoad`）：
  - `viewModel.$outline.sink { [weak self] in self?.applyOutline($0) }` —— apply outline 差异；首次 attach 之前的变化被 `applyOutline` 内部 `guard outlineView.dataSource != nil else { return }` 早退
  - `viewModel.store.$folds.sink { [weak self] in self?.applyFolds($0) }` —— 遍历新 folds 与 outline view 现状 diff，只对差异 rows 走 `outlineView.animator().expandItem` / `collapseItem`
  - 两条都**不用** `dropFirst()` —— `@Published` 立即回放当前值正是初次 sink 该同步的初始状态；用 dropFirst 会 drop 掉 pre-populated store（二次 mount / 测试 fixture）的真数据。首次 attach 前的 view 副作用由 `applyOutline` 的 dataSource-nil gate 挡住
- 关键方法：
  - `viewDidLayout` 首次：见 § 4.1 attach 契约
  - `applyOutline(_ tree)`、`applyFolds(_ folds)`、`retileAtNewWidth(_)`、`updateRowHeightsForLiveResize(newWidth:)`、`loadOlderPages()`、`loadFirstScreen(viewportHeight:)`（详见 § 4 / § 6）
  - `rowViewDidClickChevron(itemID:)`：`store.setFold(itemID: id, expanded: !(store.folds[id] ?? false))` —— Controller 直接调 Store，不经 VM 中转
- **规范**：`Controller` 后缀；顶层 `CLAUDE.md` "thin coordinator" —— 无业务逻辑，只 sink + apply + Task 生命周期 + view tree 构造；`loadView` 只建树、`viewDidLoad` 只绑、`viewDidLayout` 首次做 attach；`init(coder:)` `@available(*, unavailable) + fatalError`。
- **`prepareForRemoval` 显式释放**（顶层 `CLAUDE.md`："deterministic teardown of per-attach resources"）：
  ```swift
  override func prepareForRemoval() {
      // 写回滚动位到 Store，让二次 mount 恢复
      if let anchor = currentScrollAnchor() {
          store.setScrollAnchor(nodeID: anchor.nodeID, offsetFromClipTop: anchor.offset)
      }
      loaderTask?.cancel(); loaderTask = nil
      cancellables.removeAll()
      outlineView.dataSource = nil
      outlineView.delegate = nil
  }
  ```
- **为什么 rowHeightsByID 缓存放 Controller 不放 Store/VM**：height 与 outline view 当前 `bounds.width` 强绑 —— 宽度变化就整表 invalidate。Store 是 Session 域（不 known width），VM 是 VC 域但目标是"纯派生 outline tree"，height 是 view 层几何。挂 Controller 符合顶层 `CLAUDE.md`："state lives at the lowest scope shared by all its readers"（唯一 reader = 这个 Controller 上的 outline view）。

### 2.11 Row views（`NSTableCellView` 子类，按 outline node kind 分派）

**顶级抽象** `TranscriptRowView: NSTableCellView`（基类）：暴露 `func configure(with node: TranscriptOutlineNode)`（幂等）+ `weak var delegate: TranscriptRowViewDelegate?` + hover mouseEntered/Exited 转发到 delegate 方法。

**基于 `TranscriptItem.Kind` 分派的 4 类**：

- **`MarkdownRowView`** —— 渲染所有 `.userMarkdown*` / `.assistantMarkdown*` case、`.userAttachmentImage`、`.assistantThinking`。内部按 `TranscriptItem.Kind` 具体 case 切子 view：`HeadingBlockView` / `ParagraphBlockView` / `CodeBlockView` / `ListBlockView` / `TableBlockView` / `BlockquoteBlockView` / `ThematicBreakView` / `AttachmentImageView` / `ThinkingBlockView`。**复用** `RowLayout` 计算文本布局（小改 `RowLayout` 让它按 `TranscriptItem` 输入，不再看老 `Block`）。
- **`ToolGroupHeaderRowView`** —— 渲染 `.toolGroup(ToolGroupHeader)`。header 内容：图标 + `completedTitle` + 自绘 chevron。
- **`ToolInvocationHeaderRowView`** —— 渲染 `.assistantToolUse(ToolInvocation)`。header 内容：tool label + status（history 全 completed）+ 自绘 chevron（若该 tool 有 body 子节点）。
- **`ToolBodyRowView`** —— 抽象基类；具体渲染分派到 per-tool-kind subclass：`FileEditBodyRowView` / `BashBodyRowView` / `ReadBodyRowView` / `GrepBodyRowView` / `GlobBodyRowView` / `WebFetchBodyRowView` / `WebSearchBodyRowView` / `AskUserQuestionBodyRowView` / `AgentBodyRowView` / `GenericBodyRowView`。**参考迁移** `Layout/ToolGroupChildren/<Kind>/*Layout.swift` 里的度量与绘制逻辑到对应 subclass —— 每 subclass 一个 body 图像。**不**复用老 `ToolGroupLayout`（那是"整个 group 一 cell"的容器，本 PR 用不到）。

**Reuse identifier —— 集中常量、枚举分派**（顶层 `CLAUDE.md` list 规范："Reuse identifiers are centralized constants … a typo becomes a compile error instead of a silent nil"）：

```swift
// 已知 tool kind 枚举 —— SDK 加新 tool 时该 enum 补 case，dequeue / register 两端保持编译期锁定
enum ToolBodyKind: String {
    case fileEdit, read, bash, grep, glob
    case webFetch, webSearch, askUserQuestion, agent, generic
    init(toolName: String) {
        self = Self(rawValue: toolName) ?? .generic
    }
}

extension NSUserInterfaceItemIdentifier {
    static let markdownRow             = NSUserInterfaceItemIdentifier("MarkdownRow")
    static let toolGroupHeaderRow      = NSUserInterfaceItemIdentifier("ToolGroupHeaderRow")
    static let toolInvocationHeaderRow = NSUserInterfaceItemIdentifier("ToolInvocationHeaderRow")
    static let toolBodyRowFileEdit     = NSUserInterfaceItemIdentifier("ToolBodyRow.fileEdit")
    static let toolBodyRowRead         = NSUserInterfaceItemIdentifier("ToolBodyRow.read")
    // …其余 8 条 case 各自 static let…
    static let toolBodyRowGeneric      = NSUserInterfaceItemIdentifier("ToolBodyRow.generic")

    static func toolBodyRow(_ kind: ToolBodyKind) -> NSUserInterfaceItemIdentifier {
        switch kind {
        case .fileEdit: return .toolBodyRowFileEdit
        case .read:     return .toolBodyRowRead
        // …完全枚举…
        case .generic:  return .toolBodyRowGeneric
        }
    }
}

func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? TranscriptOutlineNode else { return nil }
    let identifier: NSUserInterfaceItemIdentifier
    switch node.item.kind {
    case .toolGroup:
        identifier = .toolGroupHeaderRow
    case .assistantToolUse:
        identifier = .toolInvocationHeaderRow
    case .userToolResult(_, let payload):
        identifier = .toolBodyRow(ToolBodyKind(toolName: payload.toolName))
    default:
        identifier = .markdownRow
    }
    let v = ov.makeView(withIdentifier: identifier, owner: self) as? TranscriptRowView
        ?? makeFreshRow(identifier: identifier)
    v?.delegate = self
    v?.configure(with: node)
    return v
}
```

**Native disclosure triangle 隐藏方案**：
- 子类 `TranscriptOutlineView: NSOutlineView` 里 override `frameOfOutlineCell(atRow:) -> NSRect { return .zero }` —— 把 native disclosure 的 frame 挤到零。
- `indentationPerLevel = 0` —— 我们自绘 indent 到 row view 里（`layoutOrigin.x` 按 `outlineView.level(forItem:)` 缩进）。
- Chevron 由 `ToolGroupHeaderRowView` / `ToolInvocationHeaderRowView` 自绘一个 `CAShapeLayer`；hit test 在 row view 的 `mouseDown(with:)` 里 —— 若 point 落在 chevron rect 内，调 `delegate?.rowViewDidClickChevron(itemID: node.id)`。Controller 内部：
  ```swift
  func rowViewDidClickChevron(itemID: TranscriptItem.ID) {
      let currentlyExpanded = store.folds[itemID] ?? false
      store.setFold(itemID: itemID, expanded: !currentlyExpanded)
      // Controller 的 store.$folds sink 会看到变化，走 applyFolds 里的
      // outlineView.animator().expandItem / collapseItem
  }
  ```

**规范**：全部 `View` 后缀（子 view 叫 `*BlockView` 而非 `*Subview` —— "Subview" 是 caller-shape 命名，`View` 是标准角色后缀）；只显示 + 报告；`configure(with:)` 幂等（reuse 时每字段都重写，无残留状态 —— 顶层 `CLAUDE.md` list 规范）；不直连 Store / VM / SDK；不持 domain object 引用超过当前 reuse；`init(coder:)` `@available(*, unavailable) + fatalError`。

### 2.12 `AgentSDK.SessionHistory`（SDK 扩展）
- **新增**：
  - `public struct Cursor: Sendable`（不透明字节偏移；仅进程内使用）
  - `public struct Page { let messages: [Message2]; let nextCursor: Cursor? }`
  - `public static func loadPage(id: String, cursor: Cursor?) throws -> Page` —— **同步**；一次 ~64 KB 页 + 解码；~3–8 ms 典型
  - `public static func stream(id: String, cursor: Cursor?) -> AsyncThrowingStream<Page, Error>` —— 需求驱动，每次 `next()` 触发一次 `loadPage`
- **不变式**：**每页内部 wall-clock 正序、跨页保全局 wall-clock 序（旧页整体在前、新页整体在后）**。SDK 内部反向游走字节，然后**页级正序化**（页内 messages 数组以 wall-clock 正序返回）。
- **不做跨页语义 buffer**：`loadPage` / `stream` 都不做 tool_use↔tool_result 的跨页 withhold。跨页读到 orphan `tool_result`（对应 `tool_use` 在更旧、尚未 emit 的页）时**原样吐出**；由 VM 侧的 `pending` map（§ 6.1）自然消化（`.awaitingUse` 分支），旧页 prepend 后下一次 `deriveOutline` 完成配对。**理由**：sync API 天然不能跨调用 buffer（buffer 状态会成为 SDK 里的隐藏可变状态、违反 pure API 契约）；stream 也不 buffer 是为了让两条 API 语义完全一致，同一 fixture 走两条 API 结果相同、单元可测。
- **内部 `_ReverseBatchPairer` 更名 `_ReversePageOrderFixup`** —— 语义收窄为"反向字节 walk 时把当前页里的行反过来变成 wall-clock 正序"；**不做**跨页配对，也不做跨页 tool 语义关联。名字表达实际职责。
- **Stream producer 强制 off-main**：
  ```swift
  static func stream(id: String, cursor: Cursor?) -> AsyncThrowingStream<Page, Error> {
      AsyncThrowingStream { continuation in
          let task = Task.detached(priority: .userInitiated) {
              var current = cursor
              do {
                  while !Task.isCancelled {
                      let page = try SessionHistory.loadPage(id: id, cursor: current)
                      continuation.yield(page)
                      guard let next = page.nextCursor else { break }
                      current = next
                  }
                  continuation.finish()
              } catch is CancellationError {
                  continuation.finish()
              } catch {
                  continuation.finish(throwing: error)
              }
          }
          continuation.onTermination = { _ in task.cancel() }
      }
  }
  ```
  producer 永远在 background；consumer 归 `@MainActor`。**不用** `AsyncStream(unfolding:)` —— 那个 API producer 上下文 = 调用方，consumer 在 main 上 iterate 会把 producer 拉回 main、退化成主线程 blocking read。
- **删除**：现有 `SessionHistory.load(id: order:)` async-only、无 cursor 的 API —— call site 全走 stream。
- **规范**：SDK 是 client 依赖 target；不 import AppKit；输出 `Message2`，不合成"配对好"的高级事件（那是 client 语义层）；`public` API 稳定契约明确；producer 侧的取消响应符合 Swift concurrency 惯例（`Task.isCancelled` + `continuation.onTermination`）。

## 3. 命名

- **角色后缀**：`View` / `Controller` / `Store` / `Delegate` / `ViewModel` / `Builder`（`Builder` 仅无状态时用，本 PR 落 `enum` + `static`）。
- **禁止**：`Manager` / `Storage` / `Pipeline` / `Bridge` / `Presenter` / `Adapter`。`Coordinator` 仅用于导航（已有 `DetailFlowCoordinator`）；新栈不新增 `Coordinator`。
- **数据类型无后缀**：`TranscriptItem` / `TranscriptOutlineNode` / `TranscriptOutlineTree` / `ToolGroupHeader` / `ToolInvocation` / `ToolBodyKind` / `ImageRef` / `SystemMetaKind` / `ListPayload` / `TablePayload` / `GutterAction`。
- **无数字后缀**：不允许 `TranscriptItem2` / `Transcript2*`。
- **每类型一文件**，命名对齐类型名。新栈全部落 `macos/ccterm/Content/Chat/Transcript/` 及子目录。
- **动词优先，对象在后**（方法名 SOP）：`applyOutline`、`applyFolds`、`retileAtNewWidth`、`updateRowHeightsForLiveResize`、`loadOlderPages`、`loadFirstScreen` 之类 —— 动词是动作，对象是被作用的东西；避免 `handle`（Cocoa 味 callback）+ 过去分词、避免 `perform` / `run` / `commit` / `flush` 等虚动词；实现细节（`Sync` / `BFS` / `Background`）不进方法名。

## 4. Runloop tick 契约

本节把每一处 UI 动作放到顶层 `CLAUDE.md` 的 tick 图里 —— 因为绝大部分"一 tick 差异"的 bug 都能在这里预先排除。

### 4.1 首屏 attach（`viewDidLayout` 第一次）

Attach 契约分两种起点：**空 store**（首次 mount）和 **pre-populated store**（二次 mount，切走再回来）。两条走同一段代码，只是 sync loop 是否跑一次视 `store.didLoadFirstScreen` 决定。

**Source phase 内完成**：

```
viewDidLayout()  ─────────────────────────────  ← 事件源：AppKit 派发到 responder chain
  super.viewDidLayout()

  ── Gate 1：view 尚未布局出正常 frame 时先返回，等下次 layout
  guard view.bounds.width > 0, view.bounds.height > 0 else { return }

  ── Gate 2：dataSource 已 attach 说明是 post-attach 的 layout（宽度变化 / relayout）
  if outlineView.dataSource != nil {
      let w = outlineView.bounds.width
      if w != heightCacheWidth { … 见 § 4.5 宽度变化路径 … }
      return
  }

  view.layoutSubtreeIfNeeded()                    ← 同 source phase 里同步跑 subtree 布局
                                                    这一步让 outlineView.bounds.width 稳定
                                                    顶层 CLAUDE.md："source-phase 里读 lazy
                                                    AppKit 几何前先 layoutSubtreeIfNeeded"
  let contentWidth = outlineView.bounds.width
  heightCacheWidth = contentWidth

  ── 分支 A：pre-populated store（二次 mount）—— 跳过 sync loop，直接 attach
  if store.didLoadFirstScreen {
      // VM 已在 init 里立即 derive 过 outline；rowHeightsByID 是空
      // attach 前预热"至少可见段"的高度缓存
      let visibleNodes = viewModel.outline.prefixForFirstAttach(
          approxViewportHeight: view.bounds.height
              - scrollView.contentInsets.top - scrollView.contentInsets.bottom)
      for node in visibleNodes {
          rowHeightsByID[node.id] = TranscriptRowHeight.compute(node: node, width: contentWidth)
      }
      attachDataSourceAndPaint(anchor: store.lastKnownScrollAnchor)
      loadOlderPages()   ← 若 store.nextOlderCursor != nil 从当前 cursor 续加
      return
  }

  ── 分支 B：空 store（首次 mount）—— sync loop 直到 viewport 满或文件顶

  var accHeight: CGFloat = 0
  var cursor: SessionHistory.Cursor? = nil
  let viewportHeight = view.bounds.height
      - scrollView.contentInsets.top - scrollView.contentInsets.bottom
  while accHeight < viewportHeight {
      let previousOutlineTopCount = viewModel.outline.topLevel.count
      let page = try SessionHistory.loadPage(id: transcriptId, cursor: cursor)
      let items = page.messages.enumerated().flatMap { idx, m in
          TranscriptItemBuilder.makeItems(
              from: m, pageCursor: cursor ?? .zero, indexInPage: idx)
      }
      store.prependOlderItems(items, nextCursor: page.nextCursor)
        │  ↑ store.items setter 的 willSet 发出 @Published；VM.sink 同 tick 里跑：
        │        newItems 是 sink 参数（新值）→ self.outline = deriveOutline(items: newItems)
        │        self.outline 的 willSet 发出 @Published；Controller.sink 同 tick 里跑：
        │            newOutline 是 sink 参数 → self.applyOutline(newOutline)
        │            此时 dataSource 尚未 attach → applyOutline 早退（见 applyOutline 实现）
      // prepend 后 outline 顶层前置了 delta 个新节点
      let delta = viewModel.outline.topLevel.count - previousOutlineTopCount
      let newPrefix = viewModel.outline.topLevel.prefix(delta)
      for node in newPrefix {
          let h = TranscriptRowHeight.compute(node: node, width: contentWidth)
          rowHeightsByID[node.id] = h
          accHeight += h
      }
      if page.nextCursor == nil { break }
      cursor = page.nextCursor
  }
  attachDataSourceAndPaint(anchor: nil)   ← 首次 mount 无 scroll anchor
  loadOlderPages()
```

`attachDataSourceAndPaint(anchor:)`：

```
outlineView.dataSource = self
outlineView.delegate   = self
withoutImplicitAnimations {
    outlineView.reloadData()                         ← O(top-level count) 建索引
    restoreFoldsAfterReload(store.folds)              ← 父先子后遍历 outline 恢复展开态；见下
}
outlineView.layoutSubtreeIfNeeded()                  ← 强制 tile 到 numberOfRows / heightOfRow
                                                       rowHeightsByID 已 warm → 命中
if let a = anchor,
   let node = viewModel.outline.nodeByID[a.nodeID],
   outlineView.row(forItem: node) >= 0 {
    let row = outlineView.row(forItem: node)
    let newRectMinY = outlineView.rect(ofRow: row).minY
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: newRectMinY - a.offsetFromClipTop))
    scrollView.reflectScrolledClipView(scrollView.contentView)
} else if outlineView.numberOfRows > 0 {
    outlineView.scrollRowToVisible(outlineView.numberOfRows - 1)   ← 首次 mount 滚到尾
}
```

`restoreFoldsAfterReload(_:)` 从 outline tree 根开始 pre-order 遍历（**父先子后**），对 `folds[node.id] == true` 的每个节点调 `outlineView.expandItem(node, expandChildren: false)`。父先子后是硬性要求：`NSOutlineView.expandItem(_:)` 对未 attach 的子 item 是 no-op，错序会静默丢子层展开。整个遍历包在 `withoutImplicitAnimations` 内，避免连锁 fold 动画闪现。

**Combine 链两跳的 stash 契约**（顶层 `CLAUDE.md`："`@Published` 在 `willSet` 发送；sink 里用 sink 参数、不重读属性"）：
- **VM sink** 用 sink 参数 `newItems`（不重读 `store.items`）→ `outline = deriveOutline(items: newItems, pool: &outlineNodePool)`
- **Controller sink** 用 sink 参数 `newOutline`（不重读 `viewModel.outline`）→ `applyOutline(newOutline)`
- 两跳都在同一 source phase 的执行栈里；Store setter 一次调用即完成到 outline view apply 的全链路。

**beforeWaiting**：outline view 的 tile pass 已经在上面 source phase 里被 `layoutSubtreeIfNeeded` 显式触发过一次；beforeWaiting 只做 CATransaction commit 到 render server。**首帧完整 = 无空白闪现**。

### 4.2 旧页 loader（`Task { @MainActor for try await page in stream }`）

- `for try await page`：consumer 在 `@MainActor` 上；SDK 的 stream producer 强制在 `Task.detached` 里跑 `loadPage`（见 § 2.12），consumer body 在 source phase resume（顶层 `CLAUDE.md` tick 图明列 `@MainActor Task resumed` 是 source phase 事件）。
- consumer body 里 **两阶段**：
  - **Phase 1（MainActor pure fn）**：`let previewTree = TranscriptViewModel.deriveOutline(items: newItems + store.items, pool: &localPool)` —— 直接调 VM 的 pure fn `deriveOutline`（同一份逻辑），传入 local 空 pool 避免污染 VM 真池 `outlineNodePool`。没有独立的 `previewOutline` 孪生方法。
  - **Phase 2（`await Task.detached { … }.value`）**：detached 跑 background 算 `previewTree` 头部 N 个新 top-level node 的高度；await 返回时 resume 回 source phase。
- **Commit（同 source phase）**：
  ```
  try Task.checkCancellation()   ← Phase 2 归来后先 gate
  withoutImplicitAnimations {
      let anchor = captureScrollAnchor()
      for (id, h) in heightPairs { rowHeightsByID[id] = h }   ← 先 warm 高度缓存
      store.prependOlderItems(newItems, nextCursor: page.nextCursor)
          │  ↑ 两跳 stash：VM.sink → outline @Published；Controller.sink → applyOutline
          │    applyOutline 现在 dataSource 已 attach → 走 diff apply（见 § 6.3）
          │    fold state：不在此处显式 restoreFolds —— `outlineNodePool` 保证
          │      已存在 id 的 node 引用稳定，NSOutlineView 内部展开态记忆有效
      restoreScrollAnchor(anchor)                              ← 按 node identity 找回 row，见 § 6.4
  }
  ```
- **`withoutImplicitAnimations`** = `CATransaction.setDisableActions(true)` + `NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false; body() }`。顶层 `CLAUDE.md` tick："多次 property write 在一 tick 里 coalesce 到一个 CATransaction，用 disable-actions 避免 crossfade"。
- **不在 commit 里重新 restoreFolds**：`outlineNodePool` 保 id → 实例引用稳定，NSOutlineView 对**已存在 id** 的展开态记忆本身就有效；对**新插入 id**（比如新的 `.toolGroup` 节点），若 `store.folds[newID] == true`（不太可能，因为它刚出现），会通过 `store.$folds` sink 的独立路径 apply。这样避免了 loader commit 与用户刚触发的手动 expand 动画在同 tick 里互相截断。
- **取消关卡**（顶层 `CLAUDE.md` 内存规范："Task cancel 是一等退出路径"）：
  1. `for try await` —— 上层 Task cancel 时 stream.next() 抛 `CancellationError`
  2. Phase 1 前 `try Task.checkCancellation()`
  3. Phase 2 await 之后再一次 `try Task.checkCancellation()`
  detached 内部的高度计算是 pure fn 不检查 cancel，跑完后结果被 Phase 2 之后的 `checkCancellation` 抛出丢弃。

### 4.3 Hover（`mouseEntered` / `mouseExited`）

- 事件在 source phase。Row view 的 tracking area 触发 → `delegate.rowViewDidEnterHover(itemID:)` / `rowViewDidExitHover(itemID:)`（方法调用，非属性写）。
- Controller 里：
  ```
  func rowViewDidEnterHover(itemID: TranscriptItem.ID) {
      let old = hoveredItemID
      hoveredItemID = itemID
      redrawRowIfVisible(id: old)     // 老 hover 掉色
      redrawRowIfVisible(id: itemID)  // 新 hover 变色
  }
  ```
  `redrawRowIfVisible` = `outlineView.rowView(atRow: idx, makeIfNecessary: false)?.needsDisplay = true`。
- beforeWaiting：CoreAnimation 只重绘那两 row 的 layer 内容。
- **不走 `reloadData` / `noteHeightOfRows`**（hover 只是颜色，与度量无关 —— 老 `NativeTranscript2/CLAUDE.md § 2.12`）。

### 4.4 Fold（点击自绘 chevron）

- Row view `mouseDown(with:)` 里 hit-test 自绘 chevron rect → `delegate.rowViewDidClickChevron(itemID:)`。Controller 里**直接调 store**（不经 VM）：
  ```
  func rowViewDidClickChevron(itemID: TranscriptItem.ID) {
      let currentlyExpanded = store.folds[itemID] ?? false
      store.setFold(itemID: itemID, expanded: !currentlyExpanded)
      // store.folds 变 → store.$folds sink 触发
  }
  ```
- `store.$folds.sink { [weak self] newFolds in self?.applyFolds(newFolds) }`（`newFolds` 用 sink 参数，不重读）。`applyFolds`：diff `newFolds` 与 outline view 现状，仅对差异 node 走 `outlineView.animator().expandItem(node, expandChildren: false)` / `collapseItem(node)`。
- **outline view 的 fold 动画由 AppKit 在 beforeWaiting flush**（`NSOutlineView` native `expandItem` / `collapseItem` 走 `CATransaction`）—— 我们不手绘任何 frame 动画。
- **不重派生 outline**（folds 不影响 tree 结构）。

### 4.5 宽度变化（`viewDidLayout` post-attach）

- 事件在 source phase。Controller 比较 `outlineView.bounds.width` 与 `heightCacheWidth`：
  - **相等** → 立即返回
  - **`outlineView.inLiveResize == true`** → `updateRowHeightsForLiveResize(newWidth:)`：
    - `outlineView.noteHeightOfRows(withIndexesChanged: visibleIndexes)` **仅可见段**
    - **不改** `heightCacheWidth`、**不清** `rowHeightsByID`、**不动** loader
    - 拖拽期间可见行的 `heightOfRowByItem` 在 beforeWaiting 懒计算（visible-only、user-initiated、short-lived —— 老 `NativeTranscript2/CLAUDE.md § 2.6` 允许的例外）
  - **非拖拽 drift（⌥⌘S、split-view programmatic、动画器 setFrame）** → `retileAtNewWidth(newWidth:)`：
    ```
    // 1. cancel & clean
    loaderTask?.cancel(); loaderTask = nil
    rowHeightsByID.removeAll(keepingCapacity: true)
    heightCacheWidth = newWidth

    // 2. 全 outline node 高度 off-main 算一遍 —— 不是只算可见 + overdraw
    //    老 § 2.6 要求 backfill off-main-built；若只算可见段，scroll 触及未算 rows
    //    时 outline view 会 on main 懒算，违反不变式。
    let allNodes = viewModel.outline.flatten()
    let pairs = await Task.detached(priority: .userInitiated) {
        allNodes.map { ($0.id, TranscriptRowHeight.compute(node: $0, width: newWidth)) }
    }.value

    // 3. 归主 tick 提交
    try Task.checkCancellation()
    withoutImplicitAnimations {
        for (id, h) in pairs { rowHeightsByID[id] = h }
        let allIndexes = IndexSet(integersIn: 0 ..< outlineView.numberOfRows)
        outlineView.noteHeightOfRows(withIndexesChanged: allIndexes)
        outlineView.layoutSubtreeIfNeeded()             // 顶层 CLAUDE.md："in-tick anchor for resize"
        restoreScrollAnchorAtSameNode(...)              // 见 § 6.4
    }

    // 4. 重启 loader
    loadOlderPages()
    ```
- `viewDidEndLiveResize` → 若 `heightCacheWidth != outlineView.bounds.width` → `retileAtNewWidth`（延后的完整 retile；覆盖 live-resize 期间累积的宽度漂移）。

### 4.6 Combine chain 的 tick 语义

`@Published` 在 setter **`willSet`** 阶段同步 send。链条：

```
store.items = newItems (setter, MainActor)
  │  willSet emit
  ▼
VM sink(newItems) → cancellables 里的一条:              ← MainActor, same tick
  self.outline = Self.deriveOutline(                    ← 用 sink 参数，不重读 store.items
      items: newItems, pool: &self.outlineNodePool)
    │  willSet emit
    ▼
Controller sink(newOutline) → cancellables 里的一条:    ← MainActor, same tick
  self.applyOutline(newOutline)                         ← 用 sink 参数，不重读 viewModel.outline
```

两跳的 stash 契约（顶层 `CLAUDE.md`："`@Published` 在 `willSet` 发送；sink 里用 sink 参数、不重读属性"）**必须**在 code review 里守住 —— 任一处误写 `store.items` / `viewModel.outline` 就拿到 stale。

- 无 `.receive(on:)`：Store / VM / Controller 全部 `@MainActor`，`@Published` 在 setter 所在 actor 同步 send，no cross-thread。加 `.receive(on:)` 是把 same-tick 结算撕成 next-tick + 引入无用调度成本。
- 无 `debounce` / `throttle`：Store 的 `items` mutation 已经是"每次一批"（`prependOlderItems` 一次一 page），没有 sub-tick 抖动可去；VM 派生是 pure fn，其自身是幂等的。
- **同一独立 `sink` 内的 chained mutation** 是同 tick，但 `sink` 是**回到 Combine dispatcher** 才 fan out —— 也就是说 VM sink 内部写 `self.outline = ...` 触发的下一跳 Controller sink，是等 VM sink 闭包返回后 dispatcher 才驱动的。链条中间**不允许**看别的 subscriber（否则得到 stale）；本 PR 只 store.$items / store.$folds / viewModel.$outline 三条 sink，无交叉。

## 5. 布局

`TranscriptClipView` 论证：`NSClipView.constrainBoundsRect(_:)` 默认把窄 documentView 夹到 flush-left（Apple 文档记载）；子类反转是官方推荐 pattern。`NSOutlineView` 是 `NSTableView` 子类，居中逻辑一致适用。

```
TranscriptOutlineController.view                NSView             full pane
 └ NSScrollView (host)                          stock
    · wantsLayer = true; layerContentsRedrawPolicy = .never
    · hasVerticalScroller = true; autohidesScrollers = true
    · hasHorizontalScroller = false
    · scrollerStyle = .overlay
    · drawsBackground = false; borderType = .noBorder
    · automaticallyAdjustsContentInsets = false
    · contentView = TranscriptClipView()                              MUST 先赋值再设 insets
    · contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
    · 4-edge pin to view
 └ TranscriptClipView (contentView)             subclass —— 见 § 2.8
 └ TranscriptOutlineView (documentView)         NSOutlineView 子类
    · headerView = nil
    · backgroundColor = .clear
    · style = .plain
    · selectionHighlightStyle = .none
    · gridStyleMask = []
    · usesAutomaticRowHeights = false
    · rowSizeStyle = .custom
    · intercellSpacing = .zero
    · outlineTableColumn = column  (单列，是"outline column"; native disclosure 属于此列)
    · autosaveExpandedItems = false                                   (fold 由 Store 管，不落 defaults)
    · indentationPerLevel = 0                                         (indent 自绘)
    · autoresizesOutlineColumn = false
    · override frameOfOutlineCell(atRow:) -> NSRect { return .zero }  ← 隐藏 native disclosure
    Auto Layout:
      · widthAnchor ≤ 780 required
      · widthAnchor ≥ 460 required
      · widthAnchor == clip.widthAnchor priority .defaultLow
      · topAnchor == clip.topAnchor
 └ NSTableRowView                              reuse id "TranscriptOutlineRow"
 └ 4 类 row view（reuse identifier 分派见 § 2.11）
```

**Native disclosure 隐藏**：`TranscriptOutlineView: NSOutlineView` 子类里 override `frameOfOutlineCell(atRow:)` 返回 `.zero`。这样系统仍然维护 `outlineTableColumn` 单列布局（我们唯一的 column），native disclosure triangle 只是 frame 是 zero 因此不可见、不 hit test；native `expandItem` / `collapseItem` 通过我们自绘 chevron 的 mouseDown → controller 触发（见 § 2.11 / § 4.4）。

**Indent 自绘**：outline node 有层级（group / invocation / body）—— row view 的 `layoutOrigin.x` 按 node 的层级偏移（controller 在 `outlineView(_:viewFor:)` 里读 `outlineView.level(forItem:)` 传给 row view 的 `configure`）。`indentationPerLevel = 0` 让 system 不加 indent（否则会与自绘冲突）。

Controller 实现 `outlineView(_:rowViewForItem:)` 用稳定 identifier `"TranscriptOutlineRow"` dequeue-or-new `NSTableRowView`（顶层 `CLAUDE.md` list 规范 —— 稳定 reuse id 避免 per-tick 重分配）。

## 6. 数据流

```
SDK: SessionHistory.loadPage(cursor) / stream(cursor)
     · 反向读字节 + 页级正序化（内部 _ReversePageOrderFixup）
     · 输出 Page { messages: [Message2] wall-clock 正向, nextCursor }
     · 不做跨页 tool 语义 buffer（orphan tool_result 原样吐出）
 ▼
TranscriptItemBuilder.makeItems(from:pageCursor:indexInPage:)   pure static
     · 一条 Message2 → 0..N 条 TranscriptItem
     · markdown 拆到 block 粒度；不产 .toolGroup case（VM 做）
     · 系统类消息 → .systemMeta（VM 侧 skip）
 ▼
TranscriptStore.prependOlderItems(_, nextCursor:)   @MainActor
     · items 数组 wall-clock 正向增长；首次调用置 didLoadFirstScreen = true
     · @Published items 触发 VM 的 items sink
 ▼
VM sink(newItems):
     self.outline = Self.deriveOutline(items: newItems, pool: &outlineNodePool)
     · forward-scan + pending map (§ 6.1)
     · VM 生成 .toolGroup outline node 插入 outline tree
     · tool_use↔tool_result 关联（body 子节点）
     · outlineNodePool 复用同 id node 引用（保 outline view expand state）
     · @Published outline 触发 Controller 的 outline sink
 ▼
Controller outline sink(newOutline):
     applyOutline(newOutline)
     · guard outlineView.dataSource != nil else { return }   ← 首屏 attach 前早退
     · 后续（旧页 prepend）：
         withoutImplicitAnimations {
             let anchor = captureScrollAnchor()
             ── 若是"纯顶部前置"（新 tree.topLevel.suffix == 旧 tree.topLevel）：
                 beginUpdates + insertItems(at:0..<delta, inParent:nil) + endUpdates
             ── 否则（跨页 group 合并导致头部结构变化）：
                 reloadData()                                ← 走 fallback
                 restoreFoldsAfterReload(store.folds)
             restoreScrollAnchor(anchor)
         }
```

`store.$folds` 独立一条 sink 到 Controller，走 `applyFolds(newFolds)` —— 直接调 `expandItem` / `collapseItem`，不重派生 outline。

### 6.1 VM forward-scan + pending map

`deriveOutline` 是 **static pure fn**（VM 内，签名 `pool: inout` 让调用者持池）：VM 自身派生用 `&outlineNodePool`（跨调用复用实例）；旧页 loader 的 preview 传 local 空 dict（不污染真池）。

```swift
private enum PendingToolPairing {
    case awaitingResult(useNode: TranscriptOutlineNode)          // 已见 tool_use, 等 tool_result
    case awaitingUse(resultItem: TranscriptItem,
                     resultNode: TranscriptOutlineNode)          // 已见 tool_result, 等 tool_use
}

static func deriveOutline(
    items: [TranscriptItem],
    pool: inout [TranscriptItem.ID: TranscriptOutlineNode]
) -> TranscriptOutlineTree {
    var pending: [String: PendingToolPairing] = [:]              // key = tool_use_id
    var reachable: Set<TranscriptItem.ID> = []                   // scan 末 prune pool
    var top: [TranscriptOutlineNode] = []
    var openGroupInvocations: [TranscriptOutlineNode] = []       // 累积中的 group children

    func nodeFor(_ item: TranscriptItem) -> TranscriptOutlineNode {
        reachable.insert(item.id)
        if let existing = pool[item.id] { return existing }
        let fresh = TranscriptOutlineNode(id: item.id, item: item, children: [])
        pool[item.id] = fresh
        return fresh
    }

    func emitOpenGroup() {
        guard !openGroupInvocations.isEmpty else { return }
        // 单条 invocation 也升级为 group —— 老 renderer 视觉一致（不允许降级）
        let header = ToolGroupHeader.compute(invocations: openGroupInvocations.map(\.item))
        // Group id 尾锚定：用 wall-clock 最新（openGroupInvocations.last）的 item id
        //   跨页合并只在 group 头加入更旧 tool_use、尾不变 → id 稳定 → 展开态记忆有效
        let anchorID = openGroupInvocations.last!.id
        let groupItemID = TranscriptItem.ID(rawValue: "group#\(anchorID.rawValue)")
        let groupItem = TranscriptItem(id: groupItemID, kind: .toolGroup(header))
        let groupNode = nodeFor(groupItem)
        groupNode.children = openGroupInvocations
        top.append(groupNode)
        openGroupInvocations = []
    }

    for item in items {
        switch item.kind {

        // System meta：透明 skip，不产 node、不 close openGroup、不参与 group 合并判定
        case .systemMeta:
            continue

        // Assistant tool_use：可分组，加入 openGroup
        case .assistantToolUse(let tu):
            let invNode = nodeFor(item)
            if case .awaitingUse(_, let resultNode) = pending[tu.id] {
                invNode.children = [resultNode]                  // 之前见过的 orphan result → 立刻关联
                pending[tu.id] = nil
            } else {
                invNode.children = []
                pending[tu.id] = .awaitingResult(useNode: invNode)
            }
            openGroupInvocations.append(invNode)

        // User tool_result：不作为独立 top-level，被 tool_use 吸收
        case .userToolResult(let toolUseID, _):
            let bodyNode = nodeFor(item)
            if case .awaitingResult(let useNode) = pending[toolUseID] {
                useNode.children = [bodyNode]
                pending[toolUseID] = nil
            } else {
                // orphan tool_result —— 对应 tool_use 在更旧未加载页；
                //   scan 末 emitOrphanResults 里作为独立 .toolBody 顶层节点显示
                //   （不允许降级 —— 老 ReverseEntryBuilder.flushOrphans 也这么做）
                pending[toolUseID] = .awaitingUse(resultItem: item, resultNode: bodyNode)
            }

        // 其它一切（markdown blocks / thinking / attachment / userText / assistantThinking）
        default:
            emitOpenGroup()   // close 前一段 group
            top.append(nodeFor(item))
        }
    }
    emitOpenGroup()

    // Orphan 残余处理（不降级）：
    // `.awaitingUse` = tool_result 找不到 tool_use（对应 tool_use 在更旧未加载页）
    //   → 作为独立 .toolBody 顶层节点显示，保持 wall-clock 位置（用 items 顺序索引插进 top）
    // `.awaitingResult` = tool_use 找不到 tool_result（数据缺 result，rare）
    //   → tool_use 节点已进 group、children 空是正确视觉
    emitOrphanResults(pending: pending, into: &top, items: items, nodeFor: nodeFor)

    pruneOutlineNodePool(pool: &pool, reachable: reachable)
    return TranscriptOutlineTree(topLevel: top)
}
```

**关键点**：

- **一个 map、两态**（同一 tool_use_id 只可能处于一态）。
- **`.systemMeta` skip 语义** —— 不产 node、**不 close openGroup**、不参与 group 合并判定。若两个相邻的 groupable tool_use 之间夹一条 systemMeta，仍被视为同一段 group（老 renderer 一致）。
- **`.toolGroup` item 由 VM 生成** —— builder 不产此 case；`ToolGroupHeader.compute` 是 pure fn，用 `ToolInvocation.name` 频次分布派生。
- **Group 稳定 id 尾锚定** = `"group#\(group 内最新一条 invocation 的 item.id)"`。跨页合并（旧页尾部有更旧 tool_use、拼到当前 head group 前面）只改变 group 头部、尾不变 → id 稳定 → 展开态记忆有效。头锚定（用第一条 invocation id）会因跨页合并让 id 漂移。
- **单条 tool_use 也升级为一元素 `.toolGroup`** —— 视觉一致（老 renderer 语义，避免降级）。
- **Orphan tool_result 显示为独立 `.toolBody` 顶层节点**（`emitOrphanResults`）—— 不允许降级；旧页 prepend 后下一次 scan 若找到对应 tool_use，从 orphan 恢复到正常子节点位置。
- **`outlineNodePool`** 是复用池（不是缓存 —— § 2.7 命名解释）：每次 `deriveOutline` 从头到尾都 refresh，`reachable` 集合末尾 `pruneOutlineNodePool` 清未 reach 的项。同 id 的 node 引用跨调用稳定 → `NSOutlineView.expandItem` 记忆有效。

### 6.2 首屏同步

详细流程见 § 4.1 attach 契约；数据流角度概括：
- **首次 mount（空 store）**：`viewDidLayout` 首次同步 loop：`loadPage` → items → `store.prependOlderItems` → VM sink 同步 `deriveOutline` → 遍历 outline **prefix**（新前置段）累加高度入 `rowHeightsByID`
- **二次 mount（pre-populated store）**：跳过 loop；从 `viewModel.outline` 拿"至少覆盖可见段"的头部 nodes 预热 heights
- 终止条件仅两个：viewport 满 或 文件顶（`page.nextCursor == nil`）
- dataSource 首次 attach 之前 Controller sink 收到的 outline 变化都被 `applyOutline` 早退（`guard outlineView.dataSource != nil else { return }`）
- Attach 后一次 `reloadData` + `restoreFoldsAfterReload` + `layoutSubtreeIfNeeded` + `scrollRowToVisible`（或按 `store.lastKnownScrollAnchor` 恢复）完成首帧
- **无 `maxPages` / 无 `deadline`** —— 只按目标（viewport 满 / 文件顶）终止，不给性能启发式留位置

### 6.3 旧页 loader

```swift
private func loadOlderPages() {
    guard loaderTask == nil, let startCursor = store.nextOlderCursor else { return }
    let tid = store.transcriptId
    loaderTask = Task { @MainActor [weak self] in
        do {
            let stream = SessionHistory.stream(id: tid, cursor: startCursor)
            for try await page in stream {
                try Task.checkCancellation()
                guard let self else { return }
                let newItems = page.messages.enumerated().flatMap { idx, m in
                    TranscriptItemBuilder.makeItems(
                        from: m, pageCursor: startCursor, indexInPage: idx)
                }

                // Phase 1: MainActor pure fn —— 直接调 VM 上的 static `deriveOutline`
                //   （唯一一份实现），传 local 空 pool 避免污染 VM 真池 outlineNodePool
                var localPool: [TranscriptItem.ID: TranscriptOutlineNode] = [:]
                let previewTree = TranscriptViewModel.deriveOutline(
                    items: newItems + self.store.items,
                    pool: &localPool)
                let newHeadCount = previewTree.topLevel.count
                    - self.viewModel.outline.topLevel.count
                let newHead = Array(previewTree.topLevel.prefix(newHeadCount))

                // Phase 2: off-main 算 previewTree 头部 N 个新 node 的高度
                let width = self.heightCacheWidth
                let pairs = await Task.detached(priority: .userInitiated) {
                    newHead.map { ($0.id, TranscriptRowHeight.compute(node: $0, width: width)) }
                }.value

                try Task.checkCancellation()

                // Commit（source phase）
                let anchor = self.captureScrollAnchor()
                withoutImplicitAnimations {
                    for (id, h) in pairs { self.rowHeightsByID[id] = h }   // 先 warm 高度缓存
                    self.store.prependOlderItems(newItems, nextCursor: page.nextCursor)
                    // ↑ Store setter → VM sink → outline @Published → Controller sink → applyOutline
                    //   applyOutline 做 diff apply（见下），此时 rowHeightsByID 已 warm
                    //   不在此处显式 restoreFolds —— outlineNodePool 保 id → 实例引用稳定
                    self.restoreScrollAnchor(anchor)
                }
            }
        } catch is CancellationError { return }
        catch { appLog(.error, "TranscriptOutlineController", "loader: \(error)") }
    }
}
```

**Preview 与 commit 的 tree 结构等价性**：Phase 1 与 commit 都调用同一个 `TranscriptViewModel.deriveOutline`（无孪生方法、无长期漂移风险），传的 items 相同（`newItems + store.items`），只是 pool 一个是 local 空、一个是 `&outlineNodePool`。deriveOutline 是 pure fn，同 items 输入产同 tree 结构（等价的 `TranscriptItem.ID` 集合与父子关系）；不同池只影响 node **实例**（哪个引用被复用 / 新建）—— 但 `id` 集合和 heights 计算 key 完全一致，所以 Phase 2 算的 heights 对应的 id 集合与 commit 后 outline view 需要问的 heights 完全对齐。

**`applyOutline(newOutline)` 的分支 apply**（首屏 attach 之后走这条）：

```swift
private func applyOutline(_ newTree: TranscriptOutlineTree) {
    guard outlineView.dataSource != nil else { return }      // 首屏 attach 前早退
    let oldTop = currentAppliedTopLevel                       // 上次 apply 后我们记的顶层 id 序列
    let newTop = newTree.topLevel.map(\.id)
    if isPurePrefixInsertion(old: oldTop, new: newTop) {
        // 快路径：只是顶部前置 delta 个新节点 —— 用 insertItems
        let delta = newTop.count - oldTop.count
        outlineView.beginUpdates()
        outlineView.insertItems(
            at: IndexSet(integersIn: 0 ..< delta),
            inParent: nil,
            withAnimation: [])
        outlineView.endUpdates()
    } else {
        // 慢路径：结构变化不是纯前置（跨页 group 合并、旧 head group id 依然稳定所以本质少见
        //   但仍然可能发生：比如 orphan tool_result 从独立顶层节点 collapse 进 tool_use children）
        //   → 一次 reloadData + 完整 restore expand + scroll anchor（scroll anchor 已在外层
        //     restoreScrollAnchor 里按 node identity 处理）
        outlineView.reloadData()
        restoreFoldsAfterReload(store.folds)
    }
    currentAppliedTopLevel = newTop
}

private func isPurePrefixInsertion(old: [TranscriptItem.ID], new: [TranscriptItem.ID]) -> Bool {
    guard new.count > old.count else { return old == new }    // 无 delta 也是纯前置
    return Array(new.suffix(old.count)) == old                 // 新 tree 后段 = 旧 tree
}
```

`currentAppliedTopLevel` 是 Controller 私有字段，每次 apply 结束记下"当前 outline view 顶层是什么 id 序列"；下次 apply 时判"新 tree 是不是旧 tree 前置一段"。**为什么需要这个额外字段**：不能问 `outlineView` 顶层的 items —— 那样是绕一圈从 view 层反问 dataSource；直接记在 Controller 上一层，`dataSource` 变更时同步维护。

**用 `insertItems` 而非 `reloadData` 走快路径**：`NSOutlineView` 支持无 diffable snapshot 的手写 diff（顶层 list 规范："for real trees, classic `NSOutlineViewDataSource` + manual `expandItem`/`collapseItem` is often clearer than forcing diffable"）。避免 O(N) reuse-churn（老 § 2.11 意图）。慢路径 fallback 保证跨页合并等罕见情况仍视觉正确 —— 视觉正确性 > perf。

**取消**：三关卡（`for try await`、Phase 1 前 `checkCancellation`、Phase 2 await 后 `checkCancellation`）覆盖 VC 拆除的所有窗口。detached 内部的 `TranscriptRowHeight.compute` 是 pure fn 不检查 cancel，跑完后结果被下一次 `checkCancellation` 抛出丢弃 —— 一 page worth 的 CPU 浪费在顶层规范里可接受。

### 6.4 锚点保持

Commit 前记录：
```swift
let visibleRange = outlineView.rows(in: outlineView.visibleRect)
guard visibleRange.length > 0 else { return nil }
let firstVisibleRow = visibleRange.location
let anchorNode = outlineView.item(atRow: firstVisibleRow) as? TranscriptOutlineNode
let anchorRectMinY = outlineView.rect(ofRow: firstVisibleRow).minY
let clipOriginY = scrollView.contentView.bounds.origin.y
let anchorOffset = anchorRectMinY - clipOriginY
return ScrollAnchor(node: anchorNode, offset: anchorOffset)
```

Commit 后：
```swift
guard let a = anchor, let node = a.node else { return }
let newRow = outlineView.row(forItem: node)
guard newRow >= 0 else { return }
let newRectMinY = outlineView.rect(ofRow: newRow).minY
let newClipOriginY = newRectMinY - a.offset
scrollView.contentView.scroll(to: NSPoint(x: 0, y: newClipOriginY))
scrollView.reflectScrolledClipView(scrollView.contentView)   // 文档要求成对调用
```

**为什么用 node 引用而不是 row index**：outline view diff 后 row index 变（更旧的 top-level 前置），但 `TranscriptOutlineNode` **对象引用**跨 `deriveOutline` 复用（§ 6.1 `outlineNodePool` 保证 —— 同 id → 同实例）→ `NSOutlineView.row(forItem:)` 可回到同一 node 现在的行号。

**注**：这套锚点只针对**旧页 prepend（自动 loader）**触发。用户**主动 fold** 一个 group 时，不做锚点保持 —— 让 `NSOutlineView.animator().collapseItem` 的 native 动画自然进行（老 renderer 行为一致：主动 fold 不锁滚动）。

## 7. Fold / hover

Fold 与 hover 的完整交互流已在 § 4.3 / § 4.4 说明。要点回顾：

- **Fold**：自绘 chevron 点击 → `delegate.rowViewDidClickChevron` → Controller 直接调 `store.setFold` → `store.$folds.sink` → `applyFolds` diff → `outlineView.animator().expandItem` / `collapseItem`。VM 不参与 fold 面（无 pass-through）。fold state 住 Store，跨 mount 生存。
- **Hover**：`rowViewDidEnterHover(itemID:)` / `rowViewDidExitHover(itemID:)` 方法上报 → Controller 记 `hoveredItemID` → 老 hover row + 新 hover row 各设 `needsDisplay = true`。不 reload / 不 noteHeightOfRows。

## 8. 语法高亮回填 —— 下一 PR

老 renderer 的 `Transcript2HighlightStorage` + JS engine 回填链路保留在 live 路径上不动；新历史 outline 首屏渲染时代码块无着色。下一 PR 引入时以 row view 层的局部重绘 concern 接入 —— **不进 Store / 不进 VM / 不进 outline node**，因为高亮只改颜色不改度量（老 § 2.12）。

**接口位置**：`MarkdownRowView` 与 `ToolBodyRowView` 内部的 code block 子视图暴露一个 `applyHighlight(tokens: HighlightTokens)`，下一 PR 的高亮 service 直接调；不改本 PR 交付的 Store / VM / TranscriptItem。

## 9. DI 与生命周期

### 9.1 Composition root（`AppDelegate.applicationWillFinishLaunching`）

```swift
let transcriptRegistry = TranscriptRegistryStore()
let appContext = AppContext(..., transcriptRegistry: transcriptRegistry)
// ↑ 无任何 SessionManager 接线；Store 生死不与 session 生死挂钩。
```

顶层 `CLAUDE.md` composition root 规范："`AppDelegate.applicationDidFinishLaunching(_:)` 集中装配整个对象图；此处唯一 new 具体实现，中间层直接接收 protocol 类型 —— 无 `.shared`、无 self-construct"。本 PR 只在这里 new `TranscriptRegistryStore()`，其它组件通过 `AppContext` 向下传递。

### 9.2 每 session 装配（`DetailFlowCoordinator.makeChild(.history)`）

```swift
let store = detailContext.transcriptRegistry.store(for: sid)         // get-or-create（Session 域）
let vm = TranscriptViewModel(store: store)                            // 每 mount 新建（VC 域）
return TranscriptOutlineController(viewModel: vm)                     // 每 mount 新建（VC 域）
```

**分层生命周期**：
- **Session 域**：`TranscriptStore` —— items / folds / cursor / 加载 flag 都住这里，跨 mount 存活。
- **VC 域**：`TranscriptViewModel` + `TranscriptOutlineController` —— VM 是 outline tree 派生 + `outlineNodePool` 复用池，只在当次 mount 内有意义；Controller 是 mount 一次的 thin coordinator。VM 是每次 mount 新建，`prepareForRemoval` 时随 Controller 释放。
- **规范依据**：顶层 `CLAUDE.md`："One VC's presentation state → that VC's ViewModel's `@Published`" —— VM 不允许被缓存到 VC 外。跨 mount 的状态（fold / items）住 Store，因为 lowest scope shared by all readers = Session。

### 9.3 生命周期表

| Owner | 生存范围 | 释放触发 |
|---|---|---|
| `TranscriptRegistryStore` | 进程 | AppDelegate 释放（实际不发生） |
| `TranscriptStore`（每 id）| Session 域（registry 槽内）| 本 PR 不释放（Registry 只加不减，见 § 2.4）|
| `TranscriptViewModel` | 一次 mount（VC 域）| Controller `prepareForRemoval` 时随 Controller 释放 |
| `TranscriptOutlineController` | 一次 mount | container 移除 → `prepareForRemoval` |
| `loaderTask` | ≤ Controller | `prepareForRemoval` cancel |
| detached height Task | 绑定 `await` 返回 | 上层 Task cancel → next `checkCancellation` throws；detached 跑完丢弃结果 |

**`prepareForRemoval` 显式清理**（顶层 `CLAUDE.md` § "deterministic teardown"）：
```swift
override func prepareForRemoval() {
    loaderTask?.cancel(); loaderTask = nil
    cancellables.removeAll()
    outlineView.dataSource = nil
    outlineView.delegate = nil
    // VM 随 self 释放（我们 strong hold 它，controller 释放时它就释放）；
    // Store 不释放（Session 域，registry 持有）。
}
```

`nonisolated deinit` 在 `TranscriptViewModel`、`TranscriptOutlineController`、`TranscriptStore` 上都要写（顶层 `CLAUDE.md`：`@MainActor` 类型必须 nonisolated deinit）。

## 10. 性能对齐 —— 老 `NativeTranscript2/CLAUDE.md § 2`

| 老 § 2 项 | v12 保持 |
|---|---|
| § 2.1 sync heightOfRow on cache hit | `rowHeightsByID: [TranscriptItem.ID: CGFloat]` get-or-compute；warm cache 命中；未命中路径**不允许**在首屏 attach 后触发（loader / retile 都预先 off-main 算完再 commit）|
| § 2.2 cell `wantsLayer + .onSetNeedsDisplay` | 每 row view 内部设 |
| § 2.3 scroll + clip `.never` layer redraw | outline view + scrollView + clip 都设 |
| § 2.4 layout cache 无 LRU | rowHeightsByID 挂 Controller；`heightCacheWidth` 变化时整表 invalidate + 全 outline off-main 重算 |
| § 2.5 nonisolated static make | `TranscriptRowHeight.compute(node:width:)` nonisolated pure fn |
| § 2.6 backfill off-main-built + main-sync-applied | 旧页 loader Phase 2 `Task.detached` 算 height；retileAtNewWidth 也是全 outline off-main 重算；commit main。首屏 sync loop 逐 node 同步算入缓存（bounded by viewport height）|
| § 2.7 in-tick anchor for resize | § 4.5 retileAtNewWidth 在 `withoutImplicitAnimations` 内 noteHeightOfRows + layoutSubtreeIfNeeded + restoreScrollAnchor 同 tick |
| § 2.8 live-resize 只碰 visible | § 4.5 `updateRowHeightsForLiveResize(newWidth:)` |
| § 2.9 负宽度 clamp | TranscriptClipView.setFrameSize |
| § 2.10 抑制隐式动画 | 所有 commit 路径（loader commit、fold apply、retile、hover 之外的一切）包 `withoutImplicitAnimations` |
| § 2.11 no `reloadData()` | **保持（快路径）** —— outline diff apply 走 `beginUpdates + insertItems + endUpdates`（§ 6.3 快路径）。首屏 attach 时 `reloadData` 用**一次**（首绑后建索引）。**慢路径 fallback** 保留 `reloadData`（跨页 group 合并等罕见结构变化）—— 视觉正确性 > perf |
| § 2.12 highlight refill 跳过 noteHeightOfRows | 下一 PR 接入时保持（本 PR 不做高亮）|
| § 2.13/b search / status | 搜索超范围；status history 全 completed |
| § 2.14 anti-poison cache | `rowHeightsByID[id]` 不覆写已有条目 |
| § 2.15 highlight per-scope dedup + gen guard | 下一 PR 接入时保持 |
| § 2.16 shimmer overlay | `ToolInvocationHeaderRowView` 内部自绘 |
| § 2.17 stable row-reuse key | `TranscriptOutlineRow` + per-kind reuse identifier（见 § 2.11 分派）|
| § 2.18 stable Item id | `TranscriptItem.ID` 由 `(stableMessageID, contentIndex, blockIndex)` 三元组派生；nil-uuid fallback 见 § 2.1；`outlineNodePool` 保 node 引用稳定 |
| § 2.19 每 attach 一个 width | § 4.1 attach 契约：sync loop 里高度按 `heightCacheWidth` 入缓存 → dataSource 绑 → reload → 首次 heightOfRowByItem 命中 |
| § 2.18 stable Block.id | node.id 由 `(itemID, kind)` 稳定派生；nodeCache 保引用稳定 |
| § 2.19 每 attach 一个 width | § 4.1 attach 契约：先 sync 首屏 + heights 入缓存 → dataSource 绑 → reload → 首次 heightOfRowByItem 命中 |

## 11. 测试

`cctermTests/` 遵循顶层 `CLAUDE.md` 规则（无 `forceXxxForTest`、不放宽访问；driver public 面；断言 observable output）。

- **`TranscriptItemBuilderTests`**：`Message2` fixture →
  - markdown `.text` 拆成 heading / paragraph / codeBlock / list / table / blockquote / thematicBreak 独立 item（每 markdown block 一条），`blockIndex` 依次递增
  - `.thinking` → 一条 `.assistantThinking`
  - `.toolUse` → 一条 `.assistantToolUse`
  - user `.image` 每张一条 `.userAttachmentImage`；`.toolResult` 一条 `.userToolResult`
  - 系统类消息 → 一条 `.systemMeta(SystemMetaKind)`
  - id 稳定：`(stableMessageID, contentIndex, blockIndex)` 三元组一致；`Message2Assistant.uuid == nil` 时 fallback 到 `"page@\(pageCursor)/msg\(indexInPage)"`
  - **id 碰撞回归**：单条 assistant message 含 `.text`（拆成 3 个 markdown block）+ `.toolUse` 的混合 content —— 断言 4 条 item id 互不相等
- **`TranscriptStoreOrderTests`**：`prependOlderItems` 多次后 items 永远 wall-clock 正向；空 store prepend = 赋值；首次调用后 `didLoadFirstScreen == true`；`nextCursor == nil` 翻 `didFinishLoad == true`
- **`TranscriptStoreFoldsTests`**：`setFold` 更新 `@Published folds` dict；folds 是 Store 拥有的持久状态；VM 释放（controller 释放）后 folds 仍在
- **`TranscriptStoreScrollAnchorTests`**：`setScrollAnchor` 写入；controller 释放前调用；二次构造 VC 时从 store 读出正确 anchor
- **`TranscriptViewModelInitTests`**：**pre-populated store**（`store.items` 非空）+ new VM → `viewModel.outline` **立即**非空（init 里已 derive，不 dropFirst 到空 outline）
- **`TranscriptViewModelDeriveTests`**：
  - text-only → outline top-level 全 markdown nodes
  - 3 条相邻 tool_use → 一个 `.toolGroup` 顶层 node，children 是 3 个 `.assistantToolUse` node
  - **1 条 tool_use 也升级为一元素 group**（不允许降级）
  - tool_use + 紧跟 tool_result → invocation node 含 body child
  - Orphan tool_result 首屏 → scan 末 `emitOrphanResults` 产独立 `.toolBody` 顶层节点（不允许降级）；prepend 对应 tool_use 后再次 deriveOutline → 正确关联到 invocation children，独立 body 顶层消失
  - 跨页边界可分组段（旧页尾 + 新页头都是 tool_use）→ prepend 后合并同一 group
  - `.systemMeta` skip：夹在两个相邻 tool_use 之间**不切开** group（仍是同一段）；也不出 outline node
- **`TranscriptViewModelGroupHeaderStableIdTests`**：
  - **尾锚定回归**：先有一个 head group [A]（用户展开）；prepend 一批含更旧 tool_use X/Y/Z 使合并为 [X, Y, Z, A]；断言合并后 group id 仍是 `"group#\(A.id)"`（尾未变）；断言 VM `outlineNodePool` 里 `"group#\(A.id)"` 的 node 引用与合并前 `===`
- **`TranscriptViewModelNodeIdentityTests`**：连续两次 `deriveOutline` 输入 items 头部前置一条，未变部分 node 实例 `===`（`outlineNodePool` 复用）
- **`TranscriptViewModelPureFnTests`**：drive `TranscriptViewModel.deriveOutline(items:, pool: &localPool)` 用 local 空 pool → 断言 VM 自身的 `outlineNodePool` 引用不变（pure fn 契约）；同 items + local 空 pool vs `&outlineNodePool` 产 tree 结构相等（拓扑等价、id 集合相等）
- **`TranscriptOutlineControllerAttachOrderTests`**：drive `viewDidLoad` + `viewDidLayout`（stub SDK 返回 canned Page）；断言首屏 sync loop 后 `outlineView.numberOfRows == expected`（**不**用 call-counter 型断言）
- **`TranscriptOutlineControllerSecondMountTests`**：pre-populated store + new controller + 触发 `viewDidLayout` → **不**再调 `loadPage`（stub SDK 若被调则 fail）；`outlineView.numberOfRows` 立即 = `store.items` 派生出的 outline top-level 数；scroll 位按 `store.lastKnownScrollAnchor` 恢复
- **`TranscriptOutlineControllerFoldTests`**：drive `rowViewDidClickChevron(itemID:)` → 断言 `store.folds[id] == true`（Controller 直接调 store，不经 VM）；再 drive `store.setFold(id, false)` → 断言 `outlineView.isItemExpanded(node) == false`
- **`TranscriptOutlineControllerApplyOutlineTests`**：
  - 快路径：pre-existing outline `[A, B, C]`；prepend 使 outline 变 `[X, Y, A, B, C]` → 断言 outline view 走 `insertItems(at: 0..<2)`，不走 reloadData
  - 慢路径：结构非纯前置（比如 orphan tool_result 从独立顶层节点 collapse 进 invocation children）→ 断言走 reloadData + `restoreFoldsAfterReload`
- **`TranscriptOutlineControllerAnchorMathTests`**：stable fixture（每 row 60pt）；prepend 一批更旧 5 nodes 后 clip.origin.y 使 `topVisibleNode` 视觉位置不变（新 origin.y = 旧 origin.y + 5×60）；variable-height fixture 也测一次
- **`TranscriptOutlineControllerRetileTests`**：drive `viewDidLayout` 变宽（非拖拽） → 断言 `rowHeightsByID` 全清后按新宽度重算；drive `viewDidLayout` 在 `inLiveResize` = true 时 → 断言 `rowHeightsByID` 未清、`heightCacheWidth` 未变
- **`TranscriptClipViewCenteringTests`**：documentView 宽 500，`constrainBoundsRect` 于 proposed 宽 800 / 500 / 300 → origin.x = -150 / 0 / 0
- **`TranscriptOutlineViewDisclosureHiddenTests`**：`frameOfOutlineCell(atRow:)` 返回 `.zero`（直接调 API 断言）
- **`SessionHistoryCursorTests`**：cursor + Page 正确；`stream` 与 `loadPage` 同 fixture 产**相同**页序列（两条 API 语义完全一致 —— 没有跨调用 buffer 差异）；orphan tool_result **不**被跨页 withhold（页内原样吐出，由 VM 侧处理）
- **`SessionHistoryStreamProducerThreadTests`**：drive `stream(id:cursor:)` 从 MainActor Task 里 iterate；用 `dispatchPrecondition` 或 `Thread.isMainThread` 断言 producer 里的 `loadPage` 调用**不**在 main thread（顶层规范：producer 强制 off-main）

## 12. Rollout

1. **SDK**：`Cursor` + `Page` + `loadPage(sync)` + `stream(cursor:)`（producer 强制 `Task.detached`）；`_ReverseBatchPairer` 更名 `_ReversePageOrderFixup`（只做页级正序化，不做跨页 tool 语义 buffer）；删除 `load(id:order:)`；SDK cursor + 页级正序化测试 + producer off-main 测试。
2. **Model**：`TranscriptItem` + `TranscriptOutlineNode` + `TranscriptOutlineTree` + `ToolGroupHeader` + `ToolInvocation` + `ToolBodyKind` + `ImageRef` + `SystemMetaKind` + `ListPayload` + `TablePayload` + `GutterAction`（markdown payload 类型从 `Components/Markdown` IR 复用）。
3. **Builder**：`TranscriptItemBuilder` `enum` + `static`；markdown 拆分逻辑；`.systemMeta` 落所有非语义消息类；id 三元组派生（`stableMessageID` + `contentIndex` + `blockIndex`）+ nil-uuid fallback。
4. **Store**：`TranscriptStore` + `TranscriptRegistryStore`；**无 `SessionManager` 接线**；Registry 只加不减；`folds` / `lastKnownScrollAnchor` 是持久跨 mount 状态。
5. **VM**：`TranscriptViewModel`（`static deriveOutline(items:pool:)` pure fn + `outlineNodePool` 复用池 + init 立即 derive + 不 dropFirst 订阅）。**不**暴露 fold API（Controller 直接调 store）；**没有** `previewOutline` 孪生方法（loader 直接调 pure fn `deriveOutline` with local pool）。**每次 mount 新建**，不缓存。
6. **View**：
   - `TranscriptClipView`（居中）
   - `TranscriptOutlineView`（`NSOutlineView` 子类 —— override `frameOfOutlineCell(atRow:)`）
   - `TranscriptRowView` 基类 + 4 类具体：`MarkdownRowView` / `ToolGroupHeaderRowView` / `ToolInvocationHeaderRowView` / `ToolBodyRowView` + 10 个 per-tool-kind body subclass；`ToolBodyKind` enum 集中管理 reuse identifier
   - **小改** `RowLayout` 让它按 `TranscriptItem` 输入（不再看老 `Block`）
   - **参考迁移** `Layout/ToolGroupChildren/<Kind>/*Layout.swift` 里 body 度量到对应 body subclass
7. **Controller**：`TranscriptOutlineController`；挂 `DetailFlowCoordinator.makeChild(.history)`（替换现存对未实现类型的引用）；`applyOutline` 快/慢分支；`prepareForRemoval` 写回 `lastKnownScrollAnchor`。
8. **单元测试**：见 § 11。
9. **Clean build + 跑测试 + 手动 QA**：
   - (a) 开会话响应快 + 无空白闪现
   - (b) 滚顶加载旧页 + 锚点保持
   - (c) 侧边栏切走/回 items + folds + 滚动位保
   - (d) window resize 触发 retile；drag 触发 updateRowHeightsForLiveResize
   - (e) group 和 tool 两级 native fold 动画正确
   - (f) markdown 每 kind、user bubble、image attachments、每种 tool body 渲染与老 renderer 视觉等价（**不允许降级**）
   - (g) orphan tool_result 首屏时显示为独立 body 节点，旧页 prepend 后正确合入 invocation
   - (h) 单条可分组消息作为一元素 group 显示（不作为 standalone invocation）

## 13. 下一 PR（本 PR 不做，接口留好）

- **语法高亮回填**：接 `MarkdownRowView` / `ToolBodyRowView` 的 `applyHighlight(tokens:)`。Store / VM / TranscriptItem 不动。
- **跨行选择**：新 `TranscriptSelectionStore`（由 `TranscriptStore` 拥有，因为选择态应跨 mount 生存）；row view mouse 事件 forward 到 controller、再 forward 到 selection store。
- **User bubble sheet / image preview sheet**：Delegate 已有 `requestUserBubbleSheet(itemID:)` / `requestImagePreview(image:)` 钩子，本 PR 只 log；下一 PR 接 sheet presenter。
- **⌘F 搜索**：接 VM 一个 query 面 + row view 高亮态。
- **顶/底 scrim overlay**：scroll view 的兄弟 view，不动 outline。
- **老栈从 `Session.swift` 拆出**：live 路径迁移到新栈后。

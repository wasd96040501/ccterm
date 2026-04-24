# NativeTranscript `Core/` — 组件协议

**状态:** 协议落地 + 全量迁移完成。3 个老 Row 子类已替换为 3 个 Component enum
(`Placeholder` / `UserBubble` / `AssistantMarkdown`)。老 `Rows/` `Refinements/`
`Controller/TextSelectable.swift` 与 3 个 `*PreparedItem.swift` 已删除。

---

## 1 设计目的

老代码每加一种 row 要面对 6-8 个散落概念(`TranscriptRow` / `InteractiveRow` /
`ExpandableRow` / `RowRefinement` / `TextSelectable` / `*PreparedItem` / 集中
`TranscriptPrepare` switch / `TranscriptPrepareCache.Variant`),且要改 3-4 个
集中文件。

新模型把作者面对的认知维度压到 **4 轴 + 1 可选(状态)** —— 一个 `enum
MyComponent: TranscriptComponent` 的单文件定义就能扩展,不动任何 framework
代码。

---

## 2 作者视角

```swift
enum MyThingComponent: TranscriptComponent {
    static let tag = "MyThing"

    // 4 个正交轴
    struct Input: Sendable { ... }                    // entry 里我关心的字段
    struct Content: Sendable { ... }                  // parse 结果,宽度无关
    struct Layout: HasHeight { ... }                  // width × state 排版结果
    typealias State = Void                            // 默认 stateless

    // 从 entry 挑出我的 inputs(只挑自己关心的 block,不排他)
    static func inputs(from: MessageEntry, entryIndex: Int) -> [IdentifiedInput<Input>]

    // off-main parse / hash / layout
    static func prepare(_: Input, theme:) -> Content
    static func contentHash(_: Input, theme:) -> Int
    static func layout(_: Content, theme:, width:, state:) -> Layout

    // MainActor 绘制
    @MainActor static func render(_: Layout, state:, theme:, in ctx:, bounds:)

    // 可选 override:interactions / selectables / applySelection / clearingSelection /
    //   selectedFragments / refinements / makeSideCar / relayouted
}
```

**新增 component:** 在 `Components/MyComponent.swift` 写一个 enum +
在 `TranscriptComponentRegistry.inputsAndItems(...)` 里加一行 dispatch。
不改 controller / cache / builder / pipeline。

---

## 3 模块布局

```
Core/                              # 协议骨架(本目录)
├── TranscriptComponent.swift      # 主协议 + 默认实现
├── ComponentRow.swift             # PreparedItem<C> + ComponentRow + ComponentCallbacks
├── AnyPreparedItem.swift          # Builder/cache/pipeline 持有的 type-erased 容器
├── StableId.swift                 # 结构化 row id + IdentifiedInput<Input>
├── SelectableSlot.swift           # 选中 slot 声明(纯数据)
├── Interaction.swift              # Interaction<C> + RowContext<C>(受限视图)
├── Refinement.swift               # Refinement<C> + ContentPatch<C> + RefinementContext
└── RowSideCar.swift               # 逃生门协议(GPU/CALayer)

Components/
├── PlaceholderComponent.swift     # Tool / Group / 占位虚线框
├── UserBubbleComponent.swift      # User 气泡 + chevron 折叠 (State = (isExpanded, selection))
├── AssistantMarkdownComponent.swift  # Markdown(text/heading/list/table/codeBlock/quote/break)
├── AssistantMarkdownPrebuilder.swift # MarkdownDocument → PrebuiltSegment(per-Assistant 用)
└── TranscriptComponentRegistry.swift # entry → inputs walker

Prepare/
├── TranscriptRowBuilder.swift     # prepareAll / prepareBoundedTail / prepareBoundedAround
└── TranscriptPrepareCache.swift   # (contentHash, tag) → CachedContent LRU

Controller/                        # framework 端 — 用户无需改
├── TranscriptController.swift     # rows: [ComponentRow], state-apply / hit / scroll
├── TranscriptController+Pipeline.swift  # 4 reason → 4 pipeline 调度
├── TranscriptController+Merge.swift     # transition → NSTableView 原子应用
├── TranscriptController+Hit.swift       # 点击/光标 → callbacks 分派
├── TranscriptRowView.swift              # CALayerDelegate.draw → callbacks.render
├── TranscriptSelectionController.swift  # drag → slot.selectionKey → callbacks.applySelection
├── TranscriptTableView.swift, TranscriptScrollView.swift, ...
```

---

## 4 关键决策

### 4.1 Row 从 class 降级为 struct

`ComponentRow` 是 struct;`controller.rows: [ComponentRow]` 直接持有 value。
GPU/CALayer 资源走 `SideCar: RowSideCar` 关联类型逃生门。Selection / 展开等
状态进 `C.State`(Sendable 值类型)。

### 4.2 Selection 通过 `applySelection` 路由

`SelectableSlot` 不带 `setSelection` 闭包(避免回引 row class)。每个 slot
带一个 `selectionKey: AnyHashable`,framework 拖动结算后调
`C.applySelection(key:, range:, to:)` 让 component 把 range 折进 state。
对应 `clearingSelection(state:)` 与 `selectedFragments(layout:, state:)`
覆盖 Cmd-C 拼接。

### 4.3 Interaction 是意图 enum 不是闭包

老 `InteractiveRow.hitRegions` 的 `perform: (TranscriptController) -> Void`
让 row 任意 poke controller 全局。新 `Interaction<C>`:

| case | framework 标准副作用 |
|---|---|
| `.toggleState(rect, newState, cursor)` | 自动 `applyState(newState)` + relayout + redraw |
| `.copy(rect, text, cursor)` | 写剪贴板 + clearSelection + redraw |
| `.openURL(rect, url, cursor)` | NSWorkspace open + clearSelection |
| `.custom(rect, cursor, handler)` | 给 handler 一个 `RowContext<C>`(无 controller),其余应用层 ownership 链 |

`RowContext<C>` 提供 `currentState()` + `applyState(_:)` + `noteHeightOfRow()` +
`redraw()` + `clearSelection()` + `sideCar()`,实现"row 知道自己能做什么但
不能越权"。

### 4.4 Sticky state(跨 row rebuild 持久化)

控制器 `stickyStates: [StableId: any Sendable]` 存所有 component 的 sticky
state(主要服务 UserBubble 的 expanded 折叠态)。`Interaction.toggleState`
框架自动写入。Builder 接受 `stickyStates: [StableId: any Sendable]` 参数
(便利构造器 `[StableId: any Sendable].expandedUserBubbles(_:)`),为新 row
按 stableId 查 sticky 作初始 state。

### 4.5 Refinement 是纯数据

`Refinement<C>.run() -> ContentPatch<C>`(纯闭包)。framework 调 `.run()`,
拿 patch,`patch.apply(oldContent)` 得到新 content,重跑 layout,reload row。
Refinement 不持 row 引用、不 mutate 任何东西、`Sendable` 天然。

`refinements(_ content:, context:)` 接收 `RefinementContext`,framework 注入
`theme + syntaxEngine` 等共享资源 —— refinement 不直接抓 controller。

### 4.6 双路 highlight

- **off-main batch path**(pipeline 内):`AssistantMarkdownComponent.highlightRequests(item)`
  + `applyTokens(item, tokens, theme, width)` —— pipeline 收集所有 row 的 code
  block 请求,一次 `engine.highlightBatch(...)` JSCore 调用,把 tokens 折回 items
  再 makeRow。这是首屏 TTFP 的关键路径。
- **on-main refinement path**(merge 后兜底):`refinements(_ content:, context:)`
  + `Refinement.run() -> ContentPatch` —— 走通用 refinement scheduler。捕获
  carry-over rows / cache 命中但未 highlight 的 row。

两路共享 engine 的同 tick coalescing,实际 JSCore 跨界次数仍接近 1。

### 4.7 StableId 结构化

`struct StableId { entryId: UUID; locator: Locator }`。`locator` 区分
`whole / block(Int) / custom(String)`,匹配多 component 同 entry 的场景
(assistant entry 里 text → `.block(textStartIdx)`, tool_use → `.block(idx)`)。
`SavedScrollAnchor` 等外部接口直接读 `stableId.entryId`,不再做字符串解析。

### 4.8 一个 entry 多 component 共享

`entry → component.inputs(from:)` 不排他。assistant entry 里 text block 归
`AssistantMarkdownComponent`,tool_use block 归 `PlaceholderComponent`。
`TranscriptComponentRegistry.inputsAndItems(...)` 各 component 走一遍并
按 `(entryIndex, blockIndex)` merge-sort 出最终行序。

---

## 5 使用规范(给后续 component 作者)

1. 一个 component 文件 = 一个 `enum FooComponent: TranscriptComponent`
2. 不引用 `TranscriptController` / 任何 controller 类型
3. 通过 `RowContext<Self>` 完成所有 "告诉 framework 我变了" 的副作用
4. State 设计:
   - 单字段 → `typealias State = Bool` / `Int` / 等 Sendable 类型
   - 多字段 → `struct State: Sendable { ... }`
   - Stateless → `typealias State = Void`(继承默认 `initialState`)
5. Refinement 不持 self / row 引用,要靠 `RefinementContext` 注入 engine
6. 注册:`TranscriptComponentRegistry.inputsAndItems(...)` 加一行 walker
   (Assistant 类有 highlight,需要走 `prepareAndAssistant` 专用入口注入
   `highlightProvider` / `tokenApplier`)

---

## 6 编译验证

```bash
make build
make test TEST=cctermTests/UserBubbleCollapseTests
make test TEST=cctermTests/TranscriptDiffTests
make test TEST=cctermTests/TranscriptPrepareCacheTests
make test TEST=cctermTests/TranscriptPrepareTests
make test TEST=cctermTests/TranscriptPrepareTailTests
make test TEST=cctermTests/TranscriptControllerReasonDispatchTests
```

全部 ✅。

---

*本目录文件由 `feat/sessionhandle2-migration` 分支于 2026-04-24 完成全量迁移。*

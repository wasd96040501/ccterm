# NativeTranscript

原生 AppKit transcript,替代 WKWebView-based 聊天渲染。
`NativeTranscriptView.swift`(`NSViewRepresentable`)桥进 SwiftUI。

## 1. 心智模型(读完这节再动代码)

**一种 row 类型 = 一个 `enum FooComponent: TranscriptComponent`**。
协议在 `Core/TranscriptComponent.swift`,四个正交轴:

| 轴 | 类型 | 回答 |
|---|---|---|
| Input   | `associatedtype Input: Sendable` | 我从 `MessageEntry` 的哪些字段取料? |
| Content | `associatedtype Content: Sendable` | Parse 结果,宽度无关,进 cache 的就是这个 |
| Layout  | `associatedtype Layout: HasHeight` | 给定 width × state 算出排版 |
| State   | `associatedtype State: Sendable = Void` | Row-local 状态(折叠 / 选中 range / etc.) |

再加一个可选 `SideCar: RowSideCar` — row 要持 `CALayer` / GPU 资源时用的逃生门。

**Pipeline(off-main):** `inputs(from: entry)` → `prepare(input)` → `layout(content, width, state)` → `render(layout, in: ctx)`(MainActor)。
Framework 把 off-main 结果打包成 `PreparedItem<C>`,过 MainActor 边界 type-erase 成 `ComponentRow`,Controller 持 `[ComponentRow]`。

**一个 entry 可被多个 component 各扫一遍**(非排他):assistant entry 里 text blocks 归 `AssistantMarkdownComponent`,tool_use blocks 归 `PlaceholderComponent`。`TranscriptComponentRegistry.inputsAndItems(...)` 按 `(entryIndex, blockIndex)` merge-sort 得最终行序。

## 2. 目录

```
Core/                                 # 协议骨架 — 扩 framework 时读,写 component 时只读 TranscriptComponent.swift 就够
├── TranscriptComponent.swift         # 主协议 + 默认实现(selectables/interactions/refinements 默认空等)
├── ComponentRow.swift                # PreparedItem<C> / ComponentRow / ComponentCallbacks / AnyInteraction / AnyRowContext
├── AnyPreparedItem.swift             # Sendable off-main type-erase 容器(builder/pipeline/cache 用)
├── StableId.swift                    # StableId { entryId, .whole/.block(Int)/.custom } + IdentifiedInput<Input>
├── Interaction.swift                 # Interaction<C> enum + RowContext<C>(受限视图)
├── SelectableSlot.swift              # Slot 纯数据:ordering / frame / layout / selectionKey
├── Refinement.swift                  # Refinement<C> + ContentPatch<C> + RefinementContext(注入 theme + syntaxEngine)
└── RowSideCar.swift                  # 逃生门协议 + EmptyRowSideCar 默认实现

Components/                           # 现有 component 实现(一个文件一个 component)
├── PlaceholderComponent.swift        # Tool / Group 占位虚线框 · State = Void
├── UserBubbleComponent.swift         # User 气泡 · State = { isExpanded, selection } · 有 relayouted 快路径
├── AssistantMarkdownComponent.swift  # Markdown(text/heading/list/table/codeBlock/quote) · 有 highlight refinement
├── AssistantMarkdownPrebuilder.swift # MarkdownDocument → PrebuiltSegment(AssistantMarkdownComponent 内部工具)
└── TranscriptComponentRegistry.swift # entry → [AnyPreparedItem] 的 dispatch 表(新增 component 要改这里)

Prepare/
├── TranscriptRowBuilder.swift        # prepareAll / prepareBounded / prepareBoundedTail / prepareBoundedAround
└── TranscriptPrepareCache.swift      # (contentHash, tag) → CachedContent LRU

Controller/                           # Framework 端 — 写 component 时不应引用;改 pipeline / merge / hit / scroll 时读
├── TranscriptController.swift        # rows: [ComponentRow], stickyStates, state-apply / hit / scroll
├── TranscriptController+Pipeline.swift  # 4 reason → 4 pipeline 调度;highlight batch 路径
├── TranscriptController+Merge.swift     # transition → NSTableView 原子应用
├── TranscriptController+Hit.swift       # 点击/光标 → callbacks 分派 → Interaction 意图执行
├── TranscriptRowView.swift              # CALayerDelegate.draw → callbacks.render
├── TranscriptSelectionController.swift  # drag → slot.selectionKey → callbacks.applySelection
└── TranscriptTableView.swift / TranscriptScrollView.swift / TranscriptScrollIntent.swift / TranscriptUpdateTransition.swift

Layout/                               # 共享排版工具(CT 封装、table 模型)
├── TranscriptTextLayout.swift
├── TranscriptTableLayout.swift
└── TranscriptListLayout.swift

NativeTranscriptView.swift            # SwiftUI NSViewRepresentable 入口
TranscriptTheme.swift                 # 字体 / 颜色 / margin / 所有几何常量;改视觉先在这里加字段
OpenMetrics.swift                     # 性能打点
```

## 3. 新增一个 Component(模板)

**改动范围:** 新建 `Components/MyComponent.swift` + 在 `TranscriptComponentRegistry.inputsAndItems(...)` 加一段 dispatch。**不碰** controller / builder / cache / pipeline。

```swift
enum MyComponent: TranscriptComponent {
    static let tag = "MyThing"                     // 全局唯一

    struct Input: Sendable { ... }
    struct Content: Sendable { ... }
    struct Layout: HasHeight { let cachedHeight: CGFloat; ... }
    typealias State = Void                         // stateless 最省心

    nonisolated static func inputs(from entry: MessageEntry, entryIndex: Int) -> [IdentifiedInput<Input>] {
        // 挑自己关心的 block;不归我管返回 []
    }

    nonisolated static func prepare(_ input: Input, theme: TranscriptTheme) -> Content { ... }
    nonisolated static func contentHash(_ input: Input, theme: TranscriptTheme) -> Int { ... }
    nonisolated static func layout(_ content: Content, theme: TranscriptTheme, width: CGFloat, state: State) -> Layout { ... }

    @MainActor static func render(_ layout: Layout, state: State, theme: TranscriptTheme, in ctx: CGContext, bounds: CGRect) { ... }
}
```

**在 `TranscriptComponentRegistry.inputsAndItems(...)` 加:**

```swift
for input in MyComponent.inputs(from: entry, entryIndex: entryIndex) {
    out.append(prepareAndLayout(MyComponent.self, identified: input,
                                theme: theme, width: width, stickyStates: stickyStates))
}
```

**如果需要异步补齐(highlight / image fetch / diagnostics):** override `refinements(_:context:)` 返回 `[Refinement<Self>]`。
**Assistant 这种需要 off-main batch highlight 的:** 参考 `AssistantMarkdownComponent.highlightRequests(...)` + `applyTokens(...)` + registry 里的 `prepareAndAssistant` 专用入口。

## 4. State 设计速查

| 需求 | 做法 |
|---|---|
| 无状态 | `typealias State = Void` — 自动继承 `initialState` 默认实现 |
| 单 bool | `typealias State = Bool` |
| 多字段 | `struct State: Sendable { ... }` |
| 跨 rebuild 持久化(折叠态之类) | 由 `Interaction.toggleState` 写入 controller 的 `stickyStates: [StableId: any Sendable]`,下次 builder 自动作为初始 state 取用 |

State 变化走 `Interaction.toggleState(rect, newState, cursor)` 或 `RowContext.applyState(_:)` — framework 会自动 `applyState → relayouted(快路径)或 layout(兜底)→ noteHeightOfRow → redraw`。

## 5. 不变量 / 禁令(踩中就是 bug)

- **Component 不 import `TranscriptController`,不引用任何 Controller 类型。** 所有副作用通过 `RowContext<C>` 或 `Interaction<C>` enum case。
- **`ComponentRow` 是 struct,Row 不可变。** 任何"改 row"的想法都是错的 — 改 state 就走 `applyState`,改 content 就走 refinement,改 layout 就让 framework 重跑。
- **Refinement 不持 self / row 引用、不 mutate 任何东西。** `Refinement<C>.run() -> ContentPatch<C>` 是 `@Sendable async` 纯闭包。需要共享资源(`syntaxEngine` 等)从 `RefinementContext` 取,不要直接捕获。
- **`ContentPatch.apply` 必须幂等** — 同一 patch 二次 apply 结果等价,framework 在 cache 重入场景会多次调。
- **`StableId.locator` 语义**:`.whole` = 一 entry 映射一 row;`.block(Int)` = 一 entry 多 row,Int 为 `entry.content` 里 block 的下标;`.custom(String)` = 逃生门。`SavedScrollAnchor` 等外部 API 只读 `stableId.entryId`,不解析 locator。
- **`C.tag` 全局唯一**。用作 cache key 命名空间 + NSTableView row reuse identifier。命名 = 类型名(去掉 `Component` 后缀约定,但不强制)。
- **GPU / NSObject 资源必须走 SideCar**。不要在 Content/Layout 里存 class 引用。
- **Row 不得触发副作用**去修 controller 全局状态(`expandedUserBubbles` / selection 清除 / reload 等)。这些通过 `Interaction` enum 声明,framework 做。`.custom` 逃生门的 handler 拿的也是 `RowContext<C>` 不是 controller。

## 6. 关键架构决策(边界判断用)

- **Row 从 class 降级为 struct,SideCar 作为 GPU 逃生门。** 原因:大部分 row 是纯 CGContext 绘制,class 反向引用 table 做 `noteHeightOfRow` 耦合过重;Sendable 值类型可以跨 `Task.detached` 免锁传。
- **Interaction 是意图 enum,不是闭包。** 原因:老 `InteractiveRow.hitRegions` 的 `perform: (TranscriptController) -> Void` 让 row 可以任意 poke 全局,不可测不可日志。新 `.toggleState` / `.copy` / `.openURL` / `.custom` 让 framework 能做标准副作用(反馈动画、剪贴板、NSWorkspace),`.custom` 的 handler 看不到 controller。
- **Selection 路由:slot.selectionKey + component.applySelection(key:range:to:)。** 原因:老设计 slot 带 `setSelection` 闭包会回引 row class;现在 slot 是纯数据,framework drag 结算后按 key dispatch 到 component 的 state 字段。`range.location == NSNotFound || length == 0` 代表清空。
- **双路 highlight:off-main batch + on-main refinement 兜底。** Batch 路径(`highlightRequests` + `applyTokens`)在 pipeline 里攒一次 JSCore 调用,服务首屏 TTFP;refinement 路径(`refinements(_:context:)` + `Refinement.run()`)捕获 carry-over / cache 命中但未 highlight 的 row。两路共享 engine 同 tick coalescing。
- **StableId 结构化(非字符串)。** 原因:老代码用 `"<uuid>-md-N"` 字符串拼接,scroll anchor / diff 反复 split-dash 出 entryId 不稳。现在 `{ entryId: UUID, locator: enum }`,字段读取。

## 7. 改动前清单

写新 component:读 `Core/TranscriptComponent.swift`(协议 + 默认实现)→ 看 `Components/PlaceholderComponent.swift`(最小例子)或 `UserBubbleComponent.swift`(带 state + relayouted 快路径)→ 按第 3 节模板起步。

改现有 component:stateless → state-ful 的话注意 `Interaction.toggleState` 会走 sticky state,需要想清楚跨 rebuild 语义。

改视觉常量:`TranscriptTheme.swift` 加字段;`contentHash` 如果依赖 theme 字段,要在 `TranscriptTheme.fingerprint` 里纳入,否则 cache 会给出旧 content。

改 framework(pipeline / controller):先跑 `make test TEST=cctermTests/TranscriptControllerReasonDispatchTests` 和 `TranscriptDiffTests` / `TranscriptPrepareTests` / `TranscriptPrepareTailTests` / `TranscriptPrepareCacheTests` / `UserBubbleCollapseTests`,这批覆盖了 pipeline 的 4 reason 分派、diff、cache 行为。

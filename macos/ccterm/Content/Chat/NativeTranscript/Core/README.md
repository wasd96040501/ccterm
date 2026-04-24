# NativeTranscript `Core/` — 组件协议重构接力文档

**分支:** `feat/sessionhandle2-migration`
**上下文:** NativeTranscript 模块(`macos/ccterm/Content/Chat/NativeTranscript/`) 的 component 体系重构。
**状态:** 协议骨架已落地(本目录),老代码未动,迁移未开始。
**受众:** 接手这件事的下一个人。

---

## 1 为什么做这件事

### 今天的痛

一个作者想在 transcript 里加一种新的 row(比如 `ToolBlockRow` / `ImageBubbleRow` / `ThinkingBlockRow`)要**同时**面对 6-8 个散落概念:

| 概念 | 类型 | 职责 |
|---|---|---|
| `TranscriptRow` | class 基类 | 数据 + 绘制 + table 反向操作 + selection 默认实现 5 职责混在一起 |
| `InteractiveRow` | protocol | 点击区域声明,perform 闭包可直接 poke controller 全局状态 |
| `ExpandableRow` | protocol | 展开状态 sync(只对 isExpanded 特化) |
| `RowRefinement` + `RowRefinementWork` | 2 个 protocol | 异步补齐声明 |
| `TextSelectable` | protocol | 选中区域 + selectionHeader + clearSelection |
| `*PreparedItem` struct | per-component | off-main Sendable 包装;每种 row 一份几乎同构的 struct |
| `TranscriptPrepare.<type>` | 集中静态函数 | prepare/layout 函数堆一个 enum |
| `TranscriptPrepareCache.Variant` | enum | 老三 case `.user / .assistant / .placeholder`,加 row 要改 |
| `TranscriptRowBuilder` | 集中 dispatch | 硬编码 entry → component 的 switch + 3 套 `cachedOrBuild*` 模板函数 |

每加一种 row 要**改 3-4 个集中文件** + **继承 + adopt 若干协议**。框架内部流水线的切分(off-main prepare / width-aware layout / MainActor mount)直接泄露给作者。

### 重构的核心目的

**压缩作者面对的认知维度到 4 轴 + 1 可选(状态)。** 一个 component 的定义 = 一个 `enum MyComponent: TranscriptComponent` 文件,没有 class 继承、没有多协议 adopt、没有集中文件修改。

---

## 2 目标形态:作者视角

```swift
// Components/MyThing.swift — 一个文件,不改任何 framework 代码
enum MyThingComponent: TranscriptComponent {
    static let tag = "MyThing"

    // 4 个正交轴
    struct Input: Sendable { ... }                    // entry 里我关心的字段
    struct Content: Sendable { ... }                  // parse 结果,宽度无关
    struct Layout: HasHeight { ... }                  // width×state 排版结果
    typealias State = Void                            // 默认 stateless;需要时换别的 Sendable

    // 从 entry 挑出我的 inputs(只挑自己关心的 block,不排他)
    static func inputs(from entry: MessageEntry, entryIndex: Int) -> [IdentifiedInput<Input>] { ... }

    // off-main parse/hash/layout
    static func prepare(_: Input, theme: TranscriptTheme) -> Content { ... }
    static func contentHash(_: Input, theme: TranscriptTheme) -> Int { ... }
    static func layout(_: Content, theme: TranscriptTheme, width: CGFloat, state: State) -> Layout { ... }

    // MainActor 绘制
    @MainActor
    static func render(_: Layout, state: State, theme: TranscriptTheme,
                       in ctx: CGContext, bounds: CGRect) { ... }

    // 可选(有默认空实现): interactions / selectables / refinements / makeSideCar /
    // relayouted (StatefulComponent 快路径)
}
```

**没有 class,没有继承,没有 adopt 多个 Row 协议**。Component 是一个 enum(或 struct) + 静态方法集合。

---

## 3 当前 `Core/` 目录落地内容

本次 commit 仅**新增**以下文件,绝未动老代码:

```
Core/
├── StableId.swift            结构化 stableId + IdentifiedInput<Input>
├── SelectableSlot.swift      选中区域声明(取代 TextSelectable.selectableRegions)
├── Interaction.swift         Interaction<C> enum + RowContext<C>(受限视图)
├── Refinement.swift          Refinement<C> + ContentPatch<C>(纯数据)
├── RowSideCar.swift          GPU/CALayer 逃生门协议
├── TranscriptComponent.swift 主协议(HasHeight + 4 associated types + default impls)
├── ComponentRow.swift        framework 内部:PreparedItem<C> + ComponentRow (struct) + 
│                             ComponentCallbacks type-erased dispatch
└── README.md                 本文件
```

这些文件**独立编译通过**,但尚未被任何代码使用(`grep -r 'TranscriptComponent' macos/ccterm/Content/Chat/NativeTranscript/Controller/` 为空)。

---

## 4 关键决策的理由备忘

### 4.1 Row 从 class 降级为 struct

| 关心 | 答 |
|---|---|
| 性能? | struct inline 存储,cache locality 略升;vtable 换成 @Sendable 闭包 indirect call,等价 |
| CALayer / GPU 资源怎么办? | `SideCar: RowSideCar` 关联类型逃生门,per-row 持有作者定义的 class |
| UserBubble 的 `currentSelection` 字段怎么办? | 进 `State`(stateful component 把 selection 作为 row-local state 一部分) |

### 4.2 State 作为一等第三轴

`layout(content, theme, width, state)` 签名。width 和 state **都是** layout 的输入,不是老设计里"state 变触发 class 字段分叉"的隐性方式。

`relayouted(layout, state)` 快路径 opt-in:作者把 width-dependent 但 state-independent 的 intermediate(如 UserBubble 的 CT `textLayout`)存在 Layout 字段里,state 变时只重跑几何(跳过 CT)。返回 `nil` = 没有快路径,framework fall back 到 `layout(...)` full。

### 4.3 `Interaction` 是 enum 不是闭包

老 `InteractiveRow.hitRegions` 的 `perform: (TranscriptController) -> Void` 闭包把整个 controller 暴露给 row,副作用不可见。

新 `Interaction<C>` 是**意图枚举**:
- `.toggleState` — framework 自动 apply state + noteHeightOfRow + clearSelection + redraw
- `.copy` — framework 放剪贴板 + 反馈
- `.openURL` — framework 走 NSWorkspace
- `.custom(handler:)` — 逃生门。handler 拿 `RowContext<C>`(受限视图,**不含 controller**),真需要跨界副作用(开 sheet / 导航)通过应用层 ownership chain。

### 4.4 `Refinement` 是纯数据不是 row mutation

老 `RowRefinementWork.run()` 返回 `@MainActor () -> Void` applier,applier 直接 `row.apply(...)` mutate class 字段。

新 `Refinement<C>.run()` 返回 `ContentPatch<C>`(纯数据闭包),framework 自己把 new content 替回 row → 重跑 layout → reload row。Refinement 不持有 row 引用、不 mutate,`Sendable` 天然。

### 4.5 `StableId` 结构化

老 `AnyHashable` 约定(assistant 用 `"<uuid>-md-N"` 字符串,controller 靠 split-dash 反查 entryId)。

新 `struct StableId { entryId: UUID; locator: Locator }` 结构化。`Controller.entryId(fromRowStableId:)` 字符串解析可以删(迁移阶段)。

### 4.6 `C.Type` Sendable

让 `TranscriptComponent: Sendable` —— component 作为 enum/struct with static methods 天然无状态,Sendable 合理。`C.Type` 因而 Sendable,`@Sendable` 闭包安全 capture。

### 4.7 一个命名冲突

新 `SelectableSlot.ordering: SlotOrdering`(不叫 `Ordering`)是因为老 `Controller/TextSelectable.swift:14` 有 `struct Ordering`,同名冲突。老代码删除后可以 flatten rename。

---

## 5 接下来的迁移计划

按**独立可审 commit** 分步:

### Step 2:迁移 `PlaceholderComponent`(最简单,验证 pipeline)

- 建 `Components/Placeholder/PlaceholderComponent.swift` 实现 `TranscriptComponent`
- 写 `TranscriptComponentRegistry`(或直接 `TranscriptComponents.all`) 的注册表
- 让 `TranscriptRowBuilder` **并行**支持 "新协议路径(registry)" 和 "老路径(switch)",新老共存一次 pipeline
- 让 `TranscriptController` / `merge` / pipeline 接受异构 `[ComponentRow] ∪ [老 TranscriptRow class]` —— 这里最难,可能需要一个 adapter 让老 row 暂时假装是 ComponentRow
- **或者**:直接一次砍倒,不做并行,承受短暂 broken state

**建议**:直接砍倒。当前分支是 migration 分支,不需要中间点功能完整。

### Step 3:迁移 `UserBubbleComponent`(验证 Stateful)

- `State = Bool`(isExpanded)
- Layout 内存 `UserBubbleCT` intermediate,`relayouted` 只跑几何
- Interaction:chevron 点击 = `.toggleState(newState: !expanded)`
- Selectable:一个 slot 覆盖文字区

### Step 4:迁移 `AssistantMarkdownComponent`(最复杂)

- Content 大(MarkdownDocument + prebuilt segments)
- Selectable:多 slot(per segment,包括 table selection)
- Refinement:syntax highlight(per code block,`ContentPatch` 折 tokens 回 prebuilt)
- State 可能非 Void(若 per-segment selection 进 state)

### Step 5:删老代码

- `Rows/TranscriptRow.swift` 老 class
- `Rows/*Row.swift`(已经被 Components/ 替代)
- `Prepare/*PreparedItem.swift` 三个
- `Prepare/TranscriptPrepare.swift` 集中函数
- `Prepare/TranscriptRowBuilder.swift` 老 dispatch + cachedOrBuild 模板
- `Controller/TextSelectable.swift` 老协议 + `Ordering`
- `Rows/RowProtocols.swift`(`InteractiveRow` / `ExpandableRow`)
- `Rows/MarkdownRowPrebuilder.swift`(可能整合到 `AssistantMarkdownComponent`)
- `Refinements/RowRefinement.swift` 老协议

### Step 6:整理 `Core/`

- 如果 `SlotOrdering` 可以 rename 回 `Ordering` 就 rename
- `Controller.entryId(fromRowStableId:)` 字符串解析删,改用 `StableId.entryId` 直读
- `TranscriptController.rows: [ComponentRow]`

---

## 6 需要接力者留神的地方

### 6.1 一个 entry 被多 component 消费

`assistant entry` 里 text / tool_use / thinking block 将来归 **不同 component** 各挑各的。不要把 "一个 entry → 一个 component" 的旧假设搬进 builder —— 新 builder 是:

```
for each entry:
    for each component in registry:
        inputs += component.inputs(from: entry, entryIndex: i)
sort inputs by (entryIndex, blockIndex)
```

### 6.2 `C.Type` existential 的使用

`any TranscriptComponent.Type`(metatype existential)可以放进异构数组;但 `any TranscriptComponent`(instance existential)**不能直接用访问 associated types**。Swift 5.9 primary associated types 语法 `any TranscriptComponent<Content == X>` 解决部分问题,但 registry 层大概率还是要显式 type-erase —— 参考 `ComponentRow.swift` 里 `ComponentCallbacks.make<C>(for:)` 的做法。

### 6.3 为什么 `ComponentRow` 字段是 `any Sendable`,不是 `any TranscriptComponent.Input`?

Protocol 的 associated type 在 existential context 下无法用作字段类型约束(Swift 限制)。所以 framework 内部 row 存 `state: any Sendable`,在 callbacks 里 `as! C.State` 还原。force-cast 配对由 `make(for:)` 保证类型永远一致,不会失败。开销 ~ns 级,非热点。

### 6.4 `width × state` 共同影响 layout

老 UserBubble 里 `makeSize(width:)` 的 if-else 分叉(widthChanged vs stateChanged)是**实现细节**。新协议里:
- `layout(content, theme, width, state)` 是**唯一 full 入口**,width + state 都是输入
- `relayouted(layout, theme, state)` 是**快路径入口**,调用方保证 width 未变
- Framework 的 state-apply 路径先试 `relayouted` → nil 就 fall back 到 `layout(...)` 用当前 cached width 重跑

### 6.5 老 enum `TranscriptPrepareCache.Variant` 已经删

上一 commit(`99dd7d2`)已经把 `Variant` enum 换成 `Key = (contentHash: Int, tag: String)`,老 `*PreparedItem.cacheKey` 表达式用字面量 tag(`"User"` / `"Assistant"` / `"Placeholder"`)过渡。**迁移新 component 时这些字面量会被 `C.tag` 取代,无需额外处理**。

### 6.6 不要在协议阶段写 mock 单测

协议的正确性要由**真实 component 实现 + 集成**证明,不是靠 `MockComponent` / `StatefulMock` 之类的 mock。上一次反思已存 memory(`feedback_no_mock_tests_for_unimplemented_protocols.md`)。

---

## 7 编译验证

本 commit 编译通过:

```bash
make build
```

**没有新增测试**(协议骨架阶段不写测试,迁移阶段做真实集成测试)。

---

## 8 参考

- 新协议 doc-comment 里每个类型都说了"和老 X 对比"的段落,可以对应 `Rows/`、`Prepare/`、`Refinements/`、`Controller/TextSelectable.swift` 对读
- 性能/灵活性审计(不在本 doc,在上一轮对话记录):
  - 性能:无牺牲,stableId hash 和 cache locality 略升
  - 灵活性:无牺牲,自定义 CGContext 绘制 + CALayer 持有 + 复杂交互 + 多阶段 layout 都有一等通道或逃生门
  - 唯一显性收紧:component 不再直接 poke controller 全局 —— 这是健康的结构化约束,不是能力损失

---

*本文件由 `feat/sessionhandle2-migration` 分支于 2026-04-24 生成。接手后用 `git log --oneline Core/` 看演进,用 `git blame Core/*.swift` 看具体决策出处。*

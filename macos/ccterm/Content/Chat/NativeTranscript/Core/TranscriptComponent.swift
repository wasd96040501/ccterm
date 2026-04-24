import AgentSDK
import AppKit

// MARK: - HasHeight

/// Layout 对外必须暴露的最小接口 —— 框架累加 Phase 1 budget / 喂
/// `NSTableView.heightOfRow` 只读这个字段。宽度记录在 framework 侧
/// (`TranscriptRow.cachedWidth`),不强制 Layout 带,避免给作者加负担。
protocol HasHeight: Sendable {
    var cachedHeight: CGFloat { get }
}

// MARK: - IdentifiedInput

/// Component 从 entry 里挑出的一条源料,带全局 ordering。
///
/// 设计:component 是**block 渲染器**(见 `TranscriptComponent` doc)——一条
/// entry 被多个 component 各自扫一遍,每个 component 只挑自己关心的 block。
/// Builder 按 `(entryIndex, blockIndex)` 做全局 merge-sort,得到最终 row 列表。
/// Component 之间零协作。
struct IdentifiedInput<Input: Sendable>: Sendable {
    /// Diff / scroll anchor / cache 用。由 component 自己生成,建议格式:
    /// `"<entryId>-<locator>"`(locator 反映 entry 内 block 位置)。
    let stableId: AnyHashable

    /// 源 entry 在 entries 数组里的下标。Builder 传入。
    let entryIndex: Int

    /// 这条 input 对应的 block 在 entry 里的位置(同 entry 多条 input 时用)。
    /// 简单场景(user / placeholder 一个 entry 一条 input)传 0 即可。
    let blockIndex: Int

    let input: Input
}

// MARK: - TranscriptComponent

/// 一种 row type 的闭合定义。**这是 component 作者面对的唯一协议。**
///
/// ## 作者视角的 4 个维度
///
/// | 我要回答的问题 | 对应实现 |
/// |---|---|
/// | 我从哪儿来? | `inputs(from:entryIndex:)` |
/// | 内容长啥样?指纹怎么算? | `Content` + `prepare(_:theme:)` + `contentHash(_:theme:)` |
/// | 给我宽度,能算出什么 layout? | `Layout: HasHeight` + `layout(_:theme:width:)` |
/// | 怎么画、怎么响应点击? | `makeRow(...)` 返回 `TranscriptRow` 子类 |
///
/// 其他(cache key / PreparedItem wrapper / stableId 结构 / carry-over /
/// cache put-get / theme fingerprint 组合) 由框架派生 —— 作者看不到、
/// 也不能搞错。
///
/// ## 两种 Row 基类选择
///
/// - **`ComponentRow<Self>` 便利基类**:作者只 override `draw(in:bounds:)`,
///   `stableId` / `contentHash` / `makeSize` / `identifier` 全吃掉。
/// - **直接继承 `TranscriptRow`**:完全自己 handle,适合需要接 `CALayer`
///   独立动画、多阶段 layout(如 `UserBubbleRow` 的 CT+几何两阶段复用 CT
///   结果 toggle 只跑几何)、自定义 reuse identifier 等场景。协议对 Row
///   形态不做约束,`makeRow(...)` 返回什么都行。
///
/// ## Block 渲染器 vs entry 处理器
///
/// `inputs(from:)` 只挑自己关心的 —— 空 `[]` = 不归我管。**不排他**:
/// assistant entry 会被 `AssistantMarkdownComponent`(text blocks)、
/// `ToolBlockComponent`(tool_use blocks)、`ThinkingComponent`(thinking
/// blocks) 各自扫一遍,各自产 inputs。Builder 按 `(entryIndex, blockIndex)`
/// 合并。新加 assistant 子 block 类型 = 新建一个 component,不改别人。
///
/// ## 新增 component
///
/// 1. 新建文件 `Components/MyComponent.swift`:`enum MyComponent: TranscriptComponent`
/// 2. 在 `TranscriptComponents.all` 注册(下一步基础设施会加)
///
/// 不改 controller / cache / builder 主干代码。
protocol TranscriptComponent {
    /// 源料 —— 作者从 `MessageEntry` 里挑出自己关心的字段。
    /// 必须 `Sendable`,会跨 `Task.detached` 边界。
    associatedtype Input: Sendable

    /// Parse 结果,**宽度无关**。off-main 跑。框架按 `(tag, contentHash)`
    /// 存到 `TranscriptPrepareCache`。必须 `Sendable`。
    associatedtype Content: Sendable

    /// 宽度相关排版结果。off-main 跑。精确 width,不做 bucket —— 下游
    /// `row.cachedHeight` 与此 layout 的 `cachedHeight` 完全一致
    /// (Phase 1 budget 与实际 row 高度永不 drift)。
    associatedtype Layout: HasHeight

    // MARK: - Registration

    /// 组件唯一标签。用作 cache tag / row reuse identifier。
    /// 约定:类型名即可(`"UserBubble"`, `"AssistantMarkdown"`, etc.)。
    /// 同一 process 内必须独一无二。
    static var tag: String { get }

    // MARK: - Dispatch (off-main, nonisolated)

    /// 从一条 entry 挑出属于我的 inputs。空 = 不归我管。
    ///
    /// `entryIndex` 是 entry 在 entries 数组里的全局下标 —— 由 builder
    /// 传入,component 不维护。每条产出的 `IdentifiedInput.blockIndex`
    /// 由 component 自己选(通常是 block 在 `entry.content` 里的下标)。
    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>]

    // MARK: - Prepare (off-main, nonisolated)

    /// off-main parse。`Content` 进 cache、跨 Task 边界传。
    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content

    /// off-main 内容指纹。必须包含一切影响渲染的输入(input 字段 + 需要的
    /// theme 字段,典型的是 `theme.markdown.fingerprint`)。
    ///
    /// 同 `stableId` + 同 `contentHash` → 框架视为未变,row carry-over。
    /// 只有 `contentHash` 变 → 新 row 实例,cache 因 key 不同天然 miss。
    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int

    /// off-main layout。精确 width,结果 `cachedHeight` 与 row 挂载后的
    /// `row.cachedHeight` 必须一致。
    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat
    ) -> Layout

    // MARK: - Row factory (MainActor)

    /// 构造活 row。主线程。`layout` 可能为 `nil`(cache 里的 stripped
    /// 版本或未排版的旁路);此时调用方会在 `makeSize(width:)` 时触发
    /// 排版补齐。
    @MainActor
    static func makeRow(
        input: Input,
        content: Content,
        layout: Layout?,
        theme: TranscriptTheme,
        stableId: AnyHashable
    ) -> TranscriptRow
}

// MARK: - GenericPreparedItem

/// 泛型 `TranscriptPreparedItem` 实现 —— 吃掉今天 `UserPreparedItem` /
/// `AssistantPreparedItem` / `PlaceholderPreparedItem` 三个 struct 的全部
/// 模板代码(`withStableId` / `strippingLayout` / `cacheKey` / `makeRow` /
/// `cachedHeight`)。
///
/// **框架内部类型。component 作者看不到、不构造。** Builder 调
/// `GenericPreparedItem<C>(...)` 包装 component 产的 (input, content, layout)。
///
/// Highlight / refinement 不走 `TranscriptPreparedItem.applyingTokens(...)`
/// 的老通道 —— 新 component 的 async refinement 统一用 `RowRefinement` 协议
/// 在 row 侧声明 `pendingRefinements()`,走 `runPendingRowRefinements` 通道。
/// 协议上 `highlightRequests()` / `applyingTokens(...)` 有默认空实现,
/// `GenericPreparedItem` 不需要覆盖。
struct GenericPreparedItem<C: TranscriptComponent>: TranscriptPreparedItem, @unchecked Sendable {
    let stable: AnyHashable
    let input: C.Input
    let content: C.Content
    let contentHashValue: Int
    let layout: C.Layout?

    var stableId: AnyHashable { stable }
    var contentHash: Int { contentHashValue }
    var cachedHeight: CGFloat { layout?.cachedHeight ?? 0 }
    var cacheKey: TranscriptPrepareCache.Key {
        TranscriptPrepareCache.Key(contentHash: contentHashValue, tag: C.tag)
    }

    @MainActor
    func makeRow(theme: TranscriptTheme) -> TranscriptRow {
        C.makeRow(
            input: input, content: content, layout: layout,
            theme: theme, stableId: stable)
    }

    func withStableId(_ newId: AnyHashable) -> any TranscriptPreparedItem {
        Self(
            stable: newId, input: input, content: content,
            contentHashValue: contentHashValue, layout: layout)
    }

    func strippingLayout() -> any TranscriptPreparedItem {
        Self(
            stable: stable, input: input, content: content,
            contentHashValue: contentHashValue, layout: nil)
    }
}

// MARK: - ComponentRow (optional convenience base)

/// Component 的 Row 便利基类 —— **可选**继承,只写 `draw(in:bounds:)` 即可。
///
/// 吃掉的模板:
/// - `stableId` / `contentHash` / `identifier` 对接协议;
/// - `makeSize(width:)` 的 width-dispatch(width 没变直接 return,变了调
///   `C.layout(...)` 写回 `cachedHeight`/`cachedWidth`);
/// - `layout` 字段存储。
///
/// **不选这个基类的场景**(直接继承 `TranscriptRow`):
/// - 需要接 `CALayer` 做独立动画 / GPU 加速层(row view 侧控制);
/// - 状态字段复杂到单次 `applyLayout` 语义不够 —— 如 `UserBubbleRow` 的
///   CT + 几何两阶段(toggle 只跑几何,复用 CT 结果);
/// - 自定义 `viewClass()` / `identifier` reuse 策略;
/// - 需要精确控制 `cachedWidth` 写入时机(比如宽度没变但 expansion 变了
///   要重算)。
///
/// 这些场景在 `Component.makeRow(...)` 里直接构造自己的 `TranscriptRow`
/// 子类即可 —— 协议对 Row 形态不做约束。
@MainActor
class ComponentRow<C: TranscriptComponent>: TranscriptRow {
    let input: C.Input
    let content: C.Content
    let componentTheme: TranscriptTheme
    private let stable: AnyHashable

    /// 最近一次排版结果。初始可能为 nil(cache 里 stripped 的 item +
    /// 还没 makeSize 过);一旦 `makeSize(width:)` 跑过就非 nil。
    private(set) var layout: C.Layout?

    init(
        input: C.Input,
        content: C.Content,
        layout: C.Layout?,
        theme: TranscriptTheme,
        stableId: AnyHashable
    ) {
        self.input = input
        self.content = content
        self.componentTheme = theme
        self.stable = stableId
        super.init()
        if let layout {
            self.layout = layout
            self.cachedHeight = layout.cachedHeight
            // cachedWidth 不写 —— 没传进来就是"这份 layout 的宽度未知",
            // 下次 makeSize 任意 width 都会重算。来的若是 cache hit
            // 配上精确 width 跑出来的 layout,调用方可以额外调
            // `setCachedWidth(_:)` 避免多余重算(暂未暴露,按需加)。
        }
    }

    nonisolated deinit {}

    override var stableId: AnyHashable { stable }
    override var contentHash: Int { C.contentHash(input, theme: componentTheme) }
    override var identifier: String { C.tag }

    override func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        let newLayout = C.layout(content, theme: componentTheme, width: width)
        layout = newLayout
        cachedHeight = newLayout.cachedHeight
        cachedWidth = width
    }

    /// 基类空实现。子类按需 override。
    override func draw(in ctx: CGContext, bounds: CGRect) {}
}

// MARK: - StatefulComponent (opt-in, third axis)

/// 可选扩展协议 —— 声明组件有 **row-local state**(isExpanded / isHover /
/// selection anchor / etc.)以及 "width 不变、只按 state 重排" 的快路径。
///
/// ## 为什么需要第三轴
///
/// 主协议 `TranscriptComponent` 只谈 `content × width → Layout`。但 UserBubble
/// 这类组件还有 row-local state(isExpanded):state 变时 **CT 排版(贵,
/// CoreText 换行 + measuredWidth) 无需重跑,只拼几何**。硬塞进 `makeSize(width:)`
/// 会让协议主体为所有 component 污染一个 state 概念(而绝大多数 component
/// 根本没有)。
///
/// 解法:state 作为 opt-in 的第三轴,通过这个协议接入。Stateless component
/// 看不到 `State` 关联类型。
///
/// ## 作者要写什么
///
/// - `State` 类型(Bool / struct / enum,随便)
/// - `initialState(for:)`:新 row 构造时默认值
/// - 4 参 `layout(content, theme, width, state:)`:full layout 吃 state
/// - `relayouted(layout, theme, state:)`:**快路径**,复用 layout 里的
///   width-dependent intermediate,只按 state 拼几何
///
/// ## 契约
///
/// - `relayouted(...)` 的调用方**保证 width 未变**。若 width 也变了,必须
///   走 `makeSize(width:)` 完整路径(它会内部吃当前 state 重排)。
/// - 作者把 "width-dependent 但 state-independent" 的中间产物(CT textLayout
///   等)存在 `Layout` 字段里,`relayouted` 直接读。
///
/// ## Row 侧入口
///
/// `ComponentRow<C>` 对 `C: StatefulComponent` 条件扩展出 `apply(state:)`
/// 方法。hit handler / controller state-sync pass 调用它完成快路径切换。
/// Stateless component 的 row 上这个方法根本不存在。
protocol StatefulComponent: TranscriptComponent {
    associatedtype State: Sendable

    /// Row 刚构造时的默认 state。挂载后由 `apply(state:)` sync 成真实状态
    /// (和 `ExpandableRow.applyExpansion` 同义)。
    nonisolated static func initialState(for input: Input) -> State

    /// Full layout,带 state。主协议 3 参版本由作者显式委托到这个:
    /// ```swift
    /// static func layout(_ c, theme, width) -> Layout {
    ///     layout(c, theme: theme, width: width, state: initialStateDefault)
    /// }
    /// ```
    /// 不走 default impl 委托,因为 3 参签名里没有 input —— 给不了
    /// `initialState(for:)` 它需要的参数。由作者 4 行桥接,代价可接受。
    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout

    /// **快路径**。调用方保证 width 未变 —— 不重跑任何 width-dependent 计算。
    nonisolated static func relayouted(
        _ layout: Layout,
        theme: TranscriptTheme,
        state: State
    ) -> Layout
}

extension ComponentRow where C: StatefulComponent {
    /// 按 state 重排,复用当前 layout 里的 width-dependent intermediate。
    /// **前置条件:width 未变**。layout 为 nil(还没 full layout 过)时 no-op
    /// —— 等 `makeSize(width:)` 首次跑出 layout 后再调用。
    func apply(state: C.State) {
        guard let cur = layout else { return }
        let newLayout = C.relayouted(cur, theme: componentTheme, state: state)
        self.layout = newLayout
        cachedHeight = newLayout.cachedHeight
        // cachedWidth 不动 —— 表示"上次 full layout 的宽度仍有效"
    }
}

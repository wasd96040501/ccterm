import AgentSDK
import AppKit

// MARK: - HasHeight

/// Layout 的最小对外接口 —— framework 喂 `NSTableView.heightOfRow` / 累加
/// Phase 1 budget 只读这个字段。Layout 的 width 信息由 framework 在
/// `ComponentRow.cachedSize` 里持有,不强制 Layout 带。
protocol HasHeight: Sendable {
    var cachedHeight: CGFloat { get }
}

// MARK: - TranscriptComponent

/// 一种 row type 的闭合定义。**这是 component 作者面对的唯一协议。**
///
/// ## 4 个正交轴 + 1 个 row factory
///
/// | 我要回答的问题 | 对应类型 / 方法 |
/// |---|---|
/// | 我从哪儿来? | `Input` + `inputs(from:entryIndex:)` |
/// | 内容长啥样?指纹怎么算? | `Content` + `prepare(_:theme:)` + `contentHash(_:theme:)` |
/// | 给我宽度 + state,能算什么 layout? | `Layout: HasHeight` + `layout(_:theme:width:state:)` |
/// | Row-local 状态是什么? | `State` + `initialState(for:)` (默认 `Void`,即无 state) |
/// | 怎么画? | `render(_:state:theme:in:bounds:)` |
/// | 其他(交互 / 选中 / 异步补齐 / SideCar) | 可选 override,默认空 |
///
/// ## Block 渲染器 vs entry 处理器
///
/// `inputs(from:)` 只挑自己关心的 —— 返回 `[]` = 不归我管。**不排他**:
/// assistant entry 会被 `AssistantMarkdownComponent`(text blocks)、
/// `ToolBlockComponent`(tool_use blocks)、`ThinkingComponent` 各扫一遍,各产 inputs。
/// Builder 按 `(entryIndex, blockIndex)` merge。新加 block 类型 = 新建 component,
/// 不改别人。
///
/// ## 作者不需要看的东西
///
/// - `PreparedItem<C>` / `ComponentRow` / `ComponentCallbacks`:framework
///   内部的 off-main / on-main 数据载体,`Components/` 的作者零感知
/// - `TranscriptPrepareCache.Key`:按 `C.tag` 自动生成
/// - `NSTableView` / `TranscriptRowView` 挂载细节:framework 通过 callbacks
///   反查 `render` / `interactions` / `selectables`
///
/// ## 新增 component
///
/// 1. 新建 `Components/MyComponent.swift`:`enum MyComponent: TranscriptComponent`
/// 2. 在 `TranscriptComponentRegistry` 注册
///
/// 不改 controller / cache / builder 主干代码。
protocol TranscriptComponent: Sendable {
    // MARK: - 4 个正交轴

    /// 源料。作者从 `MessageEntry` 挑出自己关心的字段。跨 `Task.detached`
    /// 边界,必须 `Sendable`。
    associatedtype Input: Sendable

    /// Parse 结果,宽度无关。off-main 跑。framework 按 `(tag, contentHash)`
    /// 存 cache。
    associatedtype Content: Sendable

    /// 宽度 + state 相关的排版结果。精确 width,不做 bucket —— row 的
    /// `cachedSize.height` 与此 layout 的 `cachedHeight` 完全一致。
    associatedtype Layout: HasHeight

    /// Row-local state(isExpanded / hover / selection range / etc.)。
    /// 默认 `Void` —— stateless component 完全不感知这个轴。
    /// Stateful component 把 State 定义成任意 `Sendable` 值类型。
    associatedtype State: Sendable = Void

    /// 逃生门:row 需要持有 `NSObject` 资源时关联。默认 `EmptyRowSideCar`
    /// (无字段、无 hook)。
    associatedtype SideCar: RowSideCar = EmptyRowSideCar

    // MARK: - Registration

    /// 组件唯一标签。用作 cache key + row reuse identifier。**约定类型名**。
    /// 同一 process 内必须独一无二。
    static var tag: String { get }

    // MARK: - Dispatch (nonisolated)

    /// 从一条 entry 挑出属于我的 inputs。空 = 不归我管。
    ///
    /// `entryIndex` + 每个 `IdentifiedInput.blockIndex` 用于 builder 把多 component
    /// 的 inputs 做全局 merge-sort。
    nonisolated static func inputs(
        from entry: MessageEntry,
        entryIndex: Int
    ) -> [IdentifiedInput<Input>]

    // MARK: - Prepare (nonisolated, off-main)

    /// Content parse。Sendable,跨 Task 边界传、进 cache。
    nonisolated static func prepare(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Content

    /// Content-only 指纹(含 theme.fingerprint)。同 stableId 下同 contentHash
    /// → framework 视为未变,row carry-over。
    nonisolated static func contentHash(
        _ input: Input,
        theme: TranscriptTheme
    ) -> Int

    /// Row 构造时的默认 state。进入 controller 后通常紧跟一次
    /// `context.applyState(...)` sync 实际状态(对标老 `applyExpansion`)。
    nonisolated static func initialState(for input: Input) -> State

    // MARK: - Layout (nonisolated, off-main)

    /// Full layout。State 参与 —— state 影响排版时,作者按 state 分支算
    /// (UserBubble 的 bubbleHeight 依赖 isExpanded);state 不影响时(Assistant /
    /// Placeholder),作者忽略 state 参数。
    nonisolated static func layout(
        _ content: Content,
        theme: TranscriptTheme,
        width: CGFloat,
        state: State
    ) -> Layout

    /// 可选快路径:width 未变、只 state 变。复用 Layout 里的 width-dependent
    /// intermediate(作者在 Layout 字段里存 CT textLayout 等),只重算 state-dependent
    /// 部分(几何)。
    ///
    /// 返回 `nil` = 没有快路径(framework fall back 到 full `layout(..., state:)`
    /// 重算,仍正确,只是重跑 CT)。
    ///
    /// UserBubble 典型实现:Layout 里存 CT 结果,`relayouted` 只跑
    /// `userBubbleGeometry(ct: ..., isExpanded:)`。
    nonisolated static func relayouted(
        _ layout: Layout,
        theme: TranscriptTheme,
        state: State
    ) -> Layout?

    // MARK: - Render + declarative metadata (MainActor)

    /// 核心绘制。`bounds` 是 row 的 bounds(flipped:y 向下)。
    @MainActor
    static func render(
        _ layout: Layout,
        state: State,
        theme: TranscriptTheme,
        in ctx: CGContext,
        bounds: CGRect
    )

    /// 交互声明。默认空,按需 override。
    @MainActor
    static func interactions(
        _ layout: Layout,
        state: State
    ) -> [Interaction<Self>]

    /// 文本可选中区域声明。默认空。
    @MainActor
    static func selectables(
        _ layout: Layout,
        state: State
    ) -> [SelectableSlot]

    /// 把某个 slot 的 selection range 折进 state。默认返回原 state(stateless /
    /// 不支持 selection 的 component)。支持 selection 的 component 按 `selectionKey`
    /// dispatch 到自己的 state 字段。
    ///
    /// Range 语义:`location == NSNotFound || length == 0` 代表"清空这个 slot 的
    /// selection";其他值代表激活的 range。
    @MainActor
    static func applySelection(
        key: AnyHashable,
        range: NSRange,
        to state: State
    ) -> State

    /// 清空全部 selection。默认返回原 state。
    @MainActor
    static func clearingSelection(_ state: State) -> State

    /// 根据 selection state + layout 导出当前可复制文本 —— Cmd-C 按
    /// (rowIndex, slot.ordering) 升序拼接时用。默认空数组。
    ///
    /// 每条返回的 fragment 代表一个 slot 的选中 substring;framework 在跨 row 拼接
    /// 时把多 fragment 用 `\n` 间隔(同 row)或 `\n\n` 间隔(跨 row)。
    @MainActor
    static func selectedFragments(
        _ layout: Layout,
        state: State
    ) -> [CopyFragment]

    /// 异步补齐活儿声明(syntax highlight / image fetch / lsp diagnostics)。
    /// 默认空。`context` 提供 framework 注入的共享资源(theme + engine)。
    nonisolated static func refinements(
        _ content: Content,
        context: RefinementContext
    ) -> [Refinement<Self>]

    // MARK: - SideCar factory (MainActor)

    /// 生成 per-row SideCar 实例。默认返回 `EmptyRowSideCar`(对应 SideCar
    /// = EmptyRowSideCar 的 component,通过约束扩展自动提供)。
    @MainActor
    static func makeSideCar(for content: Content) -> SideCar
}

// MARK: - Default implementations

extension TranscriptComponent where State == Void {
    /// Stateless component 不需要写 initialState。
    nonisolated static func initialState(for input: Input) -> State { () }
}

extension TranscriptComponent where SideCar == EmptyRowSideCar {
    /// SideCar == EmptyRowSideCar 时 framework 自动造实例。
    @MainActor
    static func makeSideCar(for content: Content) -> SideCar { EmptyRowSideCar() }
}

extension TranscriptComponent {
    /// 默认无快路径。State 变更触发 full `layout(..., state:)` 重算。
    /// 只有想跳过 width-dependent 重算(CT / 换行)的 component 才 override。
    nonisolated static func relayouted(
        _ layout: Layout,
        theme: TranscriptTheme,
        state: State
    ) -> Layout? { nil }

    /// 默认无交互。
    @MainActor
    static func interactions(
        _ layout: Layout,
        state: State
    ) -> [Interaction<Self>] { [] }

    /// 默认无选中。
    @MainActor
    static func selectables(
        _ layout: Layout,
        state: State
    ) -> [SelectableSlot] { [] }

    /// 默认不 merge,保持原 state。
    @MainActor
    static func applySelection(
        key: AnyHashable,
        range: NSRange,
        to state: State
    ) -> State { state }

    /// 默认无 selection 要清。
    @MainActor
    static func clearingSelection(_ state: State) -> State { state }

    /// 默认无可复制 fragment(stateless / 不支持 selection)。
    @MainActor
    static func selectedFragments(
        _ layout: Layout,
        state: State
    ) -> [CopyFragment] { [] }

    /// 默认无异步补齐。
    nonisolated static func refinements(
        _ content: Content,
        context: RefinementContext
    ) -> [Refinement<Self>] { [] }
}

/// Cmd-C 时 component 产出的一段 copy 文本 + 它在 row 内的 ordering。
/// framework 按 `(rowIndex, ordering)` 做最终拼接。
struct CopyFragment: Sendable {
    let ordering: SlotOrdering
    let text: String
}

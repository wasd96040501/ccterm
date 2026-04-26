import AppKit

// MARK: - PreparedItem (off-main, Sendable)

/// 泛型 off-main row 载体 —— 作者的 `C.Input` / `C.Content` / `C.Layout` /
/// `C.State` 全部按具体类型持有,Sendable 跨 `Task.detached` 边界。
///
/// Framework 内部类型。作者通过实现 `TranscriptComponent` 间接产生它(builder
/// 把 `C.inputs(...)` → `C.prepare(...)` → `C.layout(...)` 打包)。
///
/// 吃掉今天 `UserPreparedItem` / `AssistantPreparedItem` / `PlaceholderPreparedItem`
/// 三个 struct 的模板代码(`withStableId` / `strippingLayout` / `cacheKey` /
/// `makeRow`)。
struct PreparedItem<C: TranscriptComponent>: Sendable {
    let stableId: StableId
    let input: C.Input
    let content: C.Content
    let contentHash: Int
    let state: C.State

    /// `nil` 表示"在 cache 里(stripped)或还没 layout"。挂载前必须先 layout。
    let layout: C.Layout?

    var cachedHeight: CGFloat { layout?.cachedHeight ?? 0 }

    var cacheKey: TranscriptPrepareCache.Key {
        TranscriptPrepareCache.Key(contentHash: contentHash, tag: C.tag)
    }

    func withStableId(_ newId: StableId) -> Self {
        Self(
            stableId: newId, input: input, content: content,
            contentHash: contentHash, state: state, layout: layout)
    }

    func strippingLayout() -> Self {
        Self(
            stableId: stableId, input: input, content: content,
            contentHash: contentHash, state: state, layout: nil)
    }

    func withLayout(_ newLayout: C.Layout) -> Self {
        Self(
            stableId: stableId, input: input, content: content,
            contentHash: contentHash, state: state, layout: newLayout)
    }

    /// MainActor 边界 —— type-erase 到 framework 内部 `ComponentRow`。
    /// Precondition:`layout != nil`(caller 先 `C.layout(...)` 或 cache 命中
    /// 后 `withLayout(...)` 补齐)。
    ///
    /// `cachedSize.width` 由 caller 提供 —— builder 知道当前 layout 跑的 width。
    @MainActor
    func makeRow(theme: TranscriptTheme, layoutWidth: CGFloat) -> ComponentRow {
        precondition(layout != nil,
            "PreparedItem<\(C.tag)>.makeRow: layout 必须在主线程挂载前就算好")
        let sideCar = C.makeSideCar(for: content)
        return ComponentRow(
            stableId: stableId,
            identifier: C.tag,
            contentHash: contentHash,
            cachedSize: CGSize(width: layoutWidth, height: layout!.cachedHeight),
            state: state,
            content: content,
            layout: layout!,
            sideCar: sideCar,
            callbacks: .make(for: C.self))
    }
}

// MARK: - ComponentRow (@MainActor, type-erased)

/// Framework 内部 row 值载体。`TranscriptController.rows: [ComponentRow]`。
///
/// **作者不构造、不引用此类型。** 它是 `PreparedItem<C>` 过了 @MainActor 边界
/// 的 type-erased 形态 —— 放进异构 `[ComponentRow]` 数组,framework 按
/// `callbacks` 分派到具体 component 的 static methods。
///
/// ## 和老 `class TranscriptRow` 对比
///
/// | 方面 | 老 | 新 |
/// |---|---|---|
/// | 类型 | class,作者继承 | struct,作者不见 |
/// | 绘制 | `row.draw(...)` vtable | `callbacks.render(...)` 闭包 |
/// | State mutation | class 字段 `isExpanded` 等 | `row.state: any Sendable` 字段,framework replace 整值 |
/// | `noteHeightOfRow` 反向调用 | `weak var table` back-ref | Framework 持有 row 所有权,通过 index 做 |
/// | Selection/Interaction 协议 | `InteractiveRow` / `TextSelectable` adopt | `callbacks.interactions` / `callbacks.selectables` 声明式 |
@MainActor
struct ComponentRow {
    let stableId: StableId
    let identifier: String           // = C.tag,NSTableView reuse 用
    let contentHash: Int

    /// (width, height)。framework 喂 `heightOfRow` / 做 Phase 1 budget 累加。
    var cachedSize: CGSize

    /// Type-erased `C.State`。`apply(state:)` 通过 callbacks cast 后替换。
    var state: any Sendable

    /// Type-erased `C.Content`。refinement apply 后 framework 用新 content
    /// 重跑 layout 替换。
    var content: any Sendable

    /// Type-erased `C.Layout`。`makeSize(width:)` 或 `apply(state:)` 后替换。
    var layout: any HasHeight

    /// Per-row 持有的 SideCar(CALayer / GPU 资源)。stableId 不变则 carry-over。
    let sideCar: any RowSideCar

    /// Type-erased dispatch bundle —— `ComponentCallbacks.make(for: C.self)`
    /// 一次性 curry 出所有 static method 调用,绑定在 row 的生命周期上。
    let callbacks: ComponentCallbacks

    var cachedHeight: CGFloat { cachedSize.height }
    var cachedWidth: CGFloat { cachedSize.width }
}

// MARK: - ComponentCallbacks (type-erased dispatch)

/// Type-erased 调度束。框架层操作 `ComponentRow` 都走这个 —— 不需要
/// `as? C.Type` / 泛型参数。
///
/// 每个 callback 内部做一次 `as!` force-cast(从 `any Sendable` 还原到具体
/// `C.Input` / `C.Content` / `C.Layout` / `C.State`),配对由 `make(for:)`
/// 保证,类型永远一致,force-cast 不会失败(运行时 ~ns 级开销,非热点)。
///
/// `TranscriptComponent: Sendable` 让 `C.Type` 自身 Sendable,因而 @Sendable
/// 闭包可以安全 capture 它。MainActor 闭包(render/interactions/selectables)
/// 额外标 `@MainActor @Sendable` 保留隔离语义。
struct ComponentCallbacks: Sendable {
    /// `C.tag` —— row 的 identifier / cache key tag。
    let tag: String

    /// `C.render(layout, state:, theme:, in ctx:, bounds:)`。
    let render: @MainActor @Sendable (_ row: ComponentRow, _ ctx: CGContext,
                                      _ bounds: CGRect, _ theme: TranscriptTheme) -> Void

    /// `C.interactions(layout, state:)` 的 type-erased 产物。
    let interactions: @MainActor @Sendable (_ row: ComponentRow) -> [AnyInteraction]

    /// `C.selectables(layout, state:)`。
    let selectables: @MainActor @Sendable (_ row: ComponentRow) -> [SelectableSlot]

    /// `C.applySelection(key:, range:, to:)` —— framework 拿 slot 的 key + range,
    /// 请 component 把新 selection 折进 state。返回新 state(type-erased)。
    let applySelection: @MainActor @Sendable (
        _ currentState: any Sendable, _ key: AnyHashable, _ range: NSRange
    ) -> any Sendable

    /// `C.clearingSelection(state:)` —— 清空全部 selection。
    let clearingSelection: @MainActor @Sendable (_ currentState: any Sendable) -> any Sendable

    /// `C.selectedFragments(layout, state:)` —— 当前 state 下所有 slot 的选中文本。
    let selectedFragments: @MainActor @Sendable (_ row: ComponentRow) -> [CopyFragment]

    /// Off-main 快路径 —— `C.relayouted(layout, theme:, state:)`。
    /// `nil` 表示 component 没实现 fast path,framework 走 `layoutFull`。
    let relayouted: @Sendable (
        _ layout: any HasHeight,
        _ state: any Sendable,
        _ theme: TranscriptTheme
    ) -> (any HasHeight)?

    /// Off-main full layout —— `C.layout(content, theme:, width:, state:)`。
    let layoutFull: @Sendable (
        _ content: any Sendable,
        _ state: any Sendable,
        _ theme: TranscriptTheme,
        _ width: CGFloat
    ) -> any HasHeight

    /// Off-main content hash —— 对 Input 算指纹,不含 state。
    let contentHash: @Sendable (
        _ input: any Sendable,
        _ theme: TranscriptTheme
    ) -> Int

    /// Off-main default initial state —— 给 builder 构造初始 state 用。
    let initialState: @Sendable (_ input: any Sendable) -> any Sendable

    /// Off-main refinement 声明。`context` 由 framework 在调用前构造好。
    let refinements: @Sendable (
        _ content: any Sendable,
        _ context: RefinementContext
    ) -> [AnyRefinement]

    // MARK: - Factory

    /// 为某个具体 `C` 生成 callbacks 束。所有闭包内部 `as!` 从 `any Sendable`
    /// 还原到 `C.X`,然后调 `C` 的 static method。
    static func make<C: TranscriptComponent>(for _: C.Type) -> ComponentCallbacks {
        ComponentCallbacks(
            tag: C.tag,
            render: { @MainActor @Sendable row, ctx, bounds, theme in
                let layout = row.layout as! C.Layout
                let state = row.state as! C.State
                let sideCar = row.sideCar as! C.SideCar
                C.render(layout, state: state, theme: theme, sideCar: sideCar, in: ctx, bounds: bounds)
            },
            interactions: { @MainActor @Sendable row in
                let layout = row.layout as! C.Layout
                let state = row.state as! C.State
                return C.interactions(layout, state: state).map(AnyInteraction.erase)
            },
            selectables: { @MainActor @Sendable row in
                let layout = row.layout as! C.Layout
                let state = row.state as! C.State
                return C.selectables(layout, state: state)
            },
            applySelection: { @MainActor @Sendable state, key, range in
                C.applySelection(key: key, range: range, to: state as! C.State)
            },
            clearingSelection: { @MainActor @Sendable state in
                C.clearingSelection(state as! C.State)
            },
            selectedFragments: { @MainActor @Sendable row in
                let layout = row.layout as! C.Layout
                let state = row.state as! C.State
                return C.selectedFragments(layout, state: state)
            },
            relayouted: { @Sendable layout, state, theme in
                C.relayouted(layout as! C.Layout, theme: theme, state: state as! C.State)
            },
            layoutFull: { @Sendable content, state, theme, width in
                C.layout(content as! C.Content, theme: theme, width: width, state: state as! C.State)
            },
            contentHash: { @Sendable input, theme in
                C.contentHash(input as! C.Input, theme: theme)
            },
            initialState: { @Sendable input in
                C.initialState(for: input as! C.Input)
            },
            refinements: { @Sendable content, ctx in
                C.refinements(content as! C.Content, context: ctx).map(AnyRefinement.erase)
            }
        )
    }
}

// MARK: - Type-erased Interaction / Refinement

/// `Interaction<C>` 的 type-erased 包装 —— framework 层持有异构 interaction
/// 数组用。具体 handler 已在 `erase(_:)` 时通过 closure capture 保住了 `C`
/// 的具体类型,执行时类型安全。
struct AnyInteraction {
    let rect: CGRect
    let cursor: NSCursor
    let kind: Kind

    enum Kind {
        /// toggleState + custom 都走 "framework 调一个闭包" 的路径。
        /// 闭包内部已经 capture 了 new state / handler。
        case invoke(@MainActor @Sendable (AnyRowContext) -> Void)
        /// copy 的 payload —— framework 自己统一走剪贴板 + 反馈。
        case copy(text: String)
        /// openURL 的 payload —— framework 自己 NSWorkspace open。
        case openURL(URL)
        /// Hover enter/exit。framework 跟踪"当前悬停的 (rowIdx, rect)",
        /// 进时调 `onEnter`,出时调 `onExit`,都拿 `AnyRowContext`。
        case hover(
            onEnter: @MainActor @Sendable (AnyRowContext) -> Void,
            onExit: @MainActor @Sendable (AnyRowContext) -> Void)
    }

    static func erase<C: TranscriptComponent>(_ i: Interaction<C>) -> AnyInteraction {
        switch i {
        case let .toggleState(rect, newState, cursor):
            return AnyInteraction(
                rect: rect, cursor: cursor,
                kind: .invoke { ctx in
                    // 从 AnyRowContext 还原 RowContext<C>,调 applyState
                    ctx.applyState(newState)
                })
        case let .copy(rect, text, cursor):
            return AnyInteraction(rect: rect, cursor: cursor, kind: .copy(text: text))
        case let .openURL(rect, url, cursor):
            return AnyInteraction(rect: rect, cursor: cursor, kind: .openURL(url))
        case let .custom(rect, cursor, handler):
            return AnyInteraction(
                rect: rect, cursor: cursor,
                kind: .invoke { ctx in
                    handler(ctx.specialize(to: C.self))
                })
        case let .hover(rect, cursor, onEnter, onExit):
            return AnyInteraction(
                rect: rect, cursor: cursor,
                kind: .hover(
                    onEnter: { ctx in onEnter(ctx.specialize(to: C.self)) },
                    onExit:  { ctx in onExit(ctx.specialize(to: C.self))  }))
        }
    }
}

/// `RowContext<C>` 的 type-erased 形态。framework 持有这个,在调 handler /
/// invoke 时 `specialize(to: C.self)` 还原泛型。
@MainActor
struct AnyRowContext {
    let stableId: StableId
    let cachedWidth: CGFloat
    let theme: TranscriptTheme
    let currentStateErased: () -> any Sendable
    /// `(state, animated)` —— 第二参数 = NSTableView 是否要 animate row height
    /// 变更。caller 把整段动画包在 `NSAnimationContext.runAnimationGroup` 里时
    /// 传 `true`。
    let applyStateErased: (any Sendable, Bool) -> Void
    let noteHeightOfRow: () -> Void
    let redraw: () -> Void
    let clearSelection: () -> Void
    let sideCarErased: () -> any RowSideCar

    func applyState<T: Sendable>(_ state: T, animated: Bool = false) {
        applyStateErased(state, animated)
    }

    func specialize<C: TranscriptComponent>(to _: C.Type) -> RowContext<C> {
        RowContext<C>(
            stableId: stableId,
            cachedWidth: cachedWidth,
            theme: theme,
            currentState: { currentStateErased() as! C.State },
            _applyState: { newState, animated in applyStateErased(newState, animated) },
            noteHeightOfRow: noteHeightOfRow,
            redraw: redraw,
            clearSelection: clearSelection,
            sideCar: { sideCarErased() as! C.SideCar }
        )
    }
}

/// `Refinement<C>` 的 type-erased 形态。framework 调 `run()` 拿 patch,再
/// 按 component 类型回填 content。
struct AnyRefinement: Sendable {
    let run: @Sendable () async -> AnyContentPatch

    static func erase<C: TranscriptComponent>(_ r: Refinement<C>) -> AnyRefinement {
        AnyRefinement(run: {
            let patch = await r.run()
            return AnyContentPatch(applyErased: { oldContent in
                patch.apply(oldContent as! C.Content)
            })
        })
    }
}

struct AnyContentPatch: Sendable {
    let applyErased: @Sendable (any Sendable) -> any Sendable
}

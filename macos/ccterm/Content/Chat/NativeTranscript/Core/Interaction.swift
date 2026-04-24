import AppKit

/// Component 声明自己的**交互区域**。framework 读这些 Interaction → 按 intent
/// 做标准化副作用(apply state / copy / open URL / 自定义 handler)。
///
/// ## 和老 `InteractiveRow.hitRegions` 对比
///
/// - 老设计:每 region 带 `perform: @MainActor (TranscriptController) -> Void`
///   闭包,row 在闭包里任意 poke controller 全局状态(`expandedUserBubbles` /
///   `selectionController.clear()` / `noteHeightOfRow` / `redrawAllVisibleRows`)
///   —— 副作用不可见、controller API 被迫 expose 全部
/// - 新设计:`Interaction` 是**意图 enum**,framework 解释意图做标准副作用;
///   `.custom` 逃生门的 handler 拿 **`RowContext`**(受限视图),**不能** 访问
///   controller 全局
///
/// 结果:
/// 1. framework 看得见组件在做什么(便于日志、撤销、测试)
/// 2. 组件不能越权(state 变更 / row reload / selection clear 都是框架标准动作)
/// 3. 真的需要越界副作用(开 sheet / 跳 session / toast) — 通过 `.custom` 的
///    handler,handler 见不到 controller,只见到 RowContext + 上层应用层
///    (作者的 ownership chain)
enum Interaction<C: TranscriptComponent>: Sendable {
    /// 点击命中区域后,row 切到新 state。framework 自动:
    /// `apply(state: newState)` → `noteHeightOfRow` → `clearSelection`
    /// (若 state 影响 selection 有效性)→ 局部 redraw。
    ///
    /// UserBubble 的 chevron toggle 就是这个 case(`C.State = Bool`,
    /// `newState = !currentExpanded`)。
    case toggleState(rect: CGRect, newState: C.State, cursor: NSCursor)

    /// 点击 → 把 `text` 放进剪贴板 + 临时视觉反馈(framework 统一做 checkmark
    /// 动画)。code block 顶部的 copy 按钮典型 case。
    case copy(rect: CGRect, text: String, cursor: NSCursor)

    /// 点击 → 系统打开 URL。inline link 命中典型 case。
    case openURL(rect: CGRect, url: URL, cursor: NSCursor)

    /// 逃生门。handler 拿 `RowContext<C>`(**不是 controller**):能 apply
    /// state / noteHeightOfRow / redraw / sideCar 访问,但**看不见**其他 row、
    /// 看不见 controller 全局 selection / expansion set。
    ///
    /// 跨界副作用(打开 sheet / 导航)通过应用层 ownership chain 完成,
    /// framework 不承担。
    case custom(
        rect: CGRect,
        cursor: NSCursor,
        handler: @MainActor @Sendable (RowContext<C>) -> Void)
}

/// 受限视图 —— 传给 `Interaction.custom` 的 handler 和 `Refinement` 的 applier。
/// 只暴露 **row 自己能做的事**,不暴露 controller 全局状态。
///
/// 作者想让 row "告诉自己一些事"(state 变了、高度要刷、需要重绘自己、
/// sideCar 要做点动画)都走这个。
@MainActor
struct RowContext<C: TranscriptComponent> {
    let stableId: StableId
    let cachedWidth: CGFloat
    let theme: TranscriptTheme

    /// 读取本 row 的当前 state —— `applyState` 的并发安全 `get` 对应。
    /// handler 可以用 `var s = ctx.currentState(); s.x = ...; ctx.applyState(s)`
    /// 做 in-place 字段更新而不丢其他字段。
    let currentState: () -> C.State

    /// 把新 state apply 到自己。走 `StatefulComponent` fast path(`relayouted`)
    /// 如果 component 实现了;否则走 full `layout(...)` 重算(仍仅影响本 row)。
    let applyState: (C.State) -> Void

    /// 请求 framework 刷新本 row 的 height(下一 layout pass 读
    /// `cachedSize.height`)。
    let noteHeightOfRow: () -> Void

    /// 请求 framework 重绘本 row(cachedSize 不变,仅重新 render)。
    let redraw: () -> Void

    /// 若本 row 的 state 变更让当前 selection 失效(如折叠后某段文字消失),
    /// 告诉 framework 清全局 selection。
    let clearSelection: () -> Void

    /// 访问 row 的 side-car(持有 `CALayer` / animation timeline 等 GPU
    /// 资源的 opt-in class)。默认 `EmptyRowSideCar` 无副作用。
    let sideCar: () -> C.SideCar
}

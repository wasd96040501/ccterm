import AppKit

/// Component 声明自己的**文本可选中区域**。framework 的 selection controller
/// 读这些 slot → 响应用户 drag 事件 → 算出选中 range → 通过 `apply(state:)`
/// 把 selection 作为 row-local `State` 的一部分写回 row。
///
/// ## 和老 `TextSelectable.selectableRegions` 对比
///
/// - 老设计:row 持有可变字段 `currentSelection: NSRange`,slot 带
///   `setSelection: (NSRange) -> Void` 闭包让 selection controller 写回
/// - 新设计:slot **纯声明**,不带闭包;selection 进 `C.State`,统一
///   走 `apply(state:)` 通道写回 → `render(...)` 读 state 里的 selection 绘制
///
/// 结果:row 没有可变字段,selection 和其他 row-local state(isExpanded /
/// hover)正交地共用一个 State 容器。
struct SelectableSlot: Sendable {
    /// 同 row 内多个 slot 的顺序。cross-row drag 时框架按 `ordering` 决定
    /// "从哪段到哪段"的选中区间。
    ///
    /// Nested to avoid name clash with the legacy `Ordering` type in
    /// `Controller/TextSelectable.swift` during the migration window. Once
    /// the old selection stack is deleted, 可以视情决定是否 flatten。
    let ordering: SlotOrdering

    /// 选中几何模型。
    let mode: Mode

    /// Slot 在 row-local 坐标系里的 frame。
    let frameInRow: CGRect

    /// 已布局的文本数据 —— 支持 character-level hit test + range 绘制。
    let layout: TranscriptTextLayout

    enum Mode: Sendable {
        /// 流式文本(段落 / 代码块 / list item 内部)。
        case flow
        /// 表格单元格(assistant 的 markdown table)。
        case table(row: Int, col: Int)
    }
}

/// Selection 的顺序键。两层:段级 `fragmentOrdinal`(如 assistant row 里的
/// segment index),段内 `subIndex`(如 table 单元格在段内的顺序)。
struct SlotOrdering: Hashable, Sendable {
    let fragmentOrdinal: Int
    let subIndex: Int
}

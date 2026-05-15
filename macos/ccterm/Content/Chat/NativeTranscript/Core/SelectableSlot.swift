import AppKit

/// Component 声明自己的**文本可选中区域**。framework 的 selection controller
/// 读这些 slot → 响应用户 drag 事件 → 算出选中 range → 调
/// `C.applySelection(key:range:to:)` 把 selection 折进 `State` → 替换 row state。
///
/// Slot **纯声明**:无闭包、无 row 引用。作者通过 `selectionKey` 告诉 framework
/// "这个 slot 的选中 range 按这个 key 存进我的 State"。`applySelection` / `clearingSelection`
/// 由 component override 完成具体合并逻辑。
///
/// 结果:row 没有可变字段,selection 和其他 row-local state(isExpanded /
/// hover)正交地共用一个 State 容器。
struct SelectableSlot: Sendable {
    /// 同 row 内多个 slot 的顺序。cross-row drag 时框架按 `ordering` 决定
    /// "从哪段到哪段"的选中区间。
    let ordering: SlotOrdering

    /// 选中几何模型。
    let mode: Mode

    /// Slot 在 row-local 坐标系里的 frame。
    let frameInRow: CGRect

    /// 已布局的文本数据 —— 支持 character-level hit test + range 绘制。
    let layout: TranscriptTextLayout

    /// 路由键 —— framework 把本 slot 的 range 通过 `C.applySelection(key:range:to:)`
    /// 合并进 state 时用的 key。作者按自己的 selection schema 构造(Int / 复合结构)。
    let selectionKey: AnyHashable

    enum Mode: Sendable {
        /// 流式文本(段落 / 代码块 / list item 内部)。
        case flow
        /// 表格单元格(assistant 的 markdown table)。
        case cell
    }
}

/// Selection 的顺序键。两层:段级 `fragmentOrdinal`(如 assistant row 里的
/// segment index),段内 `subIndex`(如 table 单元格在段内的顺序)。跨 row Cmd-C
/// 拼接按 `(rowIndex, ordering)` 字典序排列。
struct SlotOrdering: Hashable, Comparable, Sendable {
    let fragmentOrdinal: Int
    let subIndex: Int

    static func < (lhs: SlotOrdering, rhs: SlotOrdering) -> Bool {
        if lhs.fragmentOrdinal != rhs.fragmentOrdinal {
            return lhs.fragmentOrdinal < rhs.fragmentOrdinal
        }
        return lhs.subIndex < rhs.subIndex
    }
}

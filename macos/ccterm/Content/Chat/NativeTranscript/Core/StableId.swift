import Foundation

/// Row 的结构化身份。替代老 `AnyHashable` + 字符串约定(`"<uuid>-md-N"`)
/// —— 框架按字段读,不靠 split-dash 反查 entryId。
///
/// Diff / scroll anchor / cache 都以 `StableId` 做 key。
///
/// ## Locator 规则
///
/// | Locator | 适用 |
/// |---|---|
/// | `.whole` | 一个 entry 映射一条 row(user bubble / placeholder / group) |
/// | `.block(idx)` | 一个 entry 映射多条 row(assistant 里多个 text / tool_use block 各一行);`idx` 是 block 在 `entry.content` 里的下标 |
/// | `.custom(String)` | 逃生门。一个 block 需要拆成多条 row 等特殊场景 |
struct StableId: Hashable, Sendable {
    let entryId: UUID
    let locator: Locator

    enum Locator: Hashable, Sendable {
        case whole
        case block(Int)
        case custom(String)
    }
}

/// Component 从 entry 挑出的一条源料,带全局 ordering。
///
/// 新协议下一条 entry 可被多个 component 各扫一遍(component = **block**
/// 渲染器,不是 entry 处理器)。每个 component 只挑自己关心的 block,
/// builder 按 `(entryIndex, blockIndex)` 做全局 merge-sort 得到最终 row 顺序。
///
/// 使用示例(伪代码):
///
///     // assistant entry 内三种 block 各归不同 component
///     AssistantMarkdownComponent.inputs(from:)   // 挑 text blocks
///     ToolBlockComponent.inputs(from:)            // 挑 tool_use blocks
///     ThinkingComponent.inputs(from:)             // 挑 thinking blocks
///     // builder:each component.inputs(from: entry, entryIndex: i) → 合并 sort
struct IdentifiedInput<Input: Sendable>: Sendable {
    /// Diff / scroll anchor / cache 用。
    let stableId: StableId

    /// Entry 在 entries 数组里的全局下标。Builder 传入,component 不维护。
    let entryIndex: Int

    /// 这条 input 对应的 block 在 entry 里的位置(同 entry 多条 input 时用,
    /// 全局排序需要)。简单场景(user / placeholder)传 0。
    let blockIndex: Int

    let input: Input
}

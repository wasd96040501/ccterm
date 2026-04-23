import AppKit

/// Row 自报可点击区域 —— controller 的 hit / cursor 路径**只**认这个协议，
/// 不 `as? ConcreteRow`。新 row 只要 adopt 这个协议就能接入命中分发。
@MainActor
protocol InteractiveRow: AnyObject {
    /// 当前缓存布局下的所有 hit region（row-local 坐标）。
    /// 由 row 按自己的 fragment / geometry 算出，不持久化；controller 命中查询
    /// 时读一次。
    var hitRegions: [RowHitRegion] { get }
}

/// 一块可点击区域。row 给出矩形 + cursor + 一个 perform 闭包；controller 命
/// 中时调 `perform(controller)`，由 row 决定具体副作用（剪贴板 / toggle /
/// 重绘范围 / clear selection）。
struct RowHitRegion {
    let rectInRow: CGRect
    /// hover 时的光标形状。tableView 的 `cursorUpdate` 路径读这个。
    let cursor: NSCursor
    /// 命中 + 点击后的动作。row 拿到 controller 后可以自行 `redrawRow` /
    /// `noteHeightOfRow` / `selectionController.clear()` 等。
    let perform: @MainActor (TranscriptController) -> Void
}

/// Row 可被 controller 的「展开 id 集」反向同步。`UserBubbleRow` 和未来的
/// tool block 都 adopt；controller pipeline 每次 merge 后对所有 row 调一次
/// `applyExpansion`，不关心是什么具体类型。
@MainActor
protocol ExpandableRow: AnyObject {
    /// 根据 controller 持有的「已展开 stableId 集」同步自身展开态。
    /// row 自己决定哪个 key 命中自己（默认就是 `stableId`）。
    func applyExpansion(_ expanded: Set<AnyHashable>)
}

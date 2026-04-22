import AppKit

/// 基类：描述 transcript 中一行的数据 + 缓存的排版结果。
///
/// NSTableView 走 `rowView-only` 路径：每一行由 `TranscriptRowView` 子类
/// 全权负责绘制，没有 cell view。reuse 以 `identifier` 分桶——子类默认返回
/// 类名即可让同类 row 复用同一个 view pool。
///
/// 子类必须 override：
/// - ``stableId``：diff / reload 用
/// - ``contentHash``：同 stableId 下检测内容变化的指纹
/// - ``makeSize(width:)``：按 width 计算 `cachedHeight` + 内部 layout
/// - ``draw(in:bounds:)``：绘制内容到当前 flipped CGContext
/// - ``viewClass()``：若需要自定义 row view 子类
///
/// 对齐 Telegram `TableRowItem`：持 `weak var table` + `index`，row 可以反向
/// 调用 `table.noteHeightOfRow(_:)` 让表只刷新自己这一行——这是 tool block
/// 动态展开 / 收起的基础设施。
@MainActor
class TranscriptRow {
    init() {}

    /// Workaround: macOS 26 SDK 的 `swift_task_deinitOnExecutorImpl` 在 isolated
    /// deinit 链中命中 libmalloc pointer-freed-but-not-allocated 崩溃（尤其在
    /// XCTest 的 autoreleasepool drain 路径上）。显式 nonisolated deinit 跳过
    /// executor-hop。Row 的 stored property 释放（CTLine / NSAttributedString /
    /// 值类型）都是线程安全的。
    nonisolated deinit { }

    /// 逻辑稳定 id。diff 时按此比较新旧列表中的同一条消息。
    var stableId: AnyHashable { ObjectIdentifier(self) }

    /// 内容指纹。`stableId` 一样 + `contentHash` 一样 → 视为未变，旧 row 对象
    /// 直接 carry-over（保留 cached layout）。子类 override：返回 `Hasher` 结果。
    var contentHash: Int { 0 }

    /// NSTableView 的 reuse identifier。默认按 row 类名分桶，同类互相复用。
    var identifier: String { String(describing: type(of: self)) }

    /// 最近一次 `makeSize(width:)` 得到的宽度 + 高度。
    /// controller 读 `cachedHeight` 喂 `tableView(_:heightOfRow:)`。
    var cachedHeight: CGFloat = 0
    var cachedWidth: CGFloat = 0

    /// 宿主 controller（= Telegram 的 `table` 字段）。`merge` / `replace` 后由
    /// controller 负责维护，row 侧只读。
    weak var table: TranscriptController?

    /// row 在 controller.rows 中的当前下标。未挂载时为 -1。
    /// controller 每次改动 `rows` 后会重算一次，row 侧只读。
    var index: Int = -1

    /// 按当前宽度计算 layout / 尺寸。子类 override。
    /// 保证幂等：同宽度重复调用只计算一次。
    func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width
        cachedHeight = 0
    }

    /// rowView 类。默认 `TranscriptRowView`——仅负责把绘制委派回 row。
    /// 若需要 hover / track events 等 per-row 行为，再 override。
    func viewClass() -> TranscriptRowView.Type {
        TranscriptRowView.self
    }

    /// 绘制入口。`bounds` 是 rowView 的 bounds（已是 flipped 坐标：y 向下递增）。
    /// 子类 override 写具体绘制逻辑。基类空实现。
    func draw(in ctx: CGContext, bounds: CGRect) {}

    // MARK: - Row-level table ops (对齐 Telegram TableRowItem.redraw / noteHeightOfRow)

    /// 高度变了、内容没换——让 table 只刷新我这一行的高度 + 重绘。
    /// 典型用法：tool block 展开 / 收起、流式 assistant 消息增长。
    /// 必须在主线程调用。
    func noteHeightOfRow(animated: Bool = false) {
        guard index >= 0 else { return }
        table?.noteHeightOfRow(index, animated: animated)
    }

    /// 整行重画——内容发生本质变化但 stableId 不变的场景。
    /// 等价于 Telegram `TableRowItem.redraw`。
    func redraw(animated: Bool = false) {
        guard index >= 0 else { return }
        table?.reloadRow(index, animated: animated)
    }
}

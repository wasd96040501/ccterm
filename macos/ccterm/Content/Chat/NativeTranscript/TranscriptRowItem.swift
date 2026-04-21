import AppKit

/// 基类：描述 transcript 中一行的数据 + 缓存的排版结果。
///
/// NSTableView 走 `rowView-only` 路径：每一行由 `TranscriptRowView` 子类
/// 全权负责绘制，没有 cell view。reuse 以 `identifier` 分桶——子类默认返回
/// 类名即可让同类 item 复用同一个 view pool。
///
/// 子类必须 override：
/// - ``stableId``：diff / reload 用
/// - ``makeSize(width:)``：按 width 计算 `cachedHeight` + 内部 layout
/// - ``draw(in:bounds:)``：绘制内容到当前 flipped CGContext
/// - ``viewClass()``：若需要自定义 row view 子类
@MainActor
class TranscriptRowItem {
    init() {}

    /// 逻辑稳定 id。diff 时按此比较；Stage 1 不做细粒度 diff，仅作为排查依据。
    var stableId: AnyHashable { ObjectIdentifier(self) }

    /// NSTableView 的 reuse identifier。默认按 item 类名分桶，同类互相复用。
    var identifier: String { String(describing: type(of: self)) }

    /// 最近一次 `makeSize(width:)` 得到的宽度 + 高度。
    /// controller 读 `cachedHeight` 喂 `tableView(_:heightOfRow:)`。
    var cachedHeight: CGFloat = 0
    var cachedWidth: CGFloat = 0

    /// 按当前宽度计算 layout / 尺寸。子类 override。
    /// 保证幂等：同宽度重复调用只计算一次。
    func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width
        cachedHeight = 0
    }

    /// rowView 类。默认 `TranscriptRowView`——仅负责把绘制委派回 item。
    /// 若需要 hover / track events 等 per-item 行为，再 override。
    func viewClass() -> TranscriptRowView.Type {
        TranscriptRowView.self
    }

    /// 绘制入口。`bounds` 是 rowView 的 bounds（已是 flipped 坐标：y 向下递增）。
    /// 子类 override 写具体绘制逻辑。基类空实现。
    func draw(in ctx: CGContext, bounds: CGRect) {}
}

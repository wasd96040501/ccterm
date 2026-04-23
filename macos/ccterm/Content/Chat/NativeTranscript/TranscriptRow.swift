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

    /// Fragment 缓存（性能守则 #1）：`FragmentRow` 实现的 row 每次 width 变化
    /// 时调 `fragments(width:)` 填一次；`draw` / `hit` / `selectableRegions`
    /// 都读这里，绝不重建。非 FragmentRow 的 row 此数组恒为空。
    var cachedFragments: [Fragment] = []

    /// Fragment 路径下的选中状态（keyed by fragment 的 `selectionTag`）。
    /// 文本 fragment 的 setSelection 闭包 / `clearFragmentSelections` /
    /// `FragmentPainter.paintText` 都从这里读写。
    /// 命名带 `fragment` 前缀避免与旧 row 的 private storage 冲突（迁移期间共存）。
    var fragmentTextSelections: [Int: NSRange] = [:]
    var fragmentTableSelections: [Int: [[NSRange]]] = [:]
    var fragmentListSelections: [Int: [Int: NSRange]] = [:]

    /// 宿主 controller（= Telegram 的 `table` 字段）。`merge` / `replace` 后由
    /// controller 负责维护，row 侧只读。
    weak var table: TranscriptController?

    /// row 在 controller.rows 中的当前下标。未挂载时为 -1。
    /// controller 每次改动 `rows` 后会重算一次，row 侧只读。
    var index: Int = -1

    /// 按当前宽度计算 layout / 尺寸。子类可 override；默认实现走 `FragmentRow`
    /// 路径——若 self 是 FragmentRow 且 width 真变了，调 `fragments(width:)`
    /// 把返回的 `FragmentLayout` 拆到 `cachedFragments` 和 `cachedHeight`。
    /// 非 FragmentRow 且未 override 的 row 退化为高度 0（旧基类行为）。
    func makeSize(width: CGFloat) {
        guard width != cachedWidth else { return }
        cachedWidth = width
        if let fr = self as? FragmentRow {
            let layout = fr.fragments(width: width)
            cachedFragments = layout.fragments
            cachedHeight = layout.height
        } else {
            cachedHeight = 0
        }
    }

    /// rowView 类。默认 `TranscriptRowView`——仅负责把绘制委派回 row。
    /// 若需要 hover / track events 等 per-row 行为，再 override。
    func viewClass() -> TranscriptRowView.Type {
        TranscriptRowView.self
    }

    /// 绘制入口。`bounds` 是 rowView 的 bounds（已是 flipped 坐标：y 向下递增）。
    /// 默认实现：遍历 `cachedFragments` 走 ``FragmentPainter``。未迁移的
    /// 子类 override 这个方法，默认实现不会执行。
    func draw(in ctx: CGContext, bounds: CGRect) {
        guard !cachedFragments.isEmpty else { return }
        for frag in cachedFragments {
            FragmentPainter.paint(frag, row: self, in: ctx, bounds: bounds)
        }
    }

    /// 点击命中测试：row-local 坐标 → 需要 controller 响应的动作。
    /// Fragment 路径下遍历 `.custom` fragment 的 `hit`；逆序（后画的在上）
    /// 取第一个命中。未迁移的 row 可 override 返回自己的 action。
    func hit(at point: CGPoint) -> HitAction? {
        guard !cachedFragments.isEmpty else { return nil }
        for frag in cachedFragments.reversed() {
            if case .custom(let c) = frag, let action = c.hit, c.frame.contains(point) {
                return action
            }
        }
        return nil
    }

    /// Fragment 路径下自动生成 `SelectableTextRegion` 列表。
    /// 迁移后的 row 的 `TextSelectable.selectableRegions` 直接返回这个。
    /// regionIndex 编码：
    /// - `.text` fragment：`selectionTag`
    /// - `.table` fragment：`selectionTag * 1_000_000 + row * 1_000 + col`
    /// - `.list` fragment：`selectionTag * 1_000_000 + textIdx`
    func fragmentSelectableRegions() -> [SelectableTextRegion] {
        var regions: [SelectableTextRegion] = []
        let rowId = stableId
        for frag in cachedFragments {
            switch frag {
            case .text(let f):
                guard let tag = f.selectionTag, !f.layout.lines.isEmpty else { continue }
                regions.append(SelectableTextRegion(
                    rowStableId: rowId,
                    regionIndex: tag,
                    frameInRow: f.frame,
                    layout: f.layout,
                    setSelection: { [weak self] range in
                        self?.fragmentTextSelections[tag] = range
                    }))
            case .table(let f):
                guard let tag = f.selectionTag else { continue }
                let cellFrames = f.layout.cellContentFrames
                for (r, rowFrames) in cellFrames.enumerated() {
                    for (c, cellFrame) in rowFrames.enumerated() {
                        let cellLayout = f.layout.cells[r][c]
                        guard !cellLayout.lines.isEmpty else { continue }
                        let rIdx = tag * 1_000_000 + r * 1_000 + c
                        regions.append(SelectableTextRegion(
                            rowStableId: rowId,
                            regionIndex: rIdx,
                            frameInRow: CGRect(
                                x: f.origin.x + cellFrame.origin.x,
                                y: f.origin.y + cellFrame.origin.y,
                                width: cellFrame.width,
                                height: cellFrame.height),
                            layout: cellLayout,
                            setSelection: { [weak self] range in
                                guard let self else { return }
                                var matrix = self.fragmentTableSelections[tag] ?? []
                                guard r < matrix.count, c < matrix[r].count else { return }
                                matrix[r][c] = range
                                self.fragmentTableSelections[tag] = matrix
                            }))
                    }
                }
            case .list(let f):
                guard let tag = f.selectionTag else { continue }
                for (textIdx, textLayout, originInList) in f.layout.flattenedTexts() {
                    guard !textLayout.lines.isEmpty else { continue }
                    let rIdx = tag * 1_000_000 + textIdx
                    regions.append(SelectableTextRegion(
                        rowStableId: rowId,
                        regionIndex: rIdx,
                        frameInRow: CGRect(
                            x: f.origin.x + originInList.x,
                            y: f.origin.y + originInList.y,
                            width: max(textLayout.measuredWidth, 1),
                            height: max(textLayout.totalHeight, 1)),
                        layout: textLayout,
                        setSelection: { [weak self] range in
                            guard let self else { return }
                            var m = self.fragmentListSelections[tag] ?? [:]
                            m[textIdx] = range
                            self.fragmentListSelections[tag] = m
                        }))
                }
            case .rect, .line, .custom:
                continue
            }
        }
        return regions
    }

    /// Fragment 路径下的统一清选：清三类选中存储。迁移后的 row 的
    /// `TextSelectable.clearSelection` 直接调它。
    func clearFragmentSelections() {
        fragmentTextSelections.removeAll()
        // table：保留矩阵形状（行列数），把每格 range 置 NSNotFound。
        for (tag, matrix) in fragmentTableSelections {
            let empty = [[NSRange]](
                repeating: [NSRange](
                    repeating: NSRange(location: NSNotFound, length: 0),
                    count: matrix.first?.count ?? 0),
                count: matrix.count)
            fragmentTableSelections[tag] = empty
        }
        fragmentListSelections.removeAll()
    }

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

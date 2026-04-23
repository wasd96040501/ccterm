import AppKit

/// 跨 row 文本选中协调器。
///
/// 对齐 Telegram `ChatSelectText + SelectManager`，用 Swift native 命名。
/// 所有 public 入口用 **documentView 坐标系**（= tableView bounds）。
/// `NSResponder` 身份让 Cmd-C 走标准 responder chain。
///
/// 选中算法（y-interval 模型 + cell 模式 x 过滤）：
/// 1. anchor = mouseDown 点，focus = 当前点。按 y 分成 upper / lower。
/// 2. dragXRange = [min(anchor.x, focus.x), max(anchor.x, focus.x)]——仅对
///    `.cell` 模式 region 生效的列过滤。`.flow` 模式（文本段、list item）
///    天然占满 row 宽，x 过滤不 applicable。
/// 3. upperRow / lowerRow 覆盖的 row 区间里，每 row 的每个 selectable region
///    独立决定是否参与 + 起止点——
///    - `.cell` region：先 x 过滤；若通过，按几何规则裁（y 含 upper → 起点在
///      upper.y 截半，否则整 cell 起；y 含 lower → 终点在 lower.y 截半，
///      否则整 cell 止）。这样 table 的选中是 Excel 式：drag 横向只覆盖
///      某列 → 只有该列的 cell 被选。
///    - `.flow` region：以 row-local 下的 drag 覆盖 y 区间 ∩ region 的
///      row-local y 范围判定。不相交 → 跳过；相交 → 起止按 upper/lower
///      是否落在 region 的 y 范围内来切（边界 region 用 upper/lower 的 local
///      点，内部 region 整段；单 region 同时含 upper/lower 时用 raw anchor/focus
///      以保留反向拖动语义）。这样 drag 整段落在 table cell 里时，cell 的 y
///      区间内没有任何 flow，flow 自然全部跳过——不会把 table 上/下的段落
///      误带上。
/// 4. 对不参与的 region 显式 setSelection(NSNotFound)，避免残影。
@MainActor
final class TranscriptSelectionController: NSResponder {

    weak var controller: TranscriptController?

    private var anchorPoint: CGPoint?
    private var focusPoint: CGPoint?

    /// 排序后的选中记账条目——(rowIndex, ordering) 字典序升序。Cmd-C 时按此拼接。
    private struct Entry {
        let rowStableId: AnyHashable
        let rowIndex: Int
        let ordering: Ordering
        let substring: NSAttributedString
    }
    private var entries: [Entry] = []

    /// 上一轮参与选中的 (rowId, ordering) 集合——用于清掉不再参与的残影。
    private var lastSelectedKeys: Set<SelectionKey> = []
    private struct SelectionKey: Hashable {
        let rowStableId: AnyHashable
        let ordering: Ordering
    }

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    // MARK: - Drag lifecycle

    func beginDrag(at documentPoint: CGPoint) {
        clear()
        anchorPoint = documentPoint
        focusPoint = documentPoint
    }

    func updateDrag(at documentPoint: CGPoint) {
        guard anchorPoint != nil else { return }
        focusPoint = documentPoint
        recomputeSelection()
    }

    func endDrag(at documentPoint: CGPoint) {
        guard anchorPoint != nil else { return }
        focusPoint = documentPoint
        recomputeSelection()
        anchorPoint = nil
        focusPoint = nil
    }

    func clear() {
        for key in lastSelectedKeys {
            controller?.notifyRowSelectionCleared(stableId: key.rowStableId)
        }
        entries.removeAll()
        lastSelectedKeys.removeAll()
    }

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Click-granular selection (double = word, triple = paragraph)

    /// 双击：选中命中 region 内的 word（CFStringTokenizer）。
    /// 对齐 Telegram `TextView.mouseUp` clickCount==2 → `selectWord(at:)`。
    func selectWord(at documentPoint: CGPoint) {
        anchorPoint = nil
        focusPoint = nil
        applyGranular(at: documentPoint) { layout, local in
            layout.wordRange(at: local)
        }
    }

    /// 三击：选中命中 region 内的段落（\n 切）。
    /// 对齐 Telegram `TextView.mouseUp` clickCount==3 → `selectAll(at:)`
    /// 的段落语义。
    func selectParagraph(at documentPoint: CGPoint) {
        anchorPoint = nil
        focusPoint = nil
        applyGranular(at: documentPoint) { layout, local in
            layout.paragraphRange(at: local)
        }
    }

    /// 给定一个 doc point，定位 row + region，把 `rangeProvider` 返回的 range
    /// 写到该 region 上并更新记账。
    private func applyGranular(
        at documentPoint: CGPoint,
        rangeProvider: (TranscriptTextLayout, CGPoint) -> NSRange
    ) {
        clear()
        guard let controller else { return }
        guard let ctx = controller.rowLocalContext(at: documentPoint) else { return }
        guard let selectable = controller.rows[ctx.rowIndex] as? TextSelectable else { return }
        let regions = selectable.selectableRegions
        guard !regions.isEmpty else { return }
        let pointInRow = ctx.toRowLocal(documentPoint)
        let regionIdx = findRegionIndex(for: pointInRow, regions: regions)
        let region = regions[regionIdx]

        let local = CGPoint(
            x: pointInRow.x - region.frameInRow.origin.x,
            y: pointInRow.y - region.frameInRow.origin.y)

        let range = rangeProvider(region.layout, local)
        guard range.location != NSNotFound, range.length > 0 else { return }

        region.setSelection(range)
        let sub = region.layout.attributed.attributedSubstring(from: range)
        entries = [Entry(
            rowStableId: region.rowStableId,
            rowIndex: ctx.rowIndex,
            ordering: region.ordering,
            substring: sub)]
        lastSelectedKeys = [SelectionKey(
            rowStableId: region.rowStableId,
            ordering: region.ordering)]
        controller.notifyRowSelectionChanged(index: ctx.rowIndex)
    }

    // MARK: - Recompute

    private func recomputeSelection() {
        guard let controller, let anchor = anchorPoint, let focus = focusPoint else { return }
        guard let tableView = controller.tableView else { return }

        // 1. 按 y 分出上下点。layout.selectionRange 内部处理同行反向 x，不依赖 upper/lower
        //    的 x 顺序，但 row 级头/尾判定必须用 y。
        let upper = anchor.y <= focus.y ? anchor : focus
        let lower = anchor.y <= focus.y ? focus : anchor

        // Cell 模式的 x 过滤范围——drag 包围框的 x 区间。flow 模式不看这个。
        let dragXMin = min(anchor.x, focus.x)
        let dragXMax = max(anchor.x, focus.x)

        var upperRow = clampedRow(at: upper, tableView: tableView)
        var lowerRow = clampedRow(at: lower, tableView: tableView)
        guard upperRow >= 0, lowerRow >= 0,
              upperRow < controller.rows.count, lowerRow < controller.rows.count else {
            return
        }
        // Clamp 后理应 upperRow <= lowerRow，这里兜底交换——避免罕见几何下
        // (如 resize 过程中 bounds 瞬间为 0) 走到 `upperRow...lowerRow` 崩溃。
        if upperRow > lowerRow {
            swap(&upperRow, &lowerRow)
        }

        var nextEntries: [Entry] = []
        var nextKeys: Set<SelectionKey> = []
        var visitedRowIdxs: Set<Int> = []

        for rowIdx in upperRow...lowerRow {
            visitedRowIdxs.insert(rowIdx)
            let row = controller.rows[rowIdx]
            let regions = row.selectableRegions
            guard !regions.isEmpty else { continue }
            guard let ctx = controller.rowLocalContext(forRow: rowIdx) else { continue }

            // drag 的 x 区间翻到 row-local，用于 cell 模式的横向过滤
            let dragXMinInRow = ctx.toRowLocal(CGPoint(x: dragXMin, y: 0)).x
            let dragXMaxInRow = ctx.toRowLocal(CGPoint(x: dragXMax, y: 0)).x

            for region in regions {
                let range: NSRange

                switch region.mode {
                case .cell:
                    range = cellSelectionRange(
                        region: region,
                        ctx: ctx,
                        upper: upper,
                        lower: lower,
                        dragXMinInRow: dragXMinInRow,
                        dragXMaxInRow: dragXMaxInRow,
                        rowIdx: rowIdx,
                        upperRow: upperRow,
                        lowerRow: lowerRow)
                case .flow:
                    range = flowSelectionRange(
                        region: region,
                        ctx: ctx,
                        anchor: anchor, focus: focus, upper: upper, lower: lower,
                        rowIdx: rowIdx,
                        upperRow: upperRow,
                        lowerRow: lowerRow)
                }

                if range.location != NSNotFound, range.length > 0 {
                    region.setSelection(range)
                    let sub = region.layout.attributed.attributedSubstring(from: range)
                    nextEntries.append(Entry(
                        rowStableId: region.rowStableId,
                        rowIndex: rowIdx,
                        ordering: region.ordering,
                        substring: sub))
                    nextKeys.insert(SelectionKey(
                        rowStableId: region.rowStableId,
                        ordering: region.ordering))
                } else {
                    region.setSelection(NSRange(location: NSNotFound, length: 0))
                }
            }
            controller.notifyRowSelectionChanged(index: rowIdx)
        }

        // 清掉上一轮参与、这一轮已经不在 [upperRow, lowerRow] 区间内的 row。
        for key in lastSelectedKeys where !nextKeys.contains(key) {
            // 该 row 要么被 updateDrag 外滑动出区间，要么 region 本轮未命中——
            // region setSelection(NSNotFound) 已经在区间内 row 里处理，这里只需处理
            // 不再访问的 row。
            if !visitedRowIdxs.contains(where: {
                controller.rows[$0].stableId == key.rowStableId
            }) {
                controller.notifyRowSelectionCleared(stableId: key.rowStableId)
            }
        }

        nextEntries.sort { lhs, rhs in
            if lhs.rowIndex != rhs.rowIndex { return lhs.rowIndex < rhs.rowIndex }
            return lhs.ordering < rhs.ordering
        }
        entries = nextEntries
        lastSelectedKeys = nextKeys
    }

    // MARK: - Per-region rules

    /// `.cell` 模式：drag 矩形 ∩ region frame。x 完全不重叠 → 跳过；y 裁切规则
    /// = 含 upper.y / lower.y 的 cell 对应半边裁，否则全量。x 内部不裁，cell
    /// 过滤了 x 过后内部总是整列宽度——这就是「落在哪些列就复制哪些列」的
    /// 语义，用户体感近 Excel rect 选择。
    private func cellSelectionRange(
        region: SelectableTextRegion,
        ctx: TranscriptController.RowLocalContext,
        upper: CGPoint, lower: CGPoint,
        dragXMinInRow: CGFloat, dragXMaxInRow: CGFloat,
        rowIdx: Int, upperRow: Int, lowerRow: Int
    ) -> NSRange {
        let f = region.frameInRow
        // X 过滤
        if f.maxX < dragXMinInRow || f.minX > dragXMaxInRow {
            return NSRange(location: NSNotFound, length: 0)
        }
        // Y 过滤（应对：cell 比 transcript row 高度更细粒度的场景，目前 table cell 也是如此）
        let upperInRow = ctx.toRowLocal(upper)
        let lowerInRow = ctx.toRowLocal(lower)
        // rowIdx == upperRow 但 cell 整个在 upper 之上 → 跳过
        if rowIdx == upperRow, f.maxY <= upperInRow.y {
            return NSRange(location: NSNotFound, length: 0)
        }
        // rowIdx == lowerRow 但 cell 整个在 lower 之下 → 跳过
        if rowIdx == lowerRow, f.minY >= lowerInRow.y {
            return NSRange(location: NSNotFound, length: 0)
        }
        // 计算 cell-local 的 y 起止（x 始终从 0 到 cell 宽——「整列」语义）
        let startY: CGFloat
        if rowIdx == upperRow, f.minY < upperInRow.y, upperInRow.y < f.maxY {
            startY = upperInRow.y - f.minY
        } else {
            startY = 0
        }
        let endY: CGFloat
        if rowIdx == lowerRow, f.minY < lowerInRow.y, lowerInRow.y < f.maxY {
            endY = lowerInRow.y - f.minY
        } else {
            endY = min(region.layout.totalHeight, f.height) + 1
        }
        let startLocal = CGPoint(x: 0, y: startY)
        let endLocal = CGPoint(x: region.layout.measuredWidth, y: endY)
        return region.layout.selectionRange(from: startLocal, to: endLocal)
    }

    /// `.flow` 模式：以 drag 覆盖的 row-local y 区间 ∩ region 的 y 范围做判定。
    /// 不相交 → 跳过；相交 → 起止按 upper/lower 是否落在 region 的 y 范围内来切。
    ///
    /// 换掉的旧 upper/lower region-index 模型在 anchor/focus 同时落在 `.cell`
    /// region 里时会 fallback 到"最近的 flow"，把 table 上/下的段落误带进选中。
    /// y-interval 模型天然避开——cell 的 y 区间不含任何 flow，不相交的 flow
    /// 直接跳过。
    private func flowSelectionRange(
        region: SelectableTextRegion,
        ctx: TranscriptController.RowLocalContext,
        anchor: CGPoint, focus: CGPoint, upper: CGPoint, lower: CGPoint,
        rowIdx: Int, upperRow: Int, lowerRow: Int
    ) -> NSRange {
        let regionMinY = region.frameInRow.minY
        let regionMaxY = region.frameInRow.maxY

        let upperInRow = ctx.toRowLocal(upper)
        let lowerInRow = ctx.toRowLocal(lower)

        // Row-local 下 drag 覆盖的 y 区间。中间 row（非 upperRow 非 lowerRow）
        // 代表整 row 都在 drag 区间内，用 ±∞ 模拟"整段"。
        let intervalMinY: CGFloat
        let intervalMaxY: CGFloat
        if rowIdx == upperRow && rowIdx == lowerRow {
            intervalMinY = upperInRow.y
            intervalMaxY = lowerInRow.y
        } else if rowIdx == upperRow {
            intervalMinY = upperInRow.y
            intervalMaxY = .greatestFiniteMagnitude
        } else if rowIdx == lowerRow {
            intervalMinY = -.greatestFiniteMagnitude
            intervalMaxY = lowerInRow.y
        } else {
            intervalMinY = -.greatestFiniteMagnitude
            intervalMaxY = .greatestFiniteMagnitude
        }

        // [intervalMinY, intervalMaxY] ∩ [regionMinY, regionMaxY] = ∅ → 跳过
        if intervalMaxY < regionMinY || intervalMinY > regionMaxY {
            return NSRange(location: NSNotFound, length: 0)
        }

        let upperInsideRegion = rowIdx == upperRow
            && regionMinY <= upperInRow.y && upperInRow.y <= regionMaxY
        let lowerInsideRegion = rowIdx == lowerRow
            && regionMinY <= lowerInRow.y && lowerInRow.y <= regionMaxY

        let startLocal: CGPoint
        let endLocal: CGPoint

        // 单 region 同时含 upper & lower → 用 raw anchor/focus 保留反向拖动的 x 语义
        if upperInsideRegion && lowerInsideRegion {
            startLocal = toLocal(anchor, ctx: ctx, region: region)
            endLocal = toLocal(focus, ctx: ctx, region: region)
        } else {
            startLocal = upperInsideRegion
                ? toLocal(upper, ctx: ctx, region: region)
                : .zero
            endLocal = lowerInsideRegion
                ? toLocal(lower, ctx: ctx, region: region)
                : regionEnd(region)
        }

        return region.layout.selectionRange(from: startLocal, to: endLocal)
    }

    // MARK: - Geometry helpers

    private func toLocal(
        _ docPoint: CGPoint,
        ctx: TranscriptController.RowLocalContext,
        region: SelectableTextRegion
    ) -> CGPoint {
        let pointInRow = ctx.toRowLocal(docPoint)
        return CGPoint(
            x: pointInRow.x - region.frameInRow.origin.x,
            y: pointInRow.y - region.frameInRow.origin.y)
    }

    private func regionEnd(_ region: SelectableTextRegion) -> CGPoint {
        // `frameInRow.height` 可能比 `layout.totalHeight` 小（UserBubbleRow 折叠
        // 态会截断 region 高度）。用 min 保证 selection 不越过可见区，避免折叠态
        // 从气泡内向下拖时 selection range 扫到隐藏行的字符。
        let y = min(region.layout.totalHeight, region.frameInRow.height) + 1
        return CGPoint(x: region.layout.measuredWidth, y: y)
    }

    /// row 内 point → region 下标。先 frame contains，不中取 y-center 最近。
    /// 对齐 Telegram `findClosestRect` 的语义，解决点落在 region 之间缝隙的归属。
    private func findRegionIndex(for pointInRow: CGPoint, regions: [SelectableTextRegion]) -> Int {
        for (i, region) in regions.enumerated() {
            if region.frameInRow.contains(pointInRow) { return i }
        }
        var bestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, region) in regions.enumerated() {
            let d = abs(region.frameInRow.midY - pointInRow.y)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    /// 把 doc point 归一成 tableView 内的有效 row。
    ///
    /// 注意：`NSTableView.row(at:)` 对 **任何** 超出 bounds 的点都返回 -1——
    /// 包括 x 出界、y 在界内的情况。如果仅拿 y 走 fallback（y<=0→0，否则
    /// rowCount-1），upper 点 x 越界 + lower 点 x 在界内时会得到 upperRow =
    /// rowCount-1 > lowerRow 的非法组合，撞上
    /// `for rowIdx in upperRow...lowerRow` 的 `lowerBound <= upperBound` 断言。
    ///
    /// 解决：先把 point 夹回 bounds 再 `row(at:)`，这样 y 的行序在 clamp 后仍
    /// 保持单调——upper.y <= lower.y 必然推出 upperRow <= lowerRow。
    private func clampedRow(at point: CGPoint, tableView: NSTableView) -> Int {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return -1 }
        let b = tableView.bounds
        guard b.width > 0, b.height > 0 else { return -1 }
        let cx = min(max(point.x, b.minX), b.maxX - 1)
        let cy = min(max(point.y, b.minY), b.maxY - 1)
        let raw = tableView.row(at: CGPoint(x: cx, y: cy))
        if raw >= 0 { return raw }
        // clamp 后 row(at:) 理论上必中；保留 y-fallback 以防万一。
        return cy <= b.minY ? 0 : rowCount - 1
    }

    // MARK: - NSResponder / copy

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        clear()
        controller?.redrawAllVisibleRows()
        return true
    }

    /// Cmd-C。跨 row 间隔 `\n\n`，同 row 内不同 region 间 `\n`。
    ///
    /// U+FFFC（OBJECT REPLACEMENT CHARACTER）是 `InlineSpacer` / NSTextAttachment
    /// 在 backing store 里的占位符——纯 layout 用，绝对不能进剪贴板。
    @objc func copy(_ sender: Any?) {
        guard !entries.isEmpty else { return }
        let out = NSMutableString()
        var prevRowIndex: Int? = nil
        for entry in entries {
            if let prev = prevRowIndex {
                if prev == entry.rowIndex {
                    out.append("\n")
                } else {
                    out.append("\n\n")
                }
            }
            let cleaned = entry.substring.string
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            out.append(cleaned)
            prevRowIndex = entry.rowIndex
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: self)
        pb.setString(out as String, forType: .string)
    }
}

import AppKit

/// 跨 row 文本选中协调器。
///
/// 对齐 Telegram `ChatSelectText + SelectManager`，用 Swift native 命名。
/// 所有 public 入口用 **documentView 坐标系**（= tableView bounds）。
/// `NSResponder` 身份让 Cmd-C 走标准 responder chain。
///
/// 选中算法（upper/lower 模型）：
/// 1. anchor = mouseDown 点，focus = 当前点。按 y 分成 upper / lower。
/// 2. upperRow / lowerRow 覆盖的 row 区间里，每 row 的每个 selectable region
///    独立决定是否参与 + 起止点——
///    - 单 row：region 要在 [upperRegion, lowerRegion] 范围内才选；边界 region
///      用 upper/lower 的 local 点切，中间 region 整段
///    - 跨 row 的头 row：upperRegion 起，其后的全部整段；之前的 region 不选
///    - 跨 row 的尾 row：lowerRegion 止，之前的全部整段；之后的 region 不选
///    - 中间 row：所有 region 整段
/// 3. 对不参与的 region 显式 setSelection(NSNotFound)，避免残影。
///
/// 这一步对齐了 Telegram 的 `ChatSelectText.runSelector` 里 `start_j / end_j`
/// 语义——只选中 drag 触达的 region，不让 code block 外的 segment 被带选。
@MainActor
final class TranscriptSelectionController: NSResponder {

    weak var controller: TranscriptController?

    private var anchorPoint: CGPoint?
    private var focusPoint: CGPoint?

    /// 排序后的选中记账条目——rowIndex 升序、regionIndex 升序。Cmd-C 时按此拼接。
    private struct Entry {
        let rowStableId: AnyHashable
        let rowIndex: Int
        let regionIndex: Int
        let substring: NSAttributedString
    }
    private var entries: [Entry] = []

    /// 上一轮参与选中的 (rowIndex, regionIndex) 集合——用于清掉不再参与的残影。
    private var lastSelectedKeys: Set<SelectionKey> = []
    private struct SelectionKey: Hashable {
        let rowStableId: AnyHashable
        let regionIndex: Int
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
        guard let controller, let tableView = controller.tableView else { return }
        let rowIdx = tableView.row(at: documentPoint)
        guard rowIdx >= 0, rowIdx < controller.rows.count else { return }
        guard let selectable = controller.rows[rowIdx] as? TextSelectable else { return }
        let regions = selectable.selectableRegions
        guard !regions.isEmpty else { return }
        let rowRect = tableView.rect(ofRow: rowIdx)
        let pointInRow = CGPoint(
            x: documentPoint.x - rowRect.origin.x,
            y: documentPoint.y - rowRect.origin.y)
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
            rowIndex: rowIdx,
            regionIndex: region.regionIndex,
            substring: sub)]
        lastSelectedKeys = [SelectionKey(
            rowStableId: region.rowStableId,
            regionIndex: region.regionIndex)]
        controller.notifyRowSelectionChanged(index: rowIdx)
    }

    // MARK: - Recompute

    private func recomputeSelection() {
        guard let controller, let anchor = anchorPoint, let focus = focusPoint else { return }
        guard let tableView = controller.tableView else { return }

        // 1. 按 y 分出上下点。layout.selectionRange 内部处理同行反向 x，不依赖 upper/lower
        //    的 x 顺序，但 row 级头/尾判定必须用 y。
        let upper = anchor.y <= focus.y ? anchor : focus
        let lower = anchor.y <= focus.y ? focus : anchor

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
            guard let selectable = row as? TextSelectable else { continue }
            let regions = selectable.selectableRegions
            guard !regions.isEmpty else { continue }
            let rowRect = tableView.rect(ofRow: rowIdx)

            // 点在 row 坐标系内的位置——用于匹配 region
            let upperInRow = CGPoint(
                x: upper.x - rowRect.origin.x,
                y: upper.y - rowRect.origin.y)
            let lowerInRow = CGPoint(
                x: lower.x - rowRect.origin.x,
                y: lower.y - rowRect.origin.y)

            // row 在 upperRow / lowerRow 时才需要「哪个 region 被点命中」
            let upperRegionIdx = rowIdx == upperRow
                ? findRegionIndex(for: upperInRow, regions: regions) : 0
            let lowerRegionIdx = rowIdx == lowerRow
                ? findRegionIndex(for: lowerInRow, regions: regions) : regions.count - 1

            for (idx, region) in regions.enumerated() {
                // 决定本 region 是否参与 + 起止点（在 region layout 自己的坐标系）
                let participates: Bool
                let startLocal: CGPoint
                let endLocal: CGPoint

                if upperRow == lowerRow {
                    // 单 row
                    let loReg = min(upperRegionIdx, lowerRegionIdx)
                    let hiReg = max(upperRegionIdx, lowerRegionIdx)
                    if idx < loReg || idx > hiReg {
                        participates = false
                        startLocal = .zero
                        endLocal = .zero
                    } else if idx == upperRegionIdx && idx == lowerRegionIdx {
                        // 两端同 region：直接 anchor→focus 喂给 layout；
                        // layout.selectionRange 内部会 swap reversed 的 x
                        participates = true
                        startLocal = toLocal(anchor, inRow: rowRect, region: region)
                        endLocal = toLocal(focus, inRow: rowRect, region: region)
                    } else if idx == upperRegionIdx {
                        participates = true
                        startLocal = toLocal(upper, inRow: rowRect, region: region)
                        endLocal = regionEnd(region)
                    } else if idx == lowerRegionIdx {
                        participates = true
                        startLocal = .zero
                        endLocal = toLocal(lower, inRow: rowRect, region: region)
                    } else {
                        participates = true
                        startLocal = .zero
                        endLocal = regionEnd(region)
                    }
                } else if rowIdx == upperRow {
                    // 头 row: upperRegion 起
                    if idx < upperRegionIdx {
                        participates = false
                        startLocal = .zero
                        endLocal = .zero
                    } else if idx == upperRegionIdx {
                        participates = true
                        startLocal = toLocal(upper, inRow: rowRect, region: region)
                        endLocal = regionEnd(region)
                    } else {
                        participates = true
                        startLocal = .zero
                        endLocal = regionEnd(region)
                    }
                } else if rowIdx == lowerRow {
                    // 尾 row: lowerRegion 止
                    if idx > lowerRegionIdx {
                        participates = false
                        startLocal = .zero
                        endLocal = .zero
                    } else if idx == lowerRegionIdx {
                        participates = true
                        startLocal = .zero
                        endLocal = toLocal(lower, inRow: rowRect, region: region)
                    } else {
                        participates = true
                        startLocal = .zero
                        endLocal = regionEnd(region)
                    }
                } else {
                    // 中间 row: 全选
                    participates = true
                    startLocal = .zero
                    endLocal = regionEnd(region)
                }

                if participates {
                    let range = region.layout.selectionRange(from: startLocal, to: endLocal)
                    region.setSelection(range)
                    if range.location != NSNotFound, range.length > 0 {
                        let sub = region.layout.attributed.attributedSubstring(from: range)
                        nextEntries.append(Entry(
                            rowStableId: region.rowStableId,
                            rowIndex: rowIdx,
                            regionIndex: region.regionIndex,
                            substring: sub))
                        nextKeys.insert(SelectionKey(
                            rowStableId: region.rowStableId,
                            regionIndex: region.regionIndex))
                    }
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
            return lhs.regionIndex < rhs.regionIndex
        }
        entries = nextEntries
        lastSelectedKeys = nextKeys
    }

    // MARK: - Geometry helpers

    private func toLocal(
        _ docPoint: CGPoint,
        inRow rowRect: CGRect,
        region: SelectableTextRegion
    ) -> CGPoint {
        CGPoint(
            x: docPoint.x - rowRect.origin.x - region.frameInRow.origin.x,
            y: docPoint.y - rowRect.origin.y - region.frameInRow.origin.y)
    }

    private func regionEnd(_ region: SelectableTextRegion) -> CGPoint {
        CGPoint(x: region.layout.measuredWidth, y: region.layout.totalHeight + 1)
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
            out.append(entry.substring.string)
            prevRowIndex = entry.rowIndex
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: self)
        pb.setString(out as String, forType: .string)
    }
}

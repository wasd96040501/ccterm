import AppKit

/// 跨 row 文本选中协调器。
///
/// 对齐 Telegram `ChatSelectText + SelectManager` 两个类的合集，但：
/// - 命名走 AppKit 风：`TranscriptSelectionController` / `SelectableTextRegion`
/// - 把 registry 并入 controller（我们 per-table 就一个实例；不跨窗口）
/// - 作为 `NSResponder` 挂进 responder chain，`copy(_:)` 走标准路径
///
/// 坐标：所有 public 入口用 **documentView 坐标系**（= tableView bounds）。
/// row frame 通过 `tableView.rect(ofRow:)` 拿，region 通过 row 的 `selectableRegions`
/// 拿 row-local frame，相加得到 region 在 document 里的 origin。
@MainActor
final class TranscriptSelectionController: NSResponder {

    weak var controller: TranscriptController?

    /// 单一 anchor → focus 拖动。anchor 是按下点，focus 是当前鼠标。
    private var anchorPoint: CGPoint?
    private var focusPoint: CGPoint?

    /// 按选中顺序记账 —— 同一 row 内多段按 regionIndex 升序，跨 row 按 row index 升序。
    /// 拷贝时按这个顺序拼。
    private struct Entry {
        let rowStableId: AnyHashable
        let rowIndex: Int
        let regionIndex: Int
        let substring: NSAttributedString
    }
    private var entries: [Entry] = []

    override init() {
        super.init()
    }

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
        // 保留 entries，不清掉——用户接下来可能 Cmd-C。
        anchorPoint = nil
        focusPoint = nil
    }

    /// 清全部选中 + 通知各 row 清状态 + 重绘。
    func clear() {
        for entry in entries {
            controller?.notifyRowSelectionCleared(stableId: entry.rowStableId)
        }
        entries.removeAll()
    }

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Recompute

    private func recomputeSelection() {
        guard let controller, let anchor = anchorPoint, let focus = focusPoint else { return }
        let tableView = controller.tableView
        guard let tableView else { return }

        // Telegram 起 / 终行是直接 row(at:)，超界返回 -1。我们按 y 在 tableView
        // 可视区之外时 clamp 到首行 / 末行。
        let anchorRow = clampedRow(at: anchor, tableView: tableView)
        let focusRow = clampedRow(at: focus, tableView: tableView)
        guard anchorRow >= 0, focusRow >= 0,
              anchorRow < controller.rows.count, focusRow < controller.rows.count else {
            return
        }

        let startRow = min(anchorRow, focusRow)
        let endRow = max(anchorRow, focusRow)

        // 新 entries；和上一轮对比，把没再出现的 row 清掉。
        var freshStableIds: Set<AnyHashable> = []
        var nextEntries: [Entry] = []

        for rowIdx in startRow...endRow {
            let row = controller.rows[rowIdx]
            guard let selectable = row as? TextSelectable else { continue }
            let rowRect = tableView.rect(ofRow: rowIdx)

            let regions = selectable.selectableRegions
            guard !regions.isEmpty else { continue }

            for region in regions {
                let regionOriginInDoc = CGPoint(
                    x: rowRect.origin.x + region.frameInRow.origin.x,
                    y: rowRect.origin.y + region.frameInRow.origin.y)

                // 把 anchor / focus 转成 layout-local 坐标。对于头尾行以外的 row
                // 要「整段选中」：startPoint=(0,0), endPoint=(maxX, totalHeight+1)。
                let layout = region.layout
                let (lStart, lEnd) = localPoints(
                    rowIdx: rowIdx,
                    startRow: startRow,
                    endRow: endRow,
                    anchor: anchor,
                    focus: focus,
                    anchorRow: anchorRow,
                    focusRow: focusRow,
                    regionOriginInDoc: regionOriginInDoc,
                    layout: layout)

                let range = layout.selectionRange(from: lStart, to: lEnd)
                region.setSelection(range)

                if range.location != NSNotFound, range.length > 0 {
                    let sub = layout.attributed.attributedSubstring(from: range)
                    nextEntries.append(Entry(
                        rowStableId: region.rowStableId,
                        rowIndex: rowIdx,
                        regionIndex: region.regionIndex,
                        substring: sub))
                    freshStableIds.insert(region.rowStableId)
                } else {
                    // 显式清空本段——避免留残影。
                    region.setSelection(NSRange(location: NSNotFound, length: 0))
                }
            }
            controller.notifyRowSelectionChanged(index: rowIdx)
        }

        // 清掉上轮在 [startRow, endRow] 之外留下的选中。
        for entry in entries where !freshStableIds.contains(entry.rowStableId) {
            controller.notifyRowSelectionCleared(stableId: entry.rowStableId)
        }

        // 排序：row index 升序，同 row 内 regionIndex 升序。
        nextEntries.sort { lhs, rhs in
            if lhs.rowIndex != rhs.rowIndex { return lhs.rowIndex < rhs.rowIndex }
            return lhs.regionIndex < rhs.regionIndex
        }
        entries = nextEntries
    }

    /// 计算 layout 自己坐标系里的 start / end 点。
    private func localPoints(
        rowIdx: Int,
        startRow: Int,
        endRow: Int,
        anchor: CGPoint,
        focus: CGPoint,
        anchorRow: Int,
        focusRow: Int,
        regionOriginInDoc: CGPoint,
        layout: TranscriptTextLayout
    ) -> (CGPoint, CGPoint) {
        let reversed = focusRow < anchorRow
        let isMultiRow = startRow != endRow

        func toLocal(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - regionOriginInDoc.x, y: p.y - regionOriginInDoc.y)
        }
        let regionEnd = CGPoint(x: layout.measuredWidth, y: layout.totalHeight + 1)
        let regionStart = CGPoint.zero

        if !isMultiRow {
            return (toLocal(anchor), toLocal(focus))
        }
        if rowIdx > startRow && rowIdx < endRow {
            return (regionStart, regionEnd)
        }
        if rowIdx == anchorRow {
            if reversed {
                return (regionStart, toLocal(anchor))
            } else {
                return (toLocal(anchor), regionEnd)
            }
        }
        if rowIdx == focusRow {
            if reversed {
                return (toLocal(focus), regionEnd)
            } else {
                return (regionStart, toLocal(focus))
            }
        }
        return (regionStart, regionEnd)
    }

    private func clampedRow(at point: CGPoint, tableView: NSTableView) -> Int {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return -1 }
        let raw = tableView.row(at: point)
        if raw >= 0 { return raw }
        // row(at:) 给 -1 的两种情况：点在表上面（y<first row's minY） / 下面。
        if point.y <= 0 { return 0 }
        return rowCount - 1
    }

    // MARK: - NSResponder / copy

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        clear()
        controller?.redrawAllVisibleRows()
        return true
    }

    /// Cmd-C。把 entries 顺序拼起来写 pasteboard。跨 row 用 `\n\n` 分隔，同 row
    /// 内不同 region 用 `\n`。
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

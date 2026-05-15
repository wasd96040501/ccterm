import AppKit

/// 跨 row 文本选中协调器。基于 component callbacks 的 `selectables` /
/// `applySelection` / `clearingSelection` / `selectedFragments` 通道,与
/// 具体 row 类型解耦。
///
/// 选中算法保持原 y-interval 模型 + cell 模式 x 过滤。
@MainActor
final class TranscriptSelectionController: NSResponder {

    weak var controller: TranscriptController?

    private var anchorPoint: CGPoint?
    private var focusPoint: CGPoint?

    /// 上一轮参与选中的 (rowStableId, ordering) 集合 —— 用于清掉不再参与的残影。
    private var lastSelectedKeys: Set<SelectionKey> = []
    private struct SelectionKey: Hashable {
        let rowStableId: StableId
        let ordering: SlotOrdering
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
        lastSelectedKeys.removeAll()
    }

    var isEmpty: Bool { lastSelectedKeys.isEmpty }

    // MARK: - Click-granular selection

    func selectWord(at documentPoint: CGPoint) {
        anchorPoint = nil
        focusPoint = nil
        applyGranular(at: documentPoint) { layout, local in
            layout.wordRange(at: local)
        }
    }

    func selectParagraph(at documentPoint: CGPoint) {
        anchorPoint = nil
        focusPoint = nil
        applyGranular(at: documentPoint) { layout, local in
            layout.paragraphRange(at: local)
        }
    }

    private func applyGranular(
        at documentPoint: CGPoint,
        rangeProvider: (TranscriptTextLayout, CGPoint) -> NSRange
    ) {
        clear()
        guard let controller else { return }
        guard let ctx = controller.rowLocalContext(at: documentPoint) else { return }
        let row = controller.rows[ctx.rowIndex]
        let slots = row.callbacks.selectables(row)
        guard !slots.isEmpty else { return }
        let pointInRow = ctx.toRowLocal(documentPoint)
        let slotIdx = findSlotIndex(for: pointInRow, slots: slots)
        let slot = slots[slotIdx]

        let local = CGPoint(
            x: pointInRow.x - slot.frameInRow.origin.x,
            y: pointInRow.y - slot.frameInRow.origin.y)

        let range = rangeProvider(slot.layout, local)
        guard range.location != NSNotFound, range.length > 0 else { return }

        applySelection(rowIndex: ctx.rowIndex, slot: slot, range: range)
        lastSelectedKeys = [SelectionKey(
            rowStableId: row.stableId, ordering: slot.ordering)]
        controller.notifyRowSelectionChanged(index: ctx.rowIndex)
    }

    // MARK: - Recompute

    private func recomputeSelection() {
        guard let controller, let anchor = anchorPoint, let focus = focusPoint else { return }
        guard let tableView = controller.tableView else { return }

        let upper = anchor.y <= focus.y ? anchor : focus
        let lower = anchor.y <= focus.y ? focus : anchor

        let dragXMin = min(anchor.x, focus.x)
        let dragXMax = max(anchor.x, focus.x)

        var upperRow = clampedRow(at: upper, tableView: tableView)
        var lowerRow = clampedRow(at: lower, tableView: tableView)
        guard upperRow >= 0, lowerRow >= 0,
              upperRow < controller.rows.count, lowerRow < controller.rows.count else {
            return
        }
        if upperRow > lowerRow {
            swap(&upperRow, &lowerRow)
        }

        var nextKeys: Set<SelectionKey> = []
        var visitedRowIdxs: Set<Int> = []

        for rowIdx in upperRow...lowerRow {
            visitedRowIdxs.insert(rowIdx)
            let row = controller.rows[rowIdx]
            let slots = row.callbacks.selectables(row)
            guard !slots.isEmpty else { continue }
            guard let ctx = controller.rowLocalContext(forRow: rowIdx) else { continue }

            let dragXMinInRow = ctx.toRowLocal(CGPoint(x: dragXMin, y: 0)).x
            let dragXMaxInRow = ctx.toRowLocal(CGPoint(x: dragXMax, y: 0)).x

            for slot in slots {
                let range: NSRange
                switch slot.mode {
                case .cell:
                    range = cellSelectionRange(
                        slot: slot, ctx: ctx,
                        upper: upper, lower: lower,
                        dragXMinInRow: dragXMinInRow, dragXMaxInRow: dragXMaxInRow,
                        rowIdx: rowIdx, upperRow: upperRow, lowerRow: lowerRow)
                case .flow:
                    range = flowSelectionRange(
                        slot: slot, ctx: ctx,
                        anchor: anchor, focus: focus, upper: upper, lower: lower,
                        rowIdx: rowIdx, upperRow: upperRow, lowerRow: lowerRow)
                }

                if range.location != NSNotFound, range.length > 0 {
                    applySelection(rowIndex: rowIdx, slot: slot, range: range)
                    nextKeys.insert(SelectionKey(
                        rowStableId: row.stableId, ordering: slot.ordering))
                } else {
                    applySelection(rowIndex: rowIdx, slot: slot,
                                   range: NSRange(location: NSNotFound, length: 0))
                }
            }
            controller.notifyRowSelectionChanged(index: rowIdx)
        }

        for key in lastSelectedKeys where !nextKeys.contains(key) {
            if !visitedRowIdxs.contains(where: {
                controller.rows[$0].stableId == key.rowStableId
            }) {
                controller.notifyRowSelectionCleared(stableId: key.rowStableId)
            }
        }

        lastSelectedKeys = nextKeys
    }

    /// 通用的 selection apply —— 不通过闭包,而是经 `callbacks.applySelection`
    /// 把 range 折进 row state。
    private func applySelection(rowIndex: Int, slot: SelectableSlot, range: NSRange) {
        guard let controller, rowIndex >= 0, rowIndex < controller.rows.count else { return }
        let row = controller.rows[rowIndex]
        let cb = row.callbacks
        let newState = cb.applySelection(row.state, slot.selectionKey, range)
        controller.rows[rowIndex].state = newState
        controller.stickyStates[row.stableId] = newState
    }

    // MARK: - Per-slot rules

    private func cellSelectionRange(
        slot: SelectableSlot,
        ctx: TranscriptController.RowLocalContext,
        upper: CGPoint, lower: CGPoint,
        dragXMinInRow: CGFloat, dragXMaxInRow: CGFloat,
        rowIdx: Int, upperRow: Int, lowerRow: Int
    ) -> NSRange {
        let f = slot.frameInRow
        if f.maxX < dragXMinInRow || f.minX > dragXMaxInRow {
            return NSRange(location: NSNotFound, length: 0)
        }
        let upperInRow = ctx.toRowLocal(upper)
        let lowerInRow = ctx.toRowLocal(lower)
        if rowIdx == upperRow, f.maxY <= upperInRow.y {
            return NSRange(location: NSNotFound, length: 0)
        }
        if rowIdx == lowerRow, f.minY >= lowerInRow.y {
            return NSRange(location: NSNotFound, length: 0)
        }
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
            endY = min(slot.layout.totalHeight, f.height) + 1
        }
        let startLocal = CGPoint(x: 0, y: startY)
        let endLocal = CGPoint(x: slot.layout.measuredWidth, y: endY)
        return slot.layout.selectionRange(from: startLocal, to: endLocal)
    }

    private func flowSelectionRange(
        slot: SelectableSlot,
        ctx: TranscriptController.RowLocalContext,
        anchor: CGPoint, focus: CGPoint, upper: CGPoint, lower: CGPoint,
        rowIdx: Int, upperRow: Int, lowerRow: Int
    ) -> NSRange {
        let regionMinY = slot.frameInRow.minY
        let regionMaxY = slot.frameInRow.maxY

        let upperInRow = ctx.toRowLocal(upper)
        let lowerInRow = ctx.toRowLocal(lower)

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

        if intervalMaxY < regionMinY || intervalMinY > regionMaxY {
            return NSRange(location: NSNotFound, length: 0)
        }

        let upperInsideRegion = rowIdx == upperRow
            && regionMinY <= upperInRow.y && upperInRow.y <= regionMaxY
        let lowerInsideRegion = rowIdx == lowerRow
            && regionMinY <= lowerInRow.y && lowerInRow.y <= regionMaxY

        let startLocal: CGPoint
        let endLocal: CGPoint

        if upperInsideRegion && lowerInsideRegion {
            startLocal = toLocal(anchor, ctx: ctx, slot: slot)
            endLocal = toLocal(focus, ctx: ctx, slot: slot)
        } else {
            startLocal = upperInsideRegion
                ? toLocal(upper, ctx: ctx, slot: slot)
                : .zero
            endLocal = lowerInsideRegion
                ? toLocal(lower, ctx: ctx, slot: slot)
                : regionEnd(slot)
        }

        return slot.layout.selectionRange(from: startLocal, to: endLocal)
    }

    // MARK: - Geometry helpers

    private func toLocal(
        _ docPoint: CGPoint,
        ctx: TranscriptController.RowLocalContext,
        slot: SelectableSlot
    ) -> CGPoint {
        let pointInRow = ctx.toRowLocal(docPoint)
        return CGPoint(
            x: pointInRow.x - slot.frameInRow.origin.x,
            y: pointInRow.y - slot.frameInRow.origin.y)
    }

    private func regionEnd(_ slot: SelectableSlot) -> CGPoint {
        let y = min(slot.layout.totalHeight, slot.frameInRow.height) + 1
        return CGPoint(x: slot.layout.measuredWidth, y: y)
    }

    private func findSlotIndex(for pointInRow: CGPoint, slots: [SelectableSlot]) -> Int {
        for (i, slot) in slots.enumerated() {
            if slot.frameInRow.contains(pointInRow) { return i }
        }
        var bestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, slot) in slots.enumerated() {
            let d = abs(slot.frameInRow.midY - pointInRow.y)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    private func clampedRow(at point: CGPoint, tableView: NSTableView) -> Int {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return -1 }
        let b = tableView.bounds
        guard b.width > 0, b.height > 0 else { return -1 }
        let cx = min(max(point.x, b.minX), b.maxX - 1)
        let cy = min(max(point.y, b.minY), b.maxY - 1)
        let raw = tableView.row(at: CGPoint(x: cx, y: cy))
        if raw >= 0 { return raw }
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

    /// Cmd-C —— 走 `callbacks.selectedFragments(row)`,跨 row 间隔 `\n\n`,
    /// 同 row 内不同 slot 间 `\n`。Selection-controller 自身不再持 substring 缓存,
    /// 直接从最新 row state 读 (避免与 row 异步状态不一致)。
    @objc func copy(_ sender: Any?) {
        guard let controller else { return }
        guard !lastSelectedKeys.isEmpty else { return }

        struct OrderedFragment {
            let rowIndex: Int
            let ordering: SlotOrdering
            let text: String
        }
        var ordered: [OrderedFragment] = []
        for (idx, row) in controller.rows.enumerated() {
            for fragment in row.callbacks.selectedFragments(row) {
                ordered.append(OrderedFragment(
                    rowIndex: idx, ordering: fragment.ordering, text: fragment.text))
            }
        }
        guard !ordered.isEmpty else { return }
        ordered.sort { lhs, rhs in
            if lhs.rowIndex != rhs.rowIndex { return lhs.rowIndex < rhs.rowIndex }
            return lhs.ordering < rhs.ordering
        }

        let out = NSMutableString()
        var prevRowIndex: Int? = nil
        for entry in ordered {
            if let prev = prevRowIndex {
                if prev == entry.rowIndex {
                    out.append("\n")
                } else {
                    out.append("\n\n")
                }
            }
            let cleaned = entry.text.replacingOccurrences(of: "\u{FFFC}", with: "")
            out.append(cleaned)
            prevRowIndex = entry.rowIndex
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: self)
        pb.setString(out as String, forType: .string)
    }
}

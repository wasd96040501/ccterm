import AppKit

/// 鼠标点击 → row-local 坐标 → 派发到 row 自报的 `RowHitRegion`。entry point
/// 由 `TranscriptTableView` 的 mouseDown / mouseMoved 调入。controller 只认
/// `InteractiveRow` 协议，不 `as?` 任何具体 row 类型。
extension TranscriptController {
    // MARK: - Row-local point conversion

    struct RowLocalContext {
        let rowIndex: Int
        let rowRect: CGRect
        let inset: CGFloat

        func toRowLocal(_ documentPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: documentPoint.x - rowRect.origin.x - inset,
                y: documentPoint.y - rowRect.origin.y)
        }
    }

    func rowLocalContext(at documentPoint: CGPoint) -> RowLocalContext? {
        guard let tableView else { return nil }
        return rowLocalContext(forRow: tableView.row(at: documentPoint))
    }

    func rowLocalContext(forRow rowIndex: Int) -> RowLocalContext? {
        guard let tableView, rowIndex >= 0, rowIndex < rows.count else { return nil }
        let rowRect = tableView.rect(ofRow: rowIndex)
        let inset = contentInset(forRow: rowIndex, rowRect: rowRect)
        return RowLocalContext(rowIndex: rowIndex, rowRect: rowRect, inset: inset)
    }

    // MARK: - Link hit-test

    func linkURL(atDocumentPoint documentPoint: CGPoint) -> URL? {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        guard let selectable = rows[ctx.rowIndex] as? TextSelectable else { return nil }
        let regions = selectable.selectableRegions
        guard !regions.isEmpty else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)

        for region in regions where region.frameInRow.contains(pointInRow) {
            let local = CGPoint(
                x: pointInRow.x - region.frameInRow.origin.x,
                y: pointInRow.y - region.frameInRow.origin.y)
            guard let ci = region.layout.characterIndex(at: local) else { continue }
            let attr = region.layout.attributed
            let idx = max(0, min(Int(ci), attr.length - 1))
            guard idx >= 0, idx < attr.length else { continue }
            let value = attr.attribute(.link, at: idx, effectiveRange: nil)
            if let url = value as? URL { return url }
            if let s = value as? String, let url = URL(string: s) { return url }
        }
        return nil
    }

    // MARK: - Interactive hit regions (protocol-dispatched)

    /// 通用命中查询：遍历 row 自报的 `hitRegions`，返回命中的 region。
    /// 命中遍历顺序按 row 内部声明；`InteractiveRow.hitRegions` 的 getter 自己
    /// 决定是否要逆序（通常后画的在上）。
    private func hitRegion(atDocumentPoint documentPoint: CGPoint)
        -> (region: RowHitRegion, rowIndex: Int)?
    {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        guard let interactive = rows[ctx.rowIndex] as? InteractiveRow else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)
        for region in interactive.hitRegions where region.rectInRow.contains(pointInRow) {
            return (region, ctx.rowIndex)
        }
        return nil
    }

    /// 返回命中 region 的 cursor——`TranscriptTableView.checkCursor` 读这个决定
    /// hover 时设 pointingHand / iBeam / arrow。
    func cursorOverHit(atDocumentPoint documentPoint: CGPoint) -> NSCursor? {
        hitRegion(atDocumentPoint: documentPoint)?.region.cursor
    }

    /// 点击分派。命中 → 调 region 的 perform 闭包（row 自己决定剪贴板 / toggle
    /// / redraw 等副作用）→ 返回 true。未命中 → false，调用方继续往下 fallthrough
    /// 到 link / selection。
    func performHit(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let hit = hitRegion(atDocumentPoint: documentPoint) else { return false }
        hit.region.perform(self)
        return true
    }

    /// 单行重绘。命中 region 的 perform 闭包可能要求只刷新自己这一行
    /// （如 code block copy 的 checkmark 反馈）。
    func redrawRow(at index: Int) {
        guard let tableView else { return }
        guard index >= 0, index < rows.count else { return }
        guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            as? TranscriptRowView else { return }
        rowView.set(row: rows[index])
    }
}

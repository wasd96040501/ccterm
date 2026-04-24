import AppKit

/// 鼠标点击 → row-local 坐标 → 派发到 row 的 component callbacks。
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
        let row = rows[ctx.rowIndex]
        let slots = row.callbacks.selectables(row)
        guard !slots.isEmpty else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)

        for slot in slots where slot.frameInRow.contains(pointInRow) {
            let local = CGPoint(
                x: pointInRow.x - slot.frameInRow.origin.x,
                y: pointInRow.y - slot.frameInRow.origin.y)
            guard let ci = slot.layout.characterIndex(at: local) else { continue }
            let attr = slot.layout.attributed
            let idx = max(0, min(Int(ci), attr.length - 1))
            guard idx >= 0, idx < attr.length else { continue }
            let value = attr.attribute(.link, at: idx, effectiveRange: nil)
            if let url = value as? URL { return url }
            if let s = value as? String, let url = URL(string: s) { return url }
        }
        return nil
    }

    // MARK: - Interactive hit (callbacks-dispatched)

    private func hitInteraction(atDocumentPoint documentPoint: CGPoint)
        -> (interaction: AnyInteraction, rowIndex: Int)?
    {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        let row = rows[ctx.rowIndex]
        let interactions = row.callbacks.interactions(row)
        let pointInRow = ctx.toRowLocal(documentPoint)
        for interaction in interactions where interaction.rect.contains(pointInRow) {
            return (interaction, ctx.rowIndex)
        }
        return nil
    }

    func cursorOverHit(atDocumentPoint documentPoint: CGPoint) -> NSCursor? {
        hitInteraction(atDocumentPoint: documentPoint)?.interaction.cursor
    }

    /// 命中 → 按 interaction kind 调框架标准副作用。返回 true = 已消化点击。
    func performHit(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let hit = hitInteraction(atDocumentPoint: documentPoint) else { return false }
        let stableId = rows[hit.rowIndex].stableId
        switch hit.interaction.kind {
        case .invoke(let handler):
            let anyCtx = makeRowContext(stableId: stableId)
            handler(anyCtx)
        case .copy(let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            selectionController.clear()
            redrawAllVisibleRows()
        case .openURL(let url):
            selectionController.clear()
            redrawAllVisibleRows()
            NSWorkspace.shared.open(url)
        }
        return true
    }

    func redrawRow(at index: Int) {
        guard let tableView else { return }
        guard index >= 0, index < rows.count else { return }
        guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            as? TranscriptRowView else { return }
        rowView.set(row: rows[index])
    }
}

import AppKit

/// 鼠标点击 → row-local 坐标 → 派发到具体可交互区域(link / code block copy /
/// user bubble chevron)。entry point 由 `TranscriptTableView` 的 mouseDown /
/// mouseMoved 调入,返回 bool 让 table view 决定是否 fallthrough 给 selection
/// controller。
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

    // MARK: - Code block click-to-copy

    func codeBlockHit(atDocumentPoint documentPoint: CGPoint) -> Bool {
        return resolveCodeBlockHit(atDocumentPoint: documentPoint) != nil
    }

    func performCodeBlockCopy(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let resolved = resolveCodeBlockHit(atDocumentPoint: documentPoint) else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resolved.hit.code, forType: .string)
        let rowIndex = resolved.rowIndex
        resolved.row.markCodeBlockCopied(
            segmentIndex: resolved.hit.segmentIndex
        ) { [weak self] in
            self?.redrawRow(at: rowIndex)
        }
        return true
    }

    fileprivate struct CodeBlockResolved {
        let row: AssistantMarkdownRow
        let rowIndex: Int
        let hit: AssistantMarkdownRow.CodeBlockHitInfo
    }

    fileprivate func resolveCodeBlockHit(atDocumentPoint documentPoint: CGPoint)
        -> CodeBlockResolved?
    {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        guard let row = rows[ctx.rowIndex] as? AssistantMarkdownRow else { return nil }
        let pointInRow = ctx.toRowLocal(documentPoint)
        guard let hit = row.codeBlockHit(atRowPoint: pointInRow) else { return nil }
        return CodeBlockResolved(row: row, rowIndex: ctx.rowIndex, hit: hit)
    }

    fileprivate func redrawRow(at index: Int) {
        guard let tableView else { return }
        guard index >= 0, index < rows.count else { return }
        guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            as? TranscriptRowView else { return }
        rowView.set(row: rows[index])
    }

    // MARK: - User bubble collapse toggle

    func isOverUserBubbleChevron(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard let ctx = rowLocalContext(at: documentPoint) else { return false }
        guard let row = rows[ctx.rowIndex] as? UserBubbleRow else { return false }
        let pointInRow = ctx.toRowLocal(documentPoint)
        return row.chevronHitRectInRow()?.contains(pointInRow) == true
    }

    func toggleUserBubble(atDocumentPoint documentPoint: CGPoint) -> Bool {
        guard lastLayoutWidth > 0 else { return false }
        guard let ctx = rowLocalContext(at: documentPoint) else { return false }
        guard let row = rows[ctx.rowIndex] as? UserBubbleRow else { return false }
        let pointInRow = ctx.toRowLocal(documentPoint)
        guard let hit = row.chevronHitRectInRow(), hit.contains(pointInRow) else {
            return false
        }

        let id = row.stableId
        if expandedUserBubbles.contains(id) {
            expandedUserBubbles.remove(id)
            row.isExpanded = false
        } else {
            expandedUserBubbles.insert(id)
            row.isExpanded = true
        }
        row.makeSize(width: lastLayoutWidth)
        noteHeightOfRow(ctx.rowIndex)
        return true
    }
}

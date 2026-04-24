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
        guard let ctx = rowLocalContext(at: documentPoint) else {
            appLog(.debug, "TranscriptHit",
                "hit doc=\(documentPoint) rowCtx=nil(rowIndex<0 or tableView nil)")
            return nil
        }
        let row = rows[ctx.rowIndex]
        let interactions = row.callbacks.interactions(row)
        let pointInRow = ctx.toRowLocal(documentPoint)
        let rectsDump = interactions.map { r in
            "[\(r.rect.origin.x),\(r.rect.origin.y),\(r.rect.size.width),\(r.rect.size.height)]\(r.rect.contains(pointInRow) ? "✓" : "✗")"
        }.joined(separator: " ")
        appLog(.debug, "TranscriptHit",
            "hit doc=\(documentPoint) row=\(ctx.rowIndex) rowRect=\(ctx.rowRect) inset=\(ctx.inset) pointInRow=\(pointInRow) tag=\(row.callbacks.tag) nInter=\(interactions.count) rects=\(rectsDump)")
        for interaction in interactions where interaction.rect.contains(pointInRow) {
            return (interaction, ctx.rowIndex)
        }
        return nil
    }

    func cursorOverHit(atDocumentPoint documentPoint: CGPoint) -> NSCursor? {
        hitInteraction(atDocumentPoint: documentPoint)?.interaction.cursor
    }

    /// 命中 → 按 interaction kind 调框架标准副作用。返回 true = 已消化点击。
    /// `.hover` 不算点击命中,这里跳过(让 mouseUp 继续 drag-select 等)。
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
        case .hover:
            return false
        }
        return true
    }

    // MARK: - Hover dispatch

    /// 跟踪当前鼠标悬停到的 (stableId, rect) —— 跨帧比较触发 onEnter / onExit。
    /// 采用 struct key,避免 row 被 diff 掉后 stableId 还残留。
    struct HoverKey: Equatable {
        let stableId: StableId
        /// 用 rect 的 (x, y, w, h) 做二级 key —— 同 row 多 hover 区时分开跟。
        let rx: CGFloat
        let ry: CGFloat
        let rw: CGFloat
        let rh: CGFloat

        init(stableId: StableId, rect: CGRect) {
            self.stableId = stableId
            self.rx = rect.origin.x
            self.ry = rect.origin.y
            self.rw = rect.size.width
            self.rh = rect.size.height
        }
    }

    /// `TranscriptTableView.mouseMoved` / `mouseExited` 调入。分派 hover enter/exit。
    /// 传 `nil` 代表鼠标离开 tableView,强制 exit 当前 hover。
    func updateHover(atDocumentPoint documentPoint: CGPoint?) {
        let found: HoverLookup?
        if let p = documentPoint {
            found = findHoverAt(documentPoint: p)
        } else {
            found = nil
        }

        let newKey = found.map { HoverKey(stableId: $0.rowStableId, rect: $0.rect) }
        if currentHover?.key == newKey { return }

        // Exit previous.
        if let prev = currentHover {
            let ctx = makeRowContext(stableId: prev.key.stableId)
            prev.exitHandler(ctx)
        }
        // Enter new.
        if let hit = found, let key = newKey {
            let ctx = makeRowContext(stableId: hit.rowStableId)
            hit.enterHandler(ctx)
            currentHover = (key: key, exitHandler: hit.exitHandler)
        } else {
            currentHover = nil
        }
    }

    struct HoverLookup {
        let rowStableId: StableId
        let rect: CGRect
        let enterHandler: @MainActor @Sendable (AnyRowContext) -> Void
        let exitHandler: @MainActor @Sendable (AnyRowContext) -> Void
    }

    private func findHoverAt(documentPoint: CGPoint) -> HoverLookup? {
        guard let ctx = rowLocalContext(at: documentPoint) else { return nil }
        let row = rows[ctx.rowIndex]
        let interactions = row.callbacks.interactions(row)
        let pointInRow = ctx.toRowLocal(documentPoint)
        for interaction in interactions where interaction.rect.contains(pointInRow) {
            if case let .hover(onEnter, onExit) = interaction.kind {
                return HoverLookup(
                    rowStableId: row.stableId,
                    rect: interaction.rect,
                    enterHandler: onEnter,
                    exitHandler: onExit)
            }
        }
        return nil
    }

    func redrawRow(at index: Int) {
        guard let tableView else { return }
        guard index >= 0, index < rows.count else { return }
        guard let rowView = tableView.rowView(atRow: index, makeIfNecessary: false)
            as? TranscriptRowView else { return }
        rowView.set(row: rows[index])
    }
}

import AppKit

/// `TranscriptUpdateTransition` → NSTableView 原子应用。
///
/// `merge(with:scroll:)` 被 Pipeline runner 们调用做 diff 应用 + scroll 对齐,
/// 原子一帧。同文件的 `computeTargetClipY` / `applyScrollIntent` /
/// `logVisualSnapshot` / `rowsMatchFinal` / `reindexAllRows` 都是内部工具。
extension TranscriptController {
    // MARK: - merge

    /// 把 transition 应用到 tableView——**原子一帧**。主线程。
    ///
    /// 核心守则:`tableH` 变更(insertRows / removeRows)和 `clipY` 变更
    /// (setBoundsOrigin)必须在**同一个**屏幕刷新周期内完成。否则用户会看到
    /// "新 tableH + 旧 clipY" 的中间帧——例如 prepend 79 行后 tableH 从 1404
    /// 变 47991,但 clipY 还是 451,视口瞬间从"文档末尾的 tail" 变成"文档开头
    /// 的 prefix",下一帧 scroll apply 才跳回贴底。用户感知为跳变。
    ///
    /// 策略:
    /// 1. **precompute** `targetClipY` —— 遍历 `transition.finalRows` 的
    ///    `cachedHeight` 算出最终 clipY,**不**依赖 AppKit 的任何 query
    ///    (`rect(ofRow:)` 在 updates 期间返回陈旧值)
    /// 2. **CATransaction 裹整体** —— `setDisableActions(true)` 禁隐式动画,
    ///    内层 beginUpdates / insertRows / setBoundsOrigin / endUpdates 合并
    ///    到一次 commit,屏幕只刷一帧终态
    /// 3. `applyScrollIntent` 仅在 short-circuit 路径(无 row 变化、纯 scroll)
    ///    调用;正常 merge 路径直接在事务内 setBoundsOrigin,不走它
    func merge(
        with transition: TranscriptUpdateTransition,
        scroll: TranscriptScrollIntent
    ) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }

        // Short-circuit: rows identical → just apply scroll (nothing to batch).
        if transition.isEmpty, rows.count == transition.finalRows.count,
           zip(rows, transition.finalRows).allSatisfy({ $0 === $1 }) {
            applyScrollIntent(scroll)
            return
        }

        let anim: NSTableView.AnimationOptions = transition.animated ? .effectFade : []
        if !transition.animated {
            NSAnimationContext.current.duration = 0
        }

        // Precompute target clipY from finalRows (cachedHeight already populated
        // by caller via makeSize(width:)). Done BEFORE mutating tableView so
        // we never query mid-transition geometry.
        let clipH = clip.bounds.height
        let currentClipY = clip.bounds.minY
        let targetClipY = computeTargetClipY(
            scroll: scroll,
            finalRows: transition.finalRows,
            clipHeight: clipH,
            currentClipY: currentClipY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        tableView.beginUpdates()

        if !transition.deleted.isEmpty {
            let desc = transition.deleted.sorted(by: >)
            for idx in desc where idx >= 0 && idx < rows.count {
                let row = rows[idx]
                row.table = nil
                row.index = -1
            }
            for idx in desc where idx >= 0 && idx < rows.count {
                rows.remove(at: idx)
            }
            tableView.removeRows(at: IndexSet(desc), withAnimation: anim)
        }

        if !transition.inserted.isEmpty {
            var insertedIndexes = IndexSet()
            for (i, row) in transition.inserted {
                let insertAt = min(i, rows.count)
                rows.insert(row, at: insertAt)
                insertedIndexes.insert(insertAt)
            }
            tableView.insertRows(at: insertedIndexes, withAnimation: anim)
        }

        if !transition.updated.isEmpty {
            for (i, row) in transition.updated where i >= 0 && i < rows.count {
                rows[i] = row
            }
        }

        if !rowsMatchFinal(transition.finalRows) {
            appLog(.warning, "TranscriptController",
                "merge: rows drifted from finalRows (rows=\(rows.count) final=\(transition.finalRows.count)); overriding")
            rows = transition.finalRows
        }

        reindexAllRows()
        tableView.endUpdates()

        // Apply scroll inside the same CATransaction so CA coalesces tableH
        // update + clipY update into a single commit. The user never sees
        // "new tableH + old clipY" or any animated interpolation.
        if let targetClipY, abs(targetClipY - clip.bounds.minY) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: targetClipY))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        for (i, _) in transition.updated where i >= 0 && i < rows.count {
            reloadRowView(at: i, animated: transition.animated)
        }

        CATransaction.commit()

        // Log post-commit state (serves the same role as the old
        // `[scroll] .anchor ... [ok/clamp]` line, but works for every intent).
        appLog(.info, "TranscriptController",
            "[scroll] \(scroll.logTag) targetClipY=\(targetClipY.map { String(format: "%.1f", $0) } ?? "nil") "
            + "clipY=\(Int(currentClipY))→\(Int(clip.bounds.minY)) "
            + "tableH=\(Int(tableView.bounds.height)) clipH=\(Int(clipH)) "
            + "rows=\(rows.count)")
    }

    /// Algebraic resolution of `scroll` against `finalRows` — no AppKit query.
    /// Returns the clipY that, once applied, satisfies the intent against the
    /// **final** table geometry (not the intermediate mid-merge one).
    ///
    /// `nil` means "leave clipY alone" (`.preserve` or unresolvable `.anchor`).
    fileprivate func computeTargetClipY(
        scroll: TranscriptScrollIntent,
        finalRows: [TranscriptRow],
        clipHeight: CGFloat,
        currentClipY: CGFloat
    ) -> CGFloat? {
        let totalH = finalRows.reduce(CGFloat(0)) { $0 + $1.cachedHeight }
        let maxY = max(0, totalH - clipHeight)

        switch scroll {
        case .preserve:
            // Still clamp — rows may have shrunk below current clipY.
            return max(0, min(currentClipY, maxY))

        case .bottom:
            return maxY

        case .anchor(let stableId, let topOffset):
            var y: CGFloat = 0
            for row in finalRows {
                if row.stableId == stableId {
                    let want = y - topOffset
                    return max(0, min(want, maxY))
                }
                y += row.cachedHeight
            }
            appLog(.warning, "TranscriptController",
                "[scroll] .anchor stableId not found in finalRows (\(finalRows.count) rows)")
            return nil
        }
    }

    /// 依据 intent 设置 clipView origin。在 `endUpdates` 之后调用——此时 rows
    /// 与 tableView geometry 都已落定，`rect(ofRow:)` 是最新值。
    fileprivate func applyScrollIntent(_ intent: TranscriptScrollIntent) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }
        switch intent {
        case .preserve:
            return
        case .bottom:
            let maxY = max(0, tableView.bounds.height - clip.bounds.height)
            guard abs(maxY - clip.bounds.minY) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: maxY))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        case let .anchor(stableId, topOffset):
            guard let idx = rows.firstIndex(where: { $0.stableId == stableId }) else {
                appLog(.warning, "TranscriptController",
                    "[scroll] .anchor stableId not found in rows (\(rows.count) rows)")
                return
            }
            let newRect = tableView.rect(ofRow: idx)
            let newY = newRect.minY - topOffset
            let maxY = max(0, tableView.bounds.height - clip.bounds.height)
            let clamped = max(0, min(newY, maxY))
            let clampTag: String
            if newY < 0 { clampTag = "clamp→0(over \(String(format: "%.1f", -newY))pt)" }
            else if newY > maxY { clampTag = "clamp→maxY(over \(String(format: "%.1f", newY - maxY))pt)" }
            else { clampTag = "ok" }
            appLog(.info, "TranscriptController",
                "[scroll] .anchor idx=\(idx) rowY=\(Int(newRect.minY)) "
                + "topOffset=\(String(format: "%.1f", topOffset)) "
                + "newY=\(String(format: "%.1f", newY)) maxY=\(Int(maxY)) "
                + "clipY=\(Int(clip.bounds.minY))→\(String(format: "%.1f", clamped)) "
                + "tableH=\(Int(tableView.bounds.height)) "
                + "clipH=\(Int(clip.bounds.height)) [\(clampTag)]")
            guard abs(clamped - clip.bounds.minY) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clamped))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Diagnostic snapshot of the current scroll state vs. what an anchor
    /// target implies. Written at the four critical points of
    /// `runViewportFirstAroundAnchor` so we can tell **which step introduces
    /// drift**:
    /// - `phase1-merged`: 第一帧是否已对齐 `(stableId, topOffset)`
    /// - `phase2-post-backfill`: highlight 回灌 + noteHeightOfRows 是否扰动了
    ///   clipY / anchor rowY 的相对关系
    /// - `phase2-merged`: Phase 2 前插 + re-anchor 后是否仍对齐
    /// Δ = actualTopOffset - expectedTopOffset; >1pt 代表视觉已错位。
    func logVisualSnapshot(
        tag: String,
        expectedAnchorStableId: AnyHashable?,
        expectedTopOffset: CGFloat?
    ) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else {
            appLog(.info, "TranscriptController",
                "[snap] \(tag): no tableView/clipView")
            return
        }
        let tableH = tableView.bounds.height
        let clipH = clip.bounds.height
        let clipY = clip.bounds.minY
        let maxY = max(0, tableH - clipH)

        var anchorInfo = "anchor=none"
        if let stableId = expectedAnchorStableId,
           let idx = rows.firstIndex(where: { $0.stableId == stableId })
        {
            let rect = tableView.rect(ofRow: idx)
            let actual = rect.minY - clipY
            let expected = expectedTopOffset ?? 0
            let delta = actual - expected
            anchorInfo = "anchorIdx=\(idx) rowY=\(Int(rect.minY)) "
                + "actualTopOffset=\(String(format: "%.1f", actual)) "
                + "expected=\(String(format: "%.1f", expected)) "
                + "Δ=\(String(format: "%.2f", delta))pt"
        } else if expectedAnchorStableId != nil {
            anchorInfo = "anchor=stableId-not-in-rows"
        }

        appLog(.info, "TranscriptController",
            "[snap] \(tag) clipY=\(Int(clipY)) maxY=\(Int(maxY)) "
            + "tableH=\(Int(tableH)) clipH=\(Int(clipH)) "
            + "rows=\(rows.count) \(anchorInfo)")
    }

    fileprivate func rowsMatchFinal(_ final: [TranscriptRow]) -> Bool {
        guard rows.count == final.count else { return false }
        for i in 0..<rows.count where rows[i] !== final[i] { return false }
        return true
    }

    fileprivate func reindexAllRows() {
        for (i, row) in rows.enumerated() {
            row.table = self
            row.index = i
        }
    }
}

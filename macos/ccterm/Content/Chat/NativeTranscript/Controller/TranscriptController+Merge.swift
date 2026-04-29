import AppKit

/// `TranscriptUpdateTransition` → NSTableView 原子应用。
extension TranscriptController {
    // MARK: - merge

    func merge(
        with transition: TranscriptUpdateTransition,
        scroll: TranscriptScrollIntent
    ) {
        guard let tableView,
              let clip = tableView.enclosingScrollView?.contentView else { return }

        // Short-circuit: rows identical → just apply scroll.
        if transition.isEmpty, rows.count == transition.finalRows.count,
           zip(rows, transition.finalRows).allSatisfy({ $0.stableId == $1.stableId }) {
            applyScrollIntent(scroll)
            return
        }

        let anim: NSTableView.AnimationOptions = transition.animated ? .effectFade : []
        if !transition.animated {
            NSAnimationContext.current.duration = 0
        }

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

        tableView.endUpdates()

        if let targetClipY, abs(targetClipY - clip.bounds.minY) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: targetClipY))
            tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        for (i, _) in transition.updated where i >= 0 && i < rows.count {
            reloadRowView(at: i, animated: transition.animated)
        }

        CATransaction.commit()

        appLog(.info, "TranscriptController",
            "[scroll] \(scroll.logTag) targetClipY=\(targetClipY.map { String(format: "%.1f", $0) } ?? "nil") "
            + "clipY=\(Int(currentClipY))→\(Int(clip.bounds.minY)) "
            + "tableH=\(Int(tableView.bounds.height)) clipH=\(Int(clipH)) "
            + "rows=\(rows.count)")
    }

    fileprivate func computeTargetClipY(
        scroll: TranscriptScrollIntent,
        finalRows: [ComponentRow],
        clipHeight: CGFloat,
        currentClipY: CGFloat
    ) -> CGFloat? {
        let totalH = finalRows.reduce(CGFloat(0)) { $0 + $1.cachedSize.height }
        let maxY = max(0, totalH - clipHeight)

        switch scroll {
        case .preserve:
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
                y += row.cachedSize.height
            }
            appLog(.warning, "TranscriptController",
                "[scroll] .anchor stableId not found in finalRows (\(finalRows.count) rows)")
            return nil
        }
    }

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

    func logVisualSnapshot(
        tag: String,
        expectedAnchorStableId: StableId?,
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

    fileprivate func rowsMatchFinal(_ final: [ComponentRow]) -> Bool {
        guard rows.count == final.count else { return false }
        for i in 0..<rows.count where rows[i].stableId != final[i].stableId { return false }
        return true
    }
}

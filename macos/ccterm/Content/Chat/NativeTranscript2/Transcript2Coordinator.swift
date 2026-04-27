import AppKit

/// `NSTableViewDataSource` + `NSTableViewDelegate` for the transcript table.
///
/// Three rebuild pipelines, all funneling through the same `[RowItem]` state:
///
/// - **`rebuildAll` (sync, MainActor)** — triggered by `setBlocks`. Full
///   pass over `currentBlocks`; reuses rows by `id+width`; applies a
///   granular diff (insert/remove/reload).
/// - **`rebuildVisible` (sync, MainActor)** — triggered every frame during
///   live resize via `tableFrameDidChange`. Only re-lays-out rows currently
///   on screen; off-screen rows keep their pre-resize (stale) layout so
///   per-frame work stays bounded regardless of total transcript length.
/// - **`rebuildAllInBackground` (detached task)** — triggered by
///   `Transcript2TableView.viewDidEndLiveResize`. Computes the full pass on
///   a background actor (`TextLayout` / `ImageLayout` / `RowItem` are all
///   `Sendable`), then hops back to main and applies. Result is discarded
///   if width drifted again or blocks changed mid-flight.
///
/// While off-screen rows have stale heights the total content height is
/// briefly wrong, but the overlay scroll bar (forced in
/// `Transcript2ScrollView`) stays hidden during live resize so the
/// inconsistency is invisible.
@MainActor
final class Transcript2Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?

    private(set) var rows: [RowItem] = []
    private var currentBlocks: [Block] = []

    /// In-flight background relayout. Cancelled on next resize or on
    /// `setBlocks` (its result would apply against the wrong row set).
    private var fullRelayoutTask: Task<Void, Never>?

    // MARK: - Triggers

    func setBlocks(_ blocks: [Block]) {
        fullRelayoutTask?.cancel()
        fullRelayoutTask = nil
        currentBlocks = blocks
        rebuildAll()
    }

    @objc func tableFrameDidChange(_ note: Notification) {
        // Visible-only relayout is the live-resize fast path: bounded
        // per-frame work, off-screen rows stay stale until
        // `viewDidEndLiveResize` triggers `rebuildAllInBackground`.
        // Programmatic frame changes (initial layout, SwiftUI re-layout,
        // window animations) must go through the full path — there is no
        // "end" event to correct stale off-screen rows afterwards.
        if tableView?.inLiveResize == true {
            rebuildVisible()
        } else {
            rebuildAll()
        }
    }

    func rebuildAllInBackground() {
        guard let tableView else { return }
        let width = effectiveContentWidth(of: tableView)
        guard width > 0 else { return }
        if rows.allSatisfy({ $0.layout.measuredWidth == width }) { return }

        fullRelayoutTask?.cancel()
        let snapshot = currentBlocks
        fullRelayoutTask = Task.detached(priority: .userInitiated) { [weak self] in
            var next: [RowItem] = []
            next.reserveCapacity(snapshot.count)
            for block in snapshot {
                if Task.isCancelled { return }
                next.append(Self.makeRowItem(for: block, width: width))
            }
            if Task.isCancelled { return }
            await MainActor.run { [next] in
                self?.applyBackgroundRelayout(next, width: width)
            }
        }
    }

    // MARK: - Pipelines

    private func rebuildAll() {
        guard let tableView else { return }
        let width = effectiveContentWidth(of: tableView)
        guard width > 0 else { return }

        let oldById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var next: [RowItem] = []
        next.reserveCapacity(currentBlocks.count)
        for block in currentBlocks {
            if let old = oldById[block.id],
               old.block == block,
               old.layout.measuredWidth == width
            {
                next.append(old)
            } else {
                next.append(Self.makeRowItem(for: block, width: width))
            }
        }

        // Update the data source FIRST. NSTableView may query
        // numberOfRows / heightOfRow synchronously inside endUpdates(); if
        // self.rows is still the old array at that point, NSTableView caches
        // wrong heights and the layout glitches (huge visual gaps).
        let old = rows
        rows = next
        applyDiff(old: old, new: next, in: tableView)
    }

    private func rebuildVisible() {
        guard let tableView else { return }
        let width = effectiveContentWidth(of: tableView)
        guard width > 0 else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else {
            // No rows visible yet (first layout pass) — fall back to full.
            rebuildAll()
            return
        }

        var changed = IndexSet()
        for i in range.location ..< range.location + range.length {
            guard rows.indices.contains(i) else { continue }
            let cur = rows[i]
            if cur.layout.measuredWidth == width { continue }
            rows[i] = Self.makeRowItem(for: cur.block, width: width)
            changed.insert(i)
        }
        guard !changed.isEmpty else { return }

        tableView.beginUpdates()
        tableView.reloadData(forRowIndexes: changed,
                             columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: changed)
        tableView.endUpdates()
    }

    private func applyBackgroundRelayout(_ next: [RowItem], width: CGFloat) {
        guard let tableView else { return }
        // Width drifted again before completion — discard.
        guard effectiveContentWidth(of: tableView) == width else { return }
        // Block set diverged (a setBlocks landed in flight) — discard;
        // setBlocks has already rebuilt against the new data.
        guard rows.count == next.count else { return }
        for i in 0 ..< rows.count where rows[i].id != next[i].id { return }

        var changed = IndexSet()
        for i in 0 ..< rows.count {
            if rows[i].layout.measuredWidth != next[i].layout.measuredWidth {
                changed.insert(i)
            }
        }
        rows = next
        guard !changed.isEmpty else { return }

        tableView.beginUpdates()
        tableView.reloadData(forRowIndexes: changed,
                             columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: changed)
        tableView.endUpdates()
    }

    /// Pure: builds a `RowItem` for `(block, width)`. `nonisolated static`
    /// so the background relayout task can call it off-MainActor.
    /// `TextLayout` / `ImageLayout` are both `Sendable`.
    nonisolated private static func makeRowItem(for block: Block, width: CGFloat) -> RowItem {
        let contentWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
        let layout: RowLayout
        switch block.kind {
        case .heading(let text):
            layout = .text(TextLayout.make(
                attributed: BlockStyle.headingAttributed(text),
                maxWidth: contentWidth))
        case .paragraph(let text):
            layout = .text(TextLayout.make(
                attributed: BlockStyle.paragraphAttributed(text),
                maxWidth: contentWidth))
        case .image(let image):
            layout = .image(ImageLayout.make(
                image: image,
                maxWidth: contentWidth,
                maxHeight: BlockStyle.imageMaxHeight))
        }
        return RowItem(id: block.id, block: block, layout: layout)
    }

    // MARK: - Diff

    private func applyDiff(old: [RowItem], new: [RowItem], in tableView: NSTableView) {
        let oldIds = old.map(\.id)
        let newIds = new.map(\.id)

        let oldById = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var contentChanged = IndexSet()
        for (newIdx, item) in new.enumerated() {
            guard let prev = oldById[item.id] else { continue }
            if prev.block != item.block
                || prev.layout.measuredWidth != item.layout.measuredWidth
            {
                contentChanged.insert(newIdx)
            }
        }

        let diff = newIds.difference(from: oldIds)

        tableView.beginUpdates()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                tableView.removeRows(at: IndexSet(integer: offset),
                                     withAnimation: [.effectFade])
            case .insert(let offset, _, _):
                tableView.insertRows(at: IndexSet(integer: offset),
                                     withAnimation: [.effectFade])
            }
        }
        if !contentChanged.isEmpty {
            tableView.reloadData(forRowIndexes: contentChanged,
                                 columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: contentChanged)
        }
        tableView.endUpdates()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        return rows[row].layout.totalHeight + 2 * BlockStyle.blockVerticalPadding
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("BlockCell")
        let cell: BlockCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? BlockCellView {
            cell = reused
        } else {
            cell = BlockCellView()
            cell.identifier = id
        }
        cell.item = rows[row]
        return cell
    }

    // MARK: - Helpers

    private func effectiveContentWidth(of tableView: NSTableView) -> CGFloat {
        // The single column has `.autoresizingMask` so NSTableView keeps its
        // width in sync with available space.
        tableView.tableColumns.first?.width ?? 0
    }
}

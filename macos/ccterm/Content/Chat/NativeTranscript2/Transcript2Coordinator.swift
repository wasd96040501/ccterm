import AppKit

/// `NSTableViewDataSource` + `NSTableViewDelegate` for the transcript table.
///
/// Owns `[RowItem]` (rows, with their layout) and `currentBlocks` (latest
/// data from SwiftUI). Both `setBlocks(_:)` and the `frameDidChange`
/// notification feed into a single `rebuild()` that re-runs layout against
/// the current width and applies a granular diff to the table.
@MainActor
final class Transcript2Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?

    private(set) var rows: [RowItem] = []
    private var currentBlocks: [Block] = []

    // MARK: - Triggers

    func setBlocks(_ blocks: [Block]) {
        currentBlocks = blocks
        rebuild()
    }

    @objc func tableFrameDidChange(_ note: Notification) {
        rebuild()
    }

    private func rebuild() {
        guard let tableView else { return }
        let width = effectiveContentWidth(of: tableView)
        guard width > 0 else { return }
        applyNewBlocks(currentBlocks, width: width, in: tableView)
    }

    // MARK: - Layout pipeline

    private func applyNewBlocks(_ blocks: [Block], width: CGFloat, in tableView: NSTableView) {
        let oldById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var next: [RowItem] = []
        next.reserveCapacity(blocks.count)
        for block in blocks {
            if let old = oldById[block.id],
               old.block == block,
               old.layout.measuredWidth == width
            {
                next.append(old)
            } else {
                next.append(makeRowItem(for: block, width: width))
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

    private func makeRowItem(for block: Block, width: CGFloat) -> RowItem {
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

        // ids present in both arrays — detect content / width changes.
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

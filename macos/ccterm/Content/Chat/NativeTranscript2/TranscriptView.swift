import AppKit
import SwiftUI

// MARK: - SwiftUI bridge

struct NativeTranscript2View: NSViewRepresentable {
    let blocks: [Block]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        // Receive frame change notifications to re-layout when width changes.
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        context.coordinator.tableView = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setBlocks(blocks)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

// MARK: - Coordinator (dataSource + delegate + diff)

extension NativeTranscript2View {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?

        /// Source of truth for rows. RowItem holds its own layout — recomputed
        /// only when block content or width changes.
        private(set) var rows: [RowItem] = []
        private var pendingBlocks: [Block]?

        struct RowItem: Equatable {
            let id: UUID
            let block: Block
            let layout: TextLayout

            static func == (lhs: RowItem, rhs: RowItem) -> Bool {
                lhs.id == rhs.id && lhs.block == rhs.block
                    && lhs.layout.measuredWidth == rhs.layout.measuredWidth
            }
        }

        // MARK: - Public entry from updateNSView

        func setBlocks(_ blocks: [Block]) {
            guard let tableView else { pendingBlocks = blocks; return }
            let width = effectiveContentWidth(of: tableView)
            guard width > 0 else { pendingBlocks = blocks; return }
            pendingBlocks = nil
            applyNewBlocks(blocks, width: width, in: tableView)
        }

        @objc func tableFrameDidChange(_ note: Notification) {
            guard let tableView else { return }
            let width = effectiveContentWidth(of: tableView)
            guard width > 0 else { return }

            if let pending = pendingBlocks {
                pendingBlocks = nil
                applyNewBlocks(pending, width: width, in: tableView)
                return
            }

            // Width changed → re-layout existing rows (no structural change).
            relayoutAllRows(width: width, in: tableView)
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
            applyDiff(old: rows, new: next, in: tableView)
            rows = next
        }

        private func relayoutAllRows(width: CGFloat, in tableView: NSTableView) {
            var changed = IndexSet()
            for i in rows.indices where rows[i].layout.measuredWidth != width {
                rows[i] = makeRowItem(for: rows[i].block, width: width)
                changed.insert(i)
            }
            guard !changed.isEmpty else { return }
            tableView.beginUpdates()
            tableView.noteHeightOfRows(withIndexesChanged: changed)
            tableView.reloadData(forRowIndexes: changed,
                                 columnIndexes: IndexSet(integer: 0))
            tableView.endUpdates()
        }

        private func makeRowItem(for block: Block, width: CGFloat) -> RowItem {
            let attr = BlockStyle.attributed(for: block)
            let textWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
            let layout = TextLayout.make(attributed: attr, maxWidth: textWidth)
            return RowItem(id: block.id, block: block, layout: layout)
        }

        // MARK: - Diff (granular insert/remove + reload for content changes)

        private func applyDiff(old: [RowItem], new: [RowItem], in tableView: NSTableView) {
            let oldIds = old.map(\.id)
            let newIds = new.map(\.id)

            // Detect content changes for ids present in both arrays.
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
            // Use the column's current width — NSTableView keeps it in sync with
            // available space when the column has `.autoresizingMask`.
            tableView.tableColumns.first?.width ?? 0
        }
    }
}

// MARK: - BlockCellView (custom NSView, Core Text drawing)

private final class BlockCellView: NSView {
    var item: NativeTranscript2View.Coordinator.RowItem? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let origin = CGPoint(
            x: BlockStyle.blockHorizontalPadding,
            y: BlockStyle.blockVerticalPadding)
        item.layout.draw(in: ctx, origin: origin)
    }
}

// MARK: - Preview

#Preview("NativeTranscript2 — heading + paragraph") {
    NativeTranscript2View(blocks: [
        Block(id: UUID(), kind: .heading("Refactor plan")),
        Block(id: UUID(), kind: .paragraph(
            "Replace the existing NativeTranscript module with a smaller, "
            + "Core Text–based renderer. The new module supports two block "
            + "kinds at first: headings and paragraphs.")),
        Block(id: UUID(), kind: .heading("Goals")),
        Block(id: UUID(), kind: .paragraph(
            "Each row computes its layout once and keeps it. The Coordinator "
            + "diffs incoming blocks against the existing rows by stable id, "
            + "so unchanged rows skip re-layout entirely.")),
        Block(id: UUID(), kind: .heading("Open questions")),
        Block(id: UUID(), kind: .paragraph(
            "How will syntax highlighting attach to a row asynchronously "
            + "without touching the synchronous prepare path? That is left "
            + "to a later step.")),
    ])
    .frame(width: 600, height: 500)
}

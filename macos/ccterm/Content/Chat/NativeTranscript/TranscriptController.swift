import AppKit

/// 持有 `[TranscriptRowItem]`，实现 `NSTableViewDataSource` / `NSTableViewDelegate`。
///
/// 职责：
/// - 把 `[MessageEntry]` 转成 items（透过 `MessageEntryTranscriber`）
/// - 批量 `makeSize(width:)` 得到每行高度
/// - reloadData 并通知 NSTableView 复用 rowView
/// - 宽度变化时重排所有 item 并通知 NSTableView 刷新可见 row
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var tableView: TranscriptTableView?
    private(set) var items: [TranscriptRowItem] = []

    var theme: MarkdownTheme?
    var syntaxEngine: SyntaxHighlightEngine?

    /// 上次排版时使用的宽度。宽度真正变化才重算。
    private var lastLayoutWidth: CGFloat = 0

    /// 上一次消费的 entries 的 id 顺序 + theme 指纹。用于 `setEntries` short-circuit
    /// —— SwiftUI reconcile 可能每帧调 updateNSView,若 entries 与 theme 都等价,
    /// 立即返回,不做任何 layout 工作。
    private var lastEntriesSignature: [UUID] = []
    private var lastThemeFingerprint: MarkdownTheme.Fingerprint?

    init(tableView: TranscriptTableView) {
        self.tableView = tableView
        super.init()
    }

    // MARK: - Public API

    /// 全量替换 entries。不做 row-level diff，直接 reloadData——NSTableView
    /// 内部仍然会按 identifier 复用 rowView。
    ///
    /// Short-circuit：entries id 列表 + theme 指纹都等价 → 立即返回。SwiftUI 的
    /// reconcile 会高频触发 updateNSView，这里必须早退以避免 O(N) 重排。
    func setEntries(_ entries: [MessageEntry], themeChanged: Bool) {
        guard let tableView else { return }
        let themeToUse = theme ?? .default
        let themeFingerprint = themeToUse.fingerprint
        let signature = entries.map { $0.id }

        if signature == lastEntriesSignature, lastThemeFingerprint == themeFingerprint {
            return
        }

        let newItems = MessageEntryTranscriber.make(entries: entries, theme: themeToUse)
        let width = effectiveWidth()
        appLog(.debug, "TranscriptController",
            "setEntries table=\(Int(tableView.bounds.width)) clip=\(Int(tableView.enclosingScrollView?.contentView.bounds.width ?? 0)) → use=\(Int(width))")

        let t0 = CFAbsoluteTimeGetCurrent()
        for item in newItems {
            item.makeSize(width: width)
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if !newItems.isEmpty {
            appLog(.info, "TranscriptController",
                "layout \(newItems.count) rows in \(ms)ms width=\(Int(width))")
        }

        items = newItems
        lastLayoutWidth = width
        lastEntriesSignature = signature
        lastThemeFingerprint = themeFingerprint
        tableView.reloadData()
        if !items.isEmpty {
            tableView.scrollRowToVisible(0)
        }
    }

    /// 宽度变化入口：重算所有 item 的 layout，通知 NSTableView 更新行高 + 重绘可见 row。
    func tableWidthChanged(_ newWidth: CGFloat) {
        guard let tableView else { return }
        guard newWidth > 0, abs(newWidth - lastLayoutWidth) > 0.5 else { return }
        appLog(.debug, "TranscriptController",
            "tableWidthChanged \(Int(lastLayoutWidth))→\(Int(newWidth)) items=\(items.count)")
        lastLayoutWidth = newWidth

        guard !items.isEmpty else { return }
        for item in items {
            item.makeSize(width: newWidth)
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<items.count))

        // 不能走 `reloadData(forRowIndexes:columnIndexes:)` —— 我们没有 column,
        // IndexSet(integer: 0) 会越界 assert。直接遍历可见 rowView 重新 set item
        // 触发 `needsDisplay`;layer backing store 会在下一帧重画一次。
        tableView.enumerateAvailableRowViews { view, row in
            guard row >= 0, row < self.items.count else { return }
            (view as? TranscriptRowView)?.set(item: self.items[row])
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < items.count else { return 1 }
        return max(1, items[row].cachedHeight)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier(item.identifier)
        let rowView: TranscriptRowView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? TranscriptRowView {
            rowView = reused
        } else {
            let cls = item.viewClass()
            rowView = cls.init(frame: .zero)
            rowView.identifier = id
        }
        rowView.set(item: item)
        return rowView
    }

    /// 所有绘制在 rowView，`viewFor` 返回 nil。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    // MARK: - Helpers

    /// 优先读 clipView(= scroll viewport 可视宽度)。tableView 自己的宽度是
    /// documentView 宽度,可能大于或小于 clipView——items 要按"可视宽度"排版,
    /// 不是按 tableView 物理宽度。
    private func effectiveWidth() -> CGFloat {
        if let clip = tableView?.enclosingScrollView?.contentView.bounds.width, clip > 0 {
            return clip
        }
        let w = tableView?.bounds.width ?? 0
        return w > 0 ? w : 760
    }
}

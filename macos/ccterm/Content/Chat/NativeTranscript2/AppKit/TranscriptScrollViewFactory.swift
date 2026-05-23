import AppKit

/// Configures and returns a `Transcript2ScrollView` wired up to the
/// given `Transcript2Controller`. Shared between the SwiftUI bridge
/// (`NativeTranscript2View`) and the AppKit-rooted host
/// (`TranscriptDetailViewController`) so the AppKit setup lives in one
/// place — content insets, `.never` layer policies, table column,
/// dataSource/delegate wiring, frameDidChange observer.
///
/// Caller is responsible for placing the returned scroll view into a
/// hierarchy and (eventually) tearing down via
/// `dismantle(_:coordinator:)` — symmetric with the SwiftUI bridge's
/// `dismantleNSView`.
enum TranscriptScrollViewFactory {

    /// The fixed transcript content insets: `top` reserves room for the
    /// window's `unifiedCompact` toolbar; `bottom` reserves room for the
    /// resting input bar + breathing space. See
    /// `Transcript2NSViewBridge.makeNSView` for the original derivation.
    static let contentInsets = NSEdgeInsets(top: 44, left: 0, bottom: 180, right: 0)

    @MainActor
    static func make(controller: Transcript2Controller) -> Transcript2ScrollView {
        let scroll = Transcript2ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .never
        scroll.automaticallyAdjustsContentInsets = false
        // Swap to the layer-backed `.never`-redraw clip *before* writing
        // `contentInsets`. NSScrollView stores the insets on its current
        // contentView; replacing the contentView afterwards drops to a
        // fresh NSClipView with zero insets and our value is silently
        // lost. Result: scroll-to-bottom landed at clip frame bottom
        // rather than at the visible-content-area bottom.
        scroll.contentView = Transcript2ClipView()
        scroll.contentInsets = contentInsets

        let table = Transcript2TableView()
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
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        let coordinator = controller.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        coordinator.tableView = table
        table.coordinator = coordinator
        scroll.documentView = table

        // Source-phase row-count sync. The coordinator's `blocks` may
        // already hold a complete transcript (re-entry — the continuous
        // bridge populated it while no table was attached); a freshly
        // constructed NSTableView doesn't auto-query a newly-bound
        // dataSource. Without this call, `numberOfRows == 0` and
        // `documentView.frame.height == 0` throughout the host's
        // addSubview → layoutSubtreeIfNeeded → scrollToTail sequence,
        // and the upcoming `clip.scroll(to:)` gets clamped to origin=0
        // by `NSClipView.constrainBoundsRect`. AppKit's first display
        // pass in beforeWaiting then updates the documentView frame on
        // its own, but bounds.origin is already pinned at 0 — the
        // documentView paints at the top for one tick before the next
        // layout corrects it. See §1.2 in NativeTranscript2/CLAUDE.md.
        //
        // `noteNumberOfRowsChanged` is the targeted sync: it re-queries
        // count, runs the internal row tile (heightOfRow for each row,
        // documentView frame update), and stops short of cell creation
        // (viewFor still runs lazily on display, same as steady state).
        // For a brand-new draft session whose `blocks` is empty, it's a
        // no-op (count 0 → 0).
        table.noteNumberOfRowsChanged()
        return scroll
    }

    /// Symmetric teardown — call from the host's `viewWillDisappear` /
    /// dismantle path. Removes the frameDidChange observer and breaks
    /// the coordinator's weak ref so re-attach paths see a fresh
    /// table.
    @MainActor
    static func dismantle(_ scroll: Transcript2ScrollView, controller: Transcript2Controller) {
        let coordinator = controller.coordinator
        NotificationCenter.default.removeObserver(coordinator)
        if coordinator.tableView === (scroll.documentView as? NSTableView) {
            coordinator.tableView = nil
        }
    }
}

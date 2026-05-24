import AppKit

/// Configures and returns a `Transcript2ScrollView` wired up to the
/// given `Transcript2Controller`. Shared between the production
/// AppKit host (`ChatSessionViewController`) and the AppKit demo
/// VCs (`TranscriptDemoViewController` etc.) so the AppKit setup lives
/// in one place — content insets, `.never` layer policies, table
/// column, dataSource/delegate wiring, frameDidChange observer.
///
/// **Two-step attach.** `make(controller:)` builds the scroll view
/// shell (clip, table, column, layer policy, content insets) but does
/// NOT bind the table's `dataSource` / `delegate` to the coordinator —
/// that is `bindData(_:controller:)`'s job. The split exists because
/// `NSTableView` answers `numberOfRows` and `heightOfRow` lazily off
/// the dataSource; if we bound it inside `make`, then any autolayout
/// pass that runs before the host's geometry has settled (the host's
/// `addSubview` + `layoutSubtreeIfNeeded` cascade) would query
/// `heightOfRow` at a transient table width — once at the column's
/// default 100pt (clamped to `BlockStyle.minLayoutWidth = 460`), and
/// again at every intermediate width autolayout walks through — and
/// every block's row layout would be typeset, cached, and immediately
/// invalidated. With the bind deferred to after `layoutSubtreeIfNeeded`,
/// the first query lands at the final, settled width and every block
/// is typeset exactly once. Guarded by
/// `TranscriptReentryLayoutCacheTests` (factory direct) and
/// `TranscriptHostReentryLayoutCacheTests` (production VC + demo VC
/// end-to-end).
///
/// Caller is responsible for placing the returned scroll view into a
/// hierarchy, calling `bindData(_:controller:)` AFTER autolayout has
/// settled (host runs `layoutSubtreeIfNeeded` on its own view in
/// between), and tearing down via `dismantle(_:controller:)`.
enum TranscriptScrollViewFactory {

    /// The fixed transcript content insets: `top` reserves room for the
    /// window's `unifiedCompact` toolbar; `bottom` matches the bottom
    /// scrim height (`ChatSessionViewController.bottomFadeScrimHeight`)
    /// so the last cell lands exactly at the input bar's top edge —
    /// hit-test then routes that band to the cell rather than the
    /// scroll view's empty backdrop.
    static let contentInsets = NSEdgeInsets(top: 44, left: 0, bottom: 100, right: 0)

    /// Builds the scroll/clip/table/column shell. The table is added to
    /// the scroll view as document view, but its `dataSource` /
    /// `delegate` remain nil — see the type doc for why. Call
    /// `bindData(_:controller:)` after the scroll view has been mounted
    /// and the host has run `layoutSubtreeIfNeeded`.
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

        scroll.documentView = table
        return scroll
    }

    /// Binds the table to its coordinator: `dataSource`, `delegate`,
    /// `frameDidChange` observer, and the coordinator's weak `tableView`
    /// ref. Triggers `noteNumberOfRowsChanged` at the end so AppKit
    /// queries `heightOfRow` at the table's current (settled) width.
    /// No-op if called twice — the observer is re-registered on the
    /// same notification center and the coordinator's `tableView` is
    /// re-pointed to the same table.
    @MainActor
    static func bindData(
        _ scroll: Transcript2ScrollView,
        controller: Transcript2Controller
    ) {
        guard let table = scroll.documentView as? Transcript2TableView else {
            assertionFailure("bindData called on a scroll view without a Transcript2TableView")
            return
        }
        let coordinator = controller.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)
        // Live-scroll gating: suppress cell hover writes while the user
        // is actively scrolling. Removed by `dismantle`'s blanket
        // `removeObserver(coordinator)`.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.scrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.scrollViewDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scroll)

        coordinator.tableView = table
        table.coordinator = coordinator
        // Setting `dataSource` already triggers NSTableView's internal
        // "fresh attach" path — it lazily queries `numberOfRows` and
        // `heightOfRow` on the next layout pass. We do NOT call
        // `noteNumberOfRowsChanged` here: experimentally that produces
        // a double-count (`table.numberOfRows` lands at 2 × blocks.count)
        // because AppKit treats the dataSource set + explicit note as
        // two independent "rows appeared" signals.
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

import AppKit
import Combine

/// History transcript view controller — reads a session-agnostic
/// `TranscriptStore` (pulled from `TranscriptRegistryStore` in
/// `DetailFlowCoordinator`) and drives stock `NSScrollView` +
/// `TranscriptClipView` + stock `NSTableView` + `BlockCellView`.
///
/// Implementation follows `docs/refactor/transcript-refactor.md`. Read
/// that doc first — every subtle ordering here is spelled out there.
///
/// **Roles rolled into this class:**
/// - `NSTableViewDataSource` / `NSTableViewDelegate` — this VC IS the
///   table's data source and delegate. No intermediate coordinator.
/// - `BlockCellViewDelegate` — cells route hover / fold / gutter events
///   here. `Session.swift`'s old live path keeps `Transcript2Coordinator`
///   as its cell delegate; the two paths never share a cell instance.
/// - `DetailContainerChild` — `prepareForRemoval` releases per-attach
///   resources.
///
/// **Row-count mirror.** dataSource callbacks read `visibleBlocks: [Block]`
/// (VC-local) instead of `store.blocks` directly. Reason: `Store` grows
/// `blocks[]` synchronously inside `events.send(...)`, but the VC applies
/// the corresponding `insertRows` after an off-main typeset hop-back. In
/// the window between them, `numberOfRows(in:)` reading `store.blocks`
/// would return a count `tableView.numberOfRows` doesn't match, and
/// `endUpdates` would raise `NSInternalInconsistencyException`. The
/// mirror stays in sync with what's actually committed to the table.
///
/// **Serialized apply.** Each `.tail` / `.older` delta is processed on a
/// chained async `Task` — batch N+1's apply awaits batch N's completion
/// before dispatching its own typeset. Two batches arriving in the same
/// runloop tick from the SDK loader will not race the `insertRows` calls.
///
/// Fold / status state lives on the Store so a sidebar switch-back
/// preserves them (users expect an expanded tool group to stay expanded).
/// Hover state is VC-local (view lifetime scope).
@MainActor
final class TranscriptViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate,
    BlockCellViewDelegate, DetailContainerChild
{

    private let store: TranscriptStore
    private let syntaxEngine: SyntaxHighlightEngine
    private let highlightStore: TranscriptHighlightStore

    private var scrollView: NSScrollView!
    private var clipView: TranscriptClipView!
    private var tableView: NSTableView!
    private var bag: Set<AnyCancellable> = []

    /// Mirror of what the table is currently displaying. Grows on commit,
    /// not on store event. See class doc.
    private var visibleBlocks: [Block] = []

    /// Chain head for the async apply pipeline. Each new apply awaits the
    /// previous task's completion before dispatching its own typeset.
    private var applyChain: Task<Void, Never>?

    // Attach-tick state (§ 5.4 of the plan).
    private var didInitialAttach = false

    /// Set by `prepareForRemoval`. Every commit-side code path
    /// (apply-chain hop-back, live-resize refill hop-back, hover paint,
    /// highlight-refill paint) checks this before touching `tableView`.
    /// Prevents the "detached typeset finishes after the container has
    /// niled the dataSource" race: the resulting `endUpdates` /
    /// `reloadData(forRowIndexes:)` on a datasourceless table raises
    /// `NSInternalInconsistencyException`.
    private var isReleased = false

    // `BlockCellViewDelegate` requirements.
    var hoveredBlockId: UUID? {
        didSet {
            if isReleased { return }
            guard oldValue != hoveredBlockId else { return }
            var affected = IndexSet()
            if let id = oldValue, let r = row(forBlockId: id) { affected.insert(r) }
            if let id = hoveredBlockId, let r = row(forBlockId: id) { affected.insert(r) }
            guard !affected.isEmpty else { return }
            runStructuralUpdate {
                self.tableView.reloadData(
                    forRowIndexes: affected, columnIndexes: IndexSet(integer: 0))
            }
        }
    }
    private(set) var isLiveScrolling: Bool = false

    private static let cellIdentifier =
        NSUserInterfaceItemIdentifier("TranscriptBlockCell")

    init(store: TranscriptStore, syntaxEngine: SyntaxHighlightEngine) {
        self.store = store
        self.syntaxEngine = syntaxEngine
        self.highlightStore = TranscriptHighlightStore()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View tree

    override func loadView() {
        // Root host — subclassed so `viewDidEndLiveResize` (an `NSView`
        // responder-chain method, NOT an `NSViewController` one) can
        // forward to the VC.
        final class HostView: NSView {
            var onDidEndLiveResize: (() -> Void)?
            override func viewDidEndLiveResize() {
                super.viewDidEndLiveResize()
                onDidEndLiveResize?()
            }
        }
        let host = HostView()
        host.onDidEndLiveResize = { [weak self] in self?.performLiveResizeRefill() }
        host.wantsLayer = true

        let scroll = NSScrollView()
        scroll.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .never
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        // Ordering intentional: assign the clip subclass BEFORE setting
        // contentInsets. `NSScrollView` stores insets on its current
        // contentView; replacing the contentView afterwards would drop
        // the insets to zero.
        let clip = TranscriptClipView()
        clip.wantsLayer = true
        clip.layerContentsRedrawPolicy = .never
        scroll.contentView = clip
        scroll.contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.wantsLayer = true
        table.layerContentsRedrawPolicy = .never
        table.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = [.autoresizingMask]
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        scroll.documentView = table

        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        // Table constraints — 460..780 band centered inside the clip.
        // `TranscriptClipView.constrainBoundsRect` does the visual
        // centering; Auto Layout picks the width.
        let hug = table.widthAnchor.constraint(equalTo: clip.widthAnchor)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            table.widthAnchor.constraint(
                lessThanOrEqualToConstant: BlockStyle.maxLayoutWidth),
            table.widthAnchor.constraint(
                greaterThanOrEqualToConstant: BlockStyle.minLayoutWidth),
            hug,
            table.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
            table.topAnchor.constraint(equalTo: clip.topAnchor),
        ])

        self.scrollView = scroll
        self.clipView = clip
        self.tableView = table
        self.view = host
    }

    // MARK: - Bindings

    override func viewDidLoad() {
        super.viewDidLoad()
        // Delegate only — dataSource stays nil so NSTableView won't tile
        // until viewDidLayout binds it at the settled width. Events sink
        // is deliberately NOT installed here; installed after the warm-
        // entry tile in viewDidLayout (§ 5.4).
        tableView.delegate = self
        highlightStore.attachEngine(syntaxEngine)
        highlightStore.onDidFill = { [weak self] blockId in
            self?.handleHighlightFilled(blockId: blockId)
        }
        // Live-scroll hover suppression (§ 2.2).
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didInitialAttach,
            view.bounds.width > 0,
            view.bounds.height > 0
        else { return }
        view.layoutSubtreeIfNeeded()
        didInitialAttach = true

        // Bind dataSource now — first heightOfRow query lands at settled
        // width. § 2.19 attach contract.
        //
        // Seed `visibleBlocks` from the store BEFORE binding dataSource so
        // the very first `numberOfRows(in:)` query lands on the mirror
        // that's about to be tiled.
        visibleBlocks = store.blocks
        tableView.dataSource = self

        // Warm re-entry: force the dataSource-set tile path to run inline
        // (§ 1.2) so heightOfRow hits the layout cache from the previous
        // mount; scrollRowToVisible lands on the correct row.
        if !visibleBlocks.isEmpty {
            tableView.layoutSubtreeIfNeeded()
            tableView.scrollRowToVisible(tableView.numberOfRows - 1)
        }

        subscribeStoreEvents()
        store.loadHistoryIfNeeded()
    }

    @objc private func scrollDidStartLiveScroll() { isLiveScrolling = true }
    @objc private func scrollDidEndLiveScroll() { isLiveScrolling = false }

    private func subscribeStoreEvents() {
        store.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] delta in self?.enqueueApply(delta) }
            .store(in: &bag)
    }

    // MARK: - DetailContainerChild

    func prepareForRemoval() {
        isReleased = true
        bag.removeAll()
        applyChain?.cancel()
        applyChain = nil
        NotificationCenter.default.removeObserver(self)
        tableView.dataSource = nil
        tableView.delegate = nil
        // Deliberately no cancel on the store's loader — it lives past us
        // in the registry.
    }

    // MARK: - Apply pipeline

    private var contentWidth: CGFloat {
        BlockStyle.clampedLayoutWidth(forRowWidth: tableView.bounds.width)
    }

    private func enqueueApply(_ delta: TranscriptStore.BlockDelta) {
        let previous = applyChain
        applyChain = Task { [weak self] in
            await previous?.value
            await self?.performApply(delta)
        }
    }

    private func performApply(_ delta: TranscriptStore.BlockDelta) async {
        if isReleased { return }
        let w = contentWidth
        let foldsSnap = store.folds
        let statusesSnap = store.statuses
        let batch: [Block]
        let kind: PhaseKind
        switch delta {
        case .tail(let b): batch = b; kind = .tail
        case .older(let b): batch = b; kind = .older
        }
        for b in batch { highlightStore.schedule(block: b) }
        let highlightsSnap = highlightStore.snapshot()

        let pairs: [(UUID, RowLayout)] = await Task.detached(priority: .userInitiated) {
            batch.map { b in
                (b.id, RowLayout.make(
                    for: b, width: w,
                    folds: foldsSnap, statuses: statusesSnap,
                    highlights: highlightsSnap))
            }
        }.value

        if isReleased { return }
        // Commit atomically on main.
        store.writeLayouts(pairs, width: w)
        switch kind {
        case .tail:
            let startIndex = visibleBlocks.count
            visibleBlocks.append(contentsOf: batch)
            runStructuralUpdate {
                self.tableView.beginUpdates()
                self.tableView.insertRows(
                    at: IndexSet(integersIn: startIndex..<(startIndex + batch.count)),
                    withAnimation: [])
                self.tableView.endUpdates()
            }
            if tableView.numberOfRows > 0 {
                tableView.scrollRowToVisible(tableView.numberOfRows - 1)
            }
        case .older:
            commitOlder(batch: batch)
        }
    }

    private enum PhaseKind { case tail, older }

    private func commitOlder(batch: [Block]) {
        let clip = scrollView.contentView
        let originBefore = clip.bounds.origin
        let visibleRange = tableView.rows(in: clip.documentVisibleRect)
        let firstVisibleRow = visibleRange.location
        let firstVisibleRect: NSRect =
            (firstVisibleRow != NSNotFound) ? tableView.rect(ofRow: firstVisibleRow) : .zero

        visibleBlocks.insert(contentsOf: batch, at: 0)
        runStructuralUpdate {
            self.tableView.beginUpdates()
            self.tableView.insertRows(
                at: IndexSet(integersIn: 0..<batch.count),
                withAnimation: [])
            self.tableView.endUpdates()

            if firstVisibleRow != NSNotFound {
                let newRow = firstVisibleRow + batch.count
                let newRect = self.tableView.rect(ofRow: newRow)
                let delta = newRect.minY - firstVisibleRect.minY
                self.clipView.scroll(
                    to: NSPoint(x: originBefore.x, y: originBefore.y + delta))
                self.scrollView.reflectScrolledClipView(self.clipView)
            }
        }
    }

    /// Wraps AppKit implicit-animation suppression around a structural
    /// or paint change so height/frame transitions don't crossfade. Every
    /// write path (Phase 1 append, Phase 2 prepend, fold toggle, hover
    /// paint, highlight refill, live-resize refill) uses this — § 2.10.
    private func runStructuralUpdate(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            body()
        }
        CATransaction.commit()
    }

    // MARK: - Live-resize refill (§ 5.5 + § 2.7 off-screen prefetch)

    private func performLiveResizeRefill() {
        if isReleased { return }
        let w = contentWidth
        // 1. Explicit width transition — required so the detached
        // prefetch's `writeLayouts` guard (width == layoutsWidth) matches.
        store.retargetWidth(w)

        // 2. Split visible from off-screen (§ 2.8 + § 2.7).
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        let visibleStart = visibleRange.location != NSNotFound ? visibleRange.location : 0
        let visibleEnd =
            visibleRange.location != NSNotFound
            ? visibleRange.location + visibleRange.length : 0
        let visibleIndexes = IndexSet(integersIn: visibleStart..<visibleEnd)
        let offscreenIndexes: IndexSet = {
            var s = IndexSet(integersIn: 0..<visibleBlocks.count)
            s.subtract(visibleIndexes)
            return s
        }()
        let visibleBlocksList = visibleIndexes.compactMap { i -> Block? in
            visibleBlocks.indices.contains(i) ? visibleBlocks[i] : nil
        }
        let offscreenBlocksList = offscreenIndexes.compactMap { i -> Block? in
            visibleBlocks.indices.contains(i) ? visibleBlocks[i] : nil
        }

        // 3. Snapshots.
        let foldsSnap = store.folds
        let statusesSnap = store.statuses
        let highlightsSnap = highlightStore.snapshot()

        // 4. Anchor capture (visible-top row) — restore after
        // noteHeightOfRows commits new heights.
        let clip = scrollView.contentView
        let originBefore = clip.bounds.origin
        let anchorRow = visibleStart
        let anchorRectBefore = (visibleRange.location != NSNotFound)
            ? tableView.rect(ofRow: anchorRow) : .zero

        // 5. Off-main typeset for visible AND off-screen. Off-screen
        // prefetch is § 2.7's guard against "off-screen rows lazy-layout
        // one-at-a-time as user scrolls in".
        Task.detached(priority: .userInitiated) { [weak self] in
            let visiblePairs = visibleBlocksList.map { b in
                (b.id, RowLayout.make(
                    for: b, width: w,
                    folds: foldsSnap, statuses: statusesSnap,
                    highlights: highlightsSnap))
            }
            let offscreenPairs = offscreenBlocksList.map { b in
                (b.id, RowLayout.make(
                    for: b, width: w,
                    folds: foldsSnap, statuses: statusesSnap,
                    highlights: highlightsSnap))
            }
            await MainActor.run {
                guard let self, !self.isReleased else { return }
                self.store.writeLayouts(visiblePairs, width: w)
                self.store.writeLayouts(offscreenPairs, width: w)
                self.runStructuralUpdate {
                    self.tableView.noteHeightOfRows(withIndexesChanged: visibleIndexes)
                    self.tableView.layoutSubtreeIfNeeded()

                    // Anchor restore — visual-top row keeps its screen y.
                    if visibleRange.location != NSNotFound {
                        let newRect = self.tableView.rect(ofRow: anchorRow)
                        let delta = newRect.minY - anchorRectBefore.minY
                        self.clipView.scroll(
                            to: NSPoint(x: originBefore.x, y: originBefore.y + delta))
                        self.scrollView.reflectScrolledClipView(self.clipView)
                    }
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleBlocks.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let block = visibleBlocks[row]
        let layout = store.layout(
            for: block, width: contentWidth,
            folds: store.folds, statuses: store.statuses,
            highlights: highlightStore.snapshot())
        let pad = BlockStyle.blockPadding(for: block.kind)
        return pad.top + layout.totalHeight + pad.bottom
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let block = visibleBlocks[row]
        let layout = store.layout(
            for: block, width: contentWidth,
            folds: store.folds, statuses: store.statuses,
            highlights: highlightStore.snapshot())
        let pad = BlockStyle.blockPadding(for: block.kind)
        let cell =
            tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil)
                as? BlockCellView ?? BlockCellView()
        cell.identifier = Self.cellIdentifier
        cell.delegate = self
        if cell.blockId != block.id {
            highlightStore.schedule(block: block)
            cell.blockId = block.id
        }
        cell.padTop = pad.top
        cell.layout = layout
        cell.gutters = block.gutters
        cell.resetCopiedFeedback()
        // Selection + search highlights: intentionally cleared. When
        // those features come back in a follow-up PR (§ 14 of the plan)
        // the reset must move to a code path that only fires on true
        // cell-reuse, not on every hover/highlight-driven `viewFor`.
        cell.selection = nil
        cell.searchHighlights = nil
        return cell
    }

    // MARK: - BlockCellViewDelegate (hover + isLiveScrolling declared above)

    func toggleFold(id: UUID) {
        if isReleased { return }
        guard let hostId = store.toggleFold(id: id) else { return }
        guard let row = row(forBlockId: hostId) else { return }
        runStructuralUpdate {
            self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            self.tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0))
        }
    }

    func requestUserBubbleSheet(id: UUID) {
        appLog(.info, "TranscriptViewController",
            "requestUserBubbleSheet ignored — sheet not wired in history path (blockId=\(id))")
    }

    func requestImagePreview(image: NSImage) {
        appLog(.info, "TranscriptViewController",
            "requestImagePreview ignored — sheet not wired in history path")
        _ = image
    }

    func handleGutter(_ spec: GutterSpec, blockId: UUID) {
        // Mirrors `Transcript2Coordinator.handleGutter` — off-main
        // serialize + pasteboard write. `NSPasteboard.general` is
        // documented as safe from any thread for clearContents +
        // setString.
        guard let block = visibleBlocks.first(where: { $0.id == blockId }) else { return }
        switch spec.kind {
        case .copy:
            let snapshot = block
            Task.detached(priority: .userInitiated) {
                let text = snapshot.copyableText()
                guard !text.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    // MARK: - Highlight refill hook

    private func handleHighlightFilled(blockId: UUID) {
        if isReleased { return }
        store.invalidateLayout(id: blockId)
        guard let row = row(forBlockId: blockId) else { return }
        // Highlights change colour, not metrics — no noteHeightOfRows.
        runStructuralUpdate {
            self.tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: - Helpers

    private func row(forBlockId id: UUID) -> Int? {
        visibleBlocks.firstIndex(where: { $0.id == id })
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// under macOS 26.
    nonisolated deinit {}
}

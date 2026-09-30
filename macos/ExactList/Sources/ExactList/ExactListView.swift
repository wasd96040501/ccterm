import AppKit
import ExactListCore

// `Anchoring` is part of this module's surface (a host spells `.row(r)` and
// defaults to `.automatic`); nothing else of Core is.
@_exported import enum ExactListCore.Anchoring

/// A vertical list of host views with exact geometry, anchored scrolling and
/// motion on AppKit's animation engine. It uses `NSTableView`'s vocabulary.
/// SPEC.md is normative, and each member names the requirements it
/// implements.
///
/// This is the only view a host mounts. It owns its scroll view, clip view and
/// document view, and none of them is public (L2). It loads by itself, at the
/// first layout that has a window and a width (L3, L4).
@MainActor
public final class ExactListView: NSView {

    /// The anchoring policy (§6), re-exported from Core so a host needs only
    /// `import ExactList`. *Deviation:* `NSTableView` has none; it leaves the
    /// offset where it was (A3).
    public typealias Anchoring = ExactListCore.Anchoring

    // MARK: - Lifecycle (§4)

    /// L1: both are held weakly and can't be replaced afterwards. Nothing is
    /// asked of either before the load point (L3).
    ///
    /// *Deviation:* `NSTableView` takes them as settable properties, so a host
    /// can assign them after mounting or forget `reloadData()` (L1).
    public init(dataSource: ExactListViewDataSource, delegate: ExactListViewDelegate) {
        let clip = ListClipView(frame: .zero)
        clipView = clip
        scrollView = ListScrollView(clipView: clip)
        documentView = ListDocumentView(frame: .zero)
        placement = RowPlacement(documentView: documentView)
        animator = MotionAnimator(clockHost: documentView)
        self.dataSource = dataSource
        self.delegate = delegate
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.documentView = documentView
        scrollView.owner = self
        clip.owner = self
        documentView.owner = self
        placement.owner = self
        animator.owner = self
        refresher.owner = self
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// `NSTableView.dataSource`: weak, the AppKit ownership. *Deviation:*
    /// read-only (L1).
    public private(set) weak var dataSource: ExactListViewDataSource?

    /// `NSTableView.delegate`: weak, the AppKit ownership. *Deviation:*
    /// read-only (L1).
    public private(set) weak var delegate: ExactListViewDelegate?

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        loadIfReady()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isLoaded { needsLayout = true }
    }

    // MARK: - Configuration (§6.4)

    /// `s`, the gap between two rows. Named after `NSGridView.rowSpacing`. A
    /// change is an anchored commit that doesn't animate (V3). Default 0.
    public var rowSpacing: CGFloat {
        get { spacing }
        set {
            precondition(newValue.isFinite && newValue >= 0, "ExactList: rowSpacing \(newValue) (L12)")
            guard isLoaded else {
                spacing = newValue
                return
            }
            requireOutsideCallbacks("rowSpacing")
            commit(map: identityMap(), newSpacing: newValue)
        }
    }

    /// `NSScrollView.contentInsets`. A change is an anchored commit that doesn't
    /// animate, and the tail stays the tail (V2).
    public var contentInsets: NSEdgeInsets {
        get { insets }
        set {
            insets = newValue
            // AppKit re-constrains the clip view here. That is an echo: the
            // anchor must resolve against the viewport before the change (V2).
            adjusting { scrollView.contentInsets = newValue }
            syncViewport()
        }
    }

    /// `NSScrollView.scrollerStyle`. `nil`, the default, follows the system
    /// setting (L11). A legacy scroller takes its width from the rows, so a
    /// change is a width change (W1). *Deviation:* optional, and a set style
    /// holds when the system setting changes. `NSScrollView` rewrites the
    /// property then, and an AppKit host pins it by overriding it in a
    /// subclass, which the list's internal scroll view doesn't allow.
    public var scrollerStyle: NSScroller.Style? {
        get { scrollView.pinnedScrollerStyle }
        set { scrollView.pinnedScrollerStyle = newValue }
    }

    /// Whether the viewport stays at the end as rows arrive and grow while it
    /// sits there (A1, A8). Default `false`, the `NSTableView` behaviour.
    public var automaticallyFollowsTail: Bool {
        get { followsTail }
        set {
            followsTail = newValue
            if isLoaded { reportTail() }
        }
    }

    /// A8: `automaticallyFollowsTail`, and the viewport at the tail.
    /// *Deviation:* `NSTableView` doesn't follow the tail.
    public var isFollowingTail: Bool {
        isLoaded && followsTail && committed.isAtTail(contentHeight: heights.contentHeight)
    }

    // MARK: - Rows (§7)

    /// `NSTableView.numberOfRows`: `n`. 0 before the load point (L5).
    public var numberOfRows: Int {
        isLoaded ? heights.count : 0
    }

    /// One batch: the updates in `updates` commit together, before this
    /// returns (U1), anchored by `anchoring` (§6), animated per M1.
    ///
    /// *Deviation from `beginUpdates()`/`endUpdates()`:* a closure can't be left
    /// unbalanced, and the `Updates` proxy it receives can't query half-applied
    /// geometry (U3). Nested calls flatten into the outermost one.
    ///
    /// Committing is a fixed point, and the loop belongs to this method, not to
    /// `CommitPlanner`, which stays pure. Which stale rows fall in `P` depends
    /// on `o'`, and `o'` depends on the heights above the anchor, some of which
    /// may be stale. So: plan, measure the stale rows now in `P` (U5, W4), plan
    /// again, until no new row enters.
    public func performBatchUpdates(
        anchoring: Anchoring = .automatic, _ updates: (Updates) -> Void,
        completionHandler: ((Bool) -> Void)? = nil
    ) {
        precondition(callbackDepth == 0, "ExactList: performBatchUpdates from inside a callback (L9)")
        if let openBatch {
            updates(openBatch)
            if let completionHandler { openCompletions.append(completionHandler) }
            return
        }
        guard isLoaded else {
            if let completionHandler { DispatchQueue.main.async { completionHandler(true) } }
            return
        }
        let recorder = Updates(oldCount: heights.count)
        openBatch = recorder
        openCompletions = completionHandler.map { [$0] } ?? []
        updates(recorder)
        recorder.close()
        openBatch = nil
        let completions = openCompletions
        openCompletions = []
        let done: (Bool) -> Void = { finished in completions.forEach { $0(finished) } }

        let map = recorder.map
        let rows = numberOfRowsInDataSource()
        precondition(
            rows == map.newCount,
            "ExactList: the data source has \(rows) rows, the updates announced \(map.newCount) (L10)")
        guard !map.isEmpty else {
            DispatchQueue.main.async { done(true) }
            return
        }
        let (duration, timing) = motionTiming(moves: !map.movedRows.isEmpty)
        commit(map: map, anchoring: anchoring, duration: duration, timing: timing, completion: done)
    }

    /// `NSTableView.insertRows(at:withAnimation:)`: a batch of one (U4).
    public func insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        requireOutsideCallbacks("insertRows")
        performBatchUpdates { $0.insertRows(at: indexes, withAnimation: options) }
    }

    /// `NSTableView.removeRows(at:withAnimation:)`: a batch of one (U4).
    public func removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        requireOutsideCallbacks("removeRows")
        performBatchUpdates { $0.removeRows(at: indexes, withAnimation: options) }
    }

    /// `NSTableView.moveRow(at:to:)`: a batch of one (U4).
    public func moveRow(at oldIndex: Int, to newIndex: Int) {
        requireOutsideCallbacks("moveRow")
        performBatchUpdates { $0.moveRow(at: oldIndex, to: newIndex) }
    }

    /// `NSTableView.reloadData(forRowIndexes:columnIndexes:)`, without the
    /// columns: asks the mounted rows among `indexes` for their views again.
    /// Heights are not asked (U6).
    public func reloadData(forRowIndexes indexes: IndexSet) {
        requireOutsideCallbacks("reloadData(forRowIndexes:)")
        performBatchUpdates { $0.reloadData(forRowIndexes: indexes) }
    }

    /// `NSTableView.noteHeightOfRows(withIndexesChanged:)`: asks these rows for
    /// their height again at commit. Animated unless inside a duration-0 group,
    /// as in a view-based table (M1).
    public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        requireOutsideCallbacks("noteHeightOfRows")
        performBatchUpdates { $0.noteHeightOfRows(withIndexesChanged: indexes) }
    }

    /// `NSTableView.reloadData()`: everything asked for again, never animated
    /// (U7, A9).
    public func reloadData() {
        requireOutsideCallbacks("reloadData")
        guard isLoaded else { return }
        // Unmounting under a host's implicit-animation group would have AppKit
        // fade the views out, and pooled views would carry that fade into the
        // rows they're reused for.
        NSAnimationContext.withoutAnimation {
            for container in animator.cancelAll() { placement.retire(container) }
            placement.removeAll()
        }
        accessibilityElements.removeAll()
        refresher.cancel()
        let wasFollowing = isFollowingTail
        let oldOffset = committed.offset
        let rows = numberOfRowsInDataSource()
        heights = RowHeights((0..<rows).map { measure($0) }, spacing: spacing)
        stale = StaleRows(count: rows)
        animator.update(heights: heights, width: width)
        let contentHeight = heights.contentHeight
        let offset =
            wasFollowing
            ? committed.maxOffset(contentHeight: contentHeight)
            : committed.clamped(committed.offset, contentHeight: contentHeight)
        NSAnimationContext.withoutAnimation {
            install(offset: offset)
            placement.place(rows: preparedRows(), keeping: [], heights: heights, width: width)
        }
        reportTail()
        if committed.offset != oldOffset { callDelegate { $0.listViewDidScroll(self) } }
        NSAccessibility.post(element: documentView, notification: .rowCountChanged)
    }

    // MARK: - Views (§10)

    /// A pooled view with `identifier`, or `make()` with the identifier set
    /// (P4).
    ///
    /// *Deviation from `makeView(withIdentifier:owner:)`:* that method returns
    /// `NSView?` so that it can serve nibs. In code, it forces
    /// `as? Foo ?? Foo()` plus a manual `identifier` assignment, and forgetting
    /// that assignment silently disables recycling.
    public func makeView<V: NSView>(withIdentifier identifier: NSUserInterfaceItemIdentifier, make: () -> V) -> V {
        pool.makeView(withIdentifier: identifier, make: make)
    }

    /// P8: `NSScrollView.addFloatingSubview(_:for:)`, on the scroll view the
    /// list keeps private (L2). The host sets the view's frame, converting
    /// from the list's coordinates.
    public func addFloatingSubview(_ view: NSView, for axis: NSEvent.GestureAxis) {
        scrollView.addFloatingSubview(view, for: axis)
    }

    /// The mounted view for `row`, or `nil` (P7).
    ///
    /// *Deviation:* there is no `makeIfNecessary`, because building a view for
    /// a row that isn't mounted would break P1.
    public func view(atRow row: Int) -> NSView? {
        placement.container(forRow: row)?.hostedView
    }

    /// The row of a mounted view or any of its descendants, else −1
    /// (`NSTableView.row(for:)`, P6).
    public func row(for view: NSView) -> Int {
        placement.row(for: view)
    }

    /// Every mounted row's view, with its row
    /// (`NSTableView.enumerateAvailableRowViews(_:)`). Views that are animating
    /// out are not included.
    public func enumerateAvailableRowViews(_ body: (NSView, Int) -> Void) {
        for row in placement.mountedRows {
            if let view = placement.container(forRow: row)?.hostedView { body(view, row) }
        }
    }

    // MARK: - Geometry (§5), in this view's own flipped coordinates

    /// G4: `NSTableView.rect(ofRow:)`, in this view's coordinates. `.zero` when
    /// out of range, or before the load point.
    public func rect(ofRow row: Int) -> NSRect {
        precondition(openBatch == nil, "ExactList: rect(ofRow:) inside a batch (L9)")
        guard isLoaded, row >= 0, row < heights.count else { return .zero }
        let frame = NSRect(x: 0, y: heights.top(ofRow: row), width: width, height: heights[row])
        return convert(frame, from: documentView)
    }

    /// G4: `NSTableView.row(at:)`. −1 in a spacing gap, outside the rows, or
    /// before the load point.
    public func row(at point: NSPoint) -> Int {
        precondition(openBatch == nil, "ExactList: row(at:) inside a batch (L9)")
        guard isLoaded else { return -1 }
        let inDocument = documentView.convert(point, from: self)
        guard inDocument.x >= 0, inDocument.x < width else { return -1 }
        return heights.row(containingY: inDocument.y) ?? -1
    }

    /// G4: `NSTableView.rows(in:)`, as a `Range<Int>`.
    public func rows(in rect: NSRect) -> Range<Int> {
        precondition(openBatch == nil, "ExactList: rows(in:) inside a batch (L9)")
        guard isLoaded else { return 0..<0 }
        let inDocument = documentView.convert(rect, from: self)
        return heights.rows(intersecting: inDocument.minY, inDocument.maxY)
    }

    // MARK: - Scrolling (§11)

    /// S1, `NSTableView.scrollRowToVisible(_:)`: the least scroll that brings
    /// `row` fully into view, or its top when
    /// it is taller than the view. Animated only under `allowsImplicitAnimation`
    /// (M1).
    public func scrollRowToVisible(_ row: Int) {
        guard isLoaded else {
            phase = .waiting(pendingScroll: .toVisible(row: row))
            return
        }
        requireOutsideCallbacks("scrollRowToVisible")
        scroll(to: offset(revealing: row))
    }

    /// S2: aligns `row` to `.top`, `.centeredVertically`, `.bottom` or
    /// `.nearestHorizontalEdge`, clamped to the scroll range.
    ///
    /// *Deviation:* `NSTableView` has no landing position; this is
    /// `NSCollectionView.scrollToItems(at:scrollPosition:)`'s shape.
    public func scrollToRow(_ row: Int, at position: NSCollectionView.ScrollPosition) {
        guard isLoaded else {
            phase = .waiting(pendingScroll: .to(row: row, position: position))
            return
        }
        requireOutsideCallbacks("scrollToRow")
        scroll(to: offset(for: row, at: position))
    }

    // MARK: - Private state

    private let scrollView: ListScrollView
    private let clipView: ListClipView
    private let documentView: ListDocumentView
    private let pool = RowViewPool()
    private let placement: RowPlacement
    private let animator: MotionAnimator
    private let refresher = StaleRowRefresher()

    private var phase: ListPhase = .waiting(pendingScroll: nil)

    /// The committed geometry, the width it was measured at (`W`), and which rows
    /// were measured at an earlier width.
    private var heights = RowHeights()
    private var width: CGFloat = 0
    private var stale = StaleRows(count: 0)

    /// The viewport as of the last commit or scroll: what anchors resolve
    /// against, even when AppKit has already moved the clip view on the way to
    /// telling us.
    private var committed = Viewport(offset: 0, height: 0, insetTop: 0, insetBottom: 0)

    private var spacing: CGFloat = 0
    private var insets = NSEdgeInsets()
    private var followsTail = false
    private var reportedTail = false

    /// The batch whose closure is running, and what it has collected (U3).
    private var openBatch: Updates?
    private var openCompletions: [(Bool) -> Void] = []

    /// Inside a data source or delegate call (L9).
    private var callbackDepth = 0

    /// The list is writing its own frames and offset: whatever AppKit reports
    /// back meanwhile is an echo, not news.
    private var isAdjusting = false

    /// AppKit's overdraw request, in document coordinates (P1).
    private var appKitPrepared: NSRect?

    /// Accessibility rows for rows with no container, made on demand (X3).
    private var accessibilityElements: [Int: UnmountedRowElement] = [:]

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    // MARK: - Loading (§4)

    /// L3, L4, L6: loads once there is a window and a width, and not before.
    private func loadIfReady() {
        guard case .waiting(let pending) = phase, window != nil, bounds.width > 0 else { return }
        // The clip view's width is final only once the scroll view has tiled at
        // this size; loading before that would measure every row at a width
        // that is never shown (L7).
        adjusting { scrollView.tile() }
        guard clipView.bounds.width > 0 else { return }
        phase = .loaded
        width = clipView.bounds.width
        let rows = numberOfRowsInDataSource()
        heights = RowHeights((0..<rows).map { measure($0) }, spacing: spacing)
        stale = StaleRows(count: rows)
        committed = liveViewport()
        animator.update(heights: heights, width: width)
        let offset: CGFloat =
            if let pending { destination(of: pending) } else if followsTail {
                committed.maxOffset(contentHeight: heights.contentHeight)
            } else { committed.minOffset }
        NSAnimationContext.withoutAnimation {
            install(offset: offset)
            placement.place(rows: preparedRows(), keeping: [], heights: heights, width: width)
        }
        reportedTail = isFollowingTail
    }

    // MARK: - Committing (§6, §7)

    /// The one place geometry, offset and the mounted set change together.
    ///
    /// Heights are asked for here, never inside a batch closure (U5): inserted
    /// and noted rows first, then, as a fixed point, every stale row the new
    /// offset brings into `P` (W4). `measured` carries rows measured already.
    private func commit(
        map: RowIndexMap, anchoring: Anchoring = .automatic, targetOffset: CGFloat? = nil,
        newViewport: Viewport? = nil, newSpacing: CGFloat? = nil, rescales: Bool = false,
        measured: [Int: CGFloat] = [:], duration: TimeInterval = 0,
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut),
        completion: ((Bool) -> Void)? = nil
    ) {
        let oldHeights = heights
        let oldOffset = committed.offset
        let target = newViewport ?? committed
        // Inserted and noted rows are asked, in ascending order; rows measured
        // already keep that measurement (G5: no pass over untouched rows).
        var fresh = IndexSet(measured.keys)
        var newHeights = oldHeights.applying(map) { row in
            fresh.insert(row)
            return measured[row] ?? measure(row)
        }
        for (row, height) in measured where newHeights[row] != height {
            newHeights.setHeight(height, ofRow: row)
        }
        if let newSpacing { newHeights.spacing = newSpacing }
        let animates = duration > 0 && asksForMotion(map, from: oldHeights, to: newHeights)
        var newStale = stale
        newStale.apply(map)
        newStale.markFresh(fresh)

        var mountedBefore = placement.mountedRows
        mountedBefore.formUnion(animator.rowsInFlight)
        // Rows still in flight from an earlier commit stay mounted (P1), so
        // they are shown too, and must be fresh like the rows in `P` (W4).
        let inFlight = IndexSet(animator.rowsInFlight.compactMap { map.newIndex(forOld: $0) })
        var plan: CommitPlan
        repeat {
            plan = CommitPlanner.plan(
                CommitInput(
                    oldHeights: oldHeights, newHeights: newHeights, map: map, oldViewport: committed,
                    newViewport: target, anchoring: anchoring, targetOffset: targetOffset, followsTail: followsTail,
                    rescalesAnchor: rescales, mountedRows: mountedBefore, animates: animates))
            var after = target
            after.offset = plan.offset
            let needed = rowsToMount(plan, viewport: after, heights: newHeights).union(inFlight).filteredIndexSet {
                newStale.contains($0)
            }
            if needed.isEmpty { break }
            for row in needed { newHeights.setHeight(measure(row), ofRow: row) }
            newStale.markFresh(needed)
        } while true

        let countChanged = map.newCount != map.oldCount
        // The removed rows that move out (M2); every other one leaves before
        // the arriving rows are placed, which then take their containers.
        let leaving = animates ? Set(plan.motions.lazy.filter { $0.kind == .removed }.map(\.row)) : []
        var retiring: [Int: RowContainerView] = [:]
        var containers: [Int: RowContainerView] = [:]
        NSAnimationContext.withoutAnimation {
            for (row, container) in placement.apply(map) {
                if leaving.contains(row) { retiring[row] = container } else { placement.retire(container) }
            }
            renumberAccessibilityElements(through: map)
            heights = plan.heights
            stale = newStale
            if let newSpacing { spacing = newSpacing }
            let placedOffset = committed.offset
            install(offset: plan.offset)
            // An animated scroll carries on from where this commit put the
            // offset (S3).
            animator.shiftScroll(by: committed.offset - placedOffset)
            placement.place(
                rows: rowsToMount(plan, viewport: committed, heights: heights), keeping: animator.rowsInFlight,
                heights: heights, width: width)
            placement.reload(rows: map.reloadedRows)
            // The rows still moving from earlier commits go on to the new
            // geometry (M8).
            animator.update(heights: heights, width: width)
            for motion in plan.motions where motion.kind != .removed {
                containers[motion.row] = placement.container(forRow: motion.row)
            }
        }
        // Outside the transaction above: a group nested in an explicit
        // CATransaction is not waited for by the caller's group (measured),
        // and M3 makes the caller's completion wait for the motion.
        animator.animate(
            plan, containers: containers, retiring: retiring, duration: animates ? duration : 0, timing: timing,
            completion: completion ?? { _ in })
        reportTail()
        if committed.offset != oldOffset { callDelegate { $0.listViewDidScroll(self) } }
        if countChanged { NSAccessibility.post(element: documentView, notification: .rowCountChanged) }
        if !stale.isEmpty { refresher.schedule() }
    }

    /// P1: the rows in `P` (and AppKit's overdraw), plus the rows the plan
    /// moves through `P`.
    private func rowsToMount(_ plan: CommitPlan, viewport: Viewport, heights: RowHeights) -> IndexSet {
        var rows = preparedRows(viewport: viewport, heights: heights)
        for motion in plan.motions where motion.kind != .removed {
            rows.insert(motion.row)
        }
        return rows
    }

    /// The rows intersecting `P`, and AppKit's own overdraw within the height
    /// of `U` of it (P1).
    private func preparedRows(viewport: Viewport? = nil, heights: RowHeights? = nil) -> IndexSet {
        let viewport = viewport ?? committed
        let heights = heights ?? self.heights
        var rows = IndexSet(integersIn: heights.rows(intersecting: viewport.preparedTop, viewport.preparedBottom))
        if let requested = appKitPrepared {
            let reach = viewport.unobscuredBottom - viewport.unobscuredTop
            let lower = max(requested.minY, viewport.preparedTop - reach)
            let upper = min(requested.maxY, viewport.preparedBottom + reach)
            if lower < upper { rows.formUnion(IndexSet(integersIn: heights.rows(intersecting: lower, upper))) }
        }
        return rows
    }

    /// Sizes the document to `W × H` and moves the clip view to `offset`,
    /// without hearing about either as news.
    private func install(offset: CGFloat) {
        adjusting {
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: heights.contentHeight)
            moveClip(to: offset)
        }
        committed = liveViewport()
    }

    private func moveClip(to offset: CGFloat) {
        clipView.setBoundsOrigin(NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Runs `body` with AppKit's reports treated as echoes of it.
    private func adjusting(_ body: () -> Void) {
        let was = isAdjusting
        isAdjusting = true
        defer { isAdjusting = was }
        body()
    }

    private func identityMap() -> RowIndexMap {
        RowIndexMap(oldCount: heights.count)
    }

    private func liveViewport() -> Viewport {
        Viewport(
            offset: clipView.bounds.origin.y, height: clipView.bounds.height, insetTop: insets.top,
            insetBottom: insets.bottom)
    }

    /// M1: `NSTableView`'s timing, `.easeOut` outside any group for 0.2 s, or
    /// 0.4 s when the batch `moves` a row; else the group's, `nil` meaning
    /// `.default`; none under Reduce Motion.
    private func motionTiming(moves: Bool = false) -> (TimeInterval, CAMediaTimingFunction) {
        let context = NSAnimationContext.current
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return (0, CAMediaTimingFunction(name: .default))
        }
        guard isInAnimationGroup(context) else { return (moves ? 0.4 : 0.2, CAMediaTimingFunction(name: .easeOut)) }
        return (context.duration, context.timingFunction ?? CAMediaTimingFunction(name: .default))
    }

    /// M1: whether a batch asks for motion, as it does in `NSTableView`: it
    /// moves a row, inserts or removes one with an effect, or changes a noted
    /// row's height, or the context allows implicit animation. Rows measured
    /// for any other reason don't count; they are not the host's change.
    private func asksForMotion(_ map: RowIndexMap, from old: RowHeights, to new: RowHeights) -> Bool {
        if !map.movedRows.isEmpty || NSAnimationContext.current.allowsImplicitAnimation { return true }
        if map.insertions.values.contains(where: { !$0.isEmpty })
            || map.removals.values.contains(where: { !$0.isEmpty })
        {
            return true
        }
        return map.notedRows.contains { row in map.oldIndex(forNew: row).map { old[$0] != new[row] } ?? false }
    }

    /// Whether an `NSAnimationContext` group is open: AppKit's own state,
    /// which `NSTableView` reads through `+_hasActiveGrouping` and no public
    /// API exposes (M1's deviation). Where AppKit doesn't answer, a group is
    /// recognised by what it set.
    private func isInAnimationGroup(_ context: NSAnimationContext) -> Bool {
        let selector = NSSelectorFromString("_hasActiveGrouping")
        if let method = class_getClassMethod(NSAnimationContext.self, selector) {
            typealias Query = @convention(c) (AnyClass, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Query.self)(NSAnimationContext.self, selector)
        }
        return context.duration != 0.25 || context.timingFunction != nil || context.allowsImplicitAnimation
            || context.completionHandler != nil
    }

    // MARK: - Width and viewport (§6.4, §9)

    /// W1–W3, V1, V2: whatever the tile changed, committed without animation.
    private func syncViewport() {
        guard isLoaded, !isAdjusting else { return }
        let live = liveViewport()
        let newWidth = clipView.bounds.width
        guard newWidth > 0 else { return }
        if newWidth != width {
            width = newWidth
            stale.markAllStale(except: [])
            commit(map: identityMap(), newViewport: live, rescales: true)
            if !stale.isEmpty { refresher.schedule() }
        } else if live.height != committed.height || live.insetTop != committed.insetTop
            || live.insetBottom != committed.insetBottom
        {
            commit(map: identityMap(), newViewport: live)
        }
    }

    /// A8: reports only a change, starting from the value at the load point.
    private func reportTail() {
        let now = isFollowingTail
        guard now != reportedTail else { return }
        reportedTail = now
        callDelegate { $0.listView(self, didChangeTailFollowing: now) }
    }

    // MARK: - Scrolling (§11)

    /// S3: without animation, a commit anchored on the destination; animated,
    /// the offset itself moves there, one frame at a time.
    private func scroll(to offset: CGFloat) {
        let (duration, timing) = motionTiming()
        if NSAnimationContext.current.allowsImplicitAnimation && duration > 0 {
            animator.scroll(from: committed.offset, to: offset, duration: duration, timing: timing)
        } else {
            animator.cancelScroll()
            commit(map: identityMap(), targetOffset: offset)
        }
    }

    /// P1, W4, A8 after the offset moved: mount against the new `P`, measuring
    /// stale rows first, and re-evaluate tail following.
    private func didScroll() {
        committed = liveViewport()
        remount()
        callDelegate { $0.listViewDidScroll(self) }
    }

    /// P1, W4, A8: mounts the rows in `P` at the committed geometry, or, when
    /// a stale row would be shown, commits to measure it first.
    private func remount() {
        if preparedRows().union(animator.rowsInFlight).contains(where: { stale.contains($0) }) {
            commit(map: identityMap())
        } else {
            NSAnimationContext.withoutAnimation {
                placement.place(rows: preparedRows(), keeping: animator.rowsInFlight, heights: heights, width: width)
            }
            reportTail()
        }
    }

    private func destination(of pending: ListPhase.PendingScroll) -> CGFloat {
        switch pending {
        case .toVisible(let row): return offset(revealing: row)
        case .to(let row, let position): return offset(for: row, at: position)
        }
    }

    /// S1: the least scroll that brings `row` into `U`, or its top when it is
    /// taller than `U`.
    private func offset(revealing row: Int) -> CGFloat {
        precondition(row >= 0 && row < heights.count, "ExactList: row \(row) out of range (L12)")
        let top = heights.top(ofRow: row)
        let bottom = top + heights[row]
        var offset = committed.offset
        if bottom - top > committed.unobscuredBottom - committed.unobscuredTop || top < committed.unobscuredTop {
            offset = top - committed.insetTop
        } else if bottom > committed.unobscuredBottom {
            offset = bottom - committed.height + committed.insetBottom
        }
        return committed.clamped(offset, contentHeight: heights.contentHeight)
    }

    /// S2: `row` aligned to `U` at `position`, clamped.
    private func offset(for row: Int, at position: NSCollectionView.ScrollPosition) -> CGFloat {
        precondition(row >= 0 && row < heights.count, "ExactList: row \(row) out of range (L12)")
        let top = heights.top(ofRow: row)
        let bottom = top + heights[row]
        let reach = committed.unobscuredBottom - committed.unobscuredTop
        let target: CGFloat
        if position.contains(.top) {
            target = top - committed.insetTop
        } else if position.contains(.centeredVertically) {
            target = (top + bottom) / 2 - committed.insetTop - reach / 2
        } else if position.contains(.bottom) {
            target = bottom - committed.height + committed.insetBottom
        } else {
            return offset(revealing: row)
        }
        return committed.clamped(target, contentHeight: heights.contentHeight)
    }

    // MARK: - Calling the host

    private func numberOfRowsInDataSource() -> Int {
        guard let dataSource else { preconditionFailure("ExactList: the data source was deallocated (L12)") }
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        return dataSource.numberOfRows(in: self)
    }

    /// Asks one row's height at `W`, checking L7 and L12.
    private func measure(_ row: Int) -> CGFloat {
        precondition(width > 0, "ExactList: measuring at width \(width) (L7)")
        guard let delegate else { preconditionFailure("ExactList: the delegate was deallocated (L12)") }
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        let height = delegate.listView(self, heightOfRow: row, width: width)
        precondition(height.isFinite && height > 0, "ExactList: row \(row) answered height \(height) (L12)")
        return height
    }

    private func callDelegate<T>(_ body: (ExactListViewDelegate) -> T) -> T {
        guard let delegate else { preconditionFailure("ExactList: the delegate was deallocated (L12)") }
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        return body(delegate)
    }

    /// L9: no update from inside a callback, and none but through the proxy
    /// inside a batch.
    private func requireOutsideCallbacks(_ what: String) {
        precondition(callbackDepth == 0, "ExactList: \(what) called from inside a data source or delegate call (L9)")
        precondition(openBatch == nil, "ExactList: \(what) called inside a batch; use its Updates (L9)")
    }

    private func renumberAccessibilityElements(through map: RowIndexMap) {
        var renumbered: [Int: UnmountedRowElement] = [:]
        for (row, element) in accessibilityElements {
            guard let now = map.newIndex(forOld: row) else { continue }
            element.row = now
            renumbered[now] = element
        }
        accessibilityElements = renumbered
    }
}

// MARK: - Collaborators (SPEC §15): each reports through its own protocol.

extension ExactListView: ListScrollViewOwner {

    /// W1, V1, V2: a width change, a viewport change, or neither.
    ///
    /// Re-entrant by nature: measuring here changes `H`, which resizes the
    /// document, which can tile again. A private flag makes the inner call a
    /// no-op; the outer one finishes against the final frame.
    func scrollViewDidTile(_ scrollView: ListScrollView) {
        guard !isAdjusting else { return }
        if isLoaded { syncViewport() } else { loadIfReady() }
    }
}

extension ExactListView: ListClipViewOwner {

    /// P1, W4, A8: mount against the new `P`, measuring stale rows first, and
    /// re-evaluate tail following. A scroll that isn't the list's own ends an
    /// animated scroll where it is (S3).
    func clipViewDidScroll(_ clipView: ListClipView) {
        guard isLoaded, !isAdjusting else { return }
        animator.cancelScroll()
        didScroll()
    }
}

extension ExactListView: ListDocumentViewOwner {

    /// K1. The delegate's answer is an event handler, not a callback of a
    /// commit, so it is called outside L9's guard: the host may update and
    /// scroll the list from it, as from `textView(_:doCommandBy:)`.
    func documentView(_ documentView: ListDocumentView, doCommandBy selector: Selector) -> Bool {
        guard let delegate else { preconditionFailure("ExactList: the delegate was deallocated (L12)") }
        if delegate.listView(self, doCommandBy: selector) { return true }
        guard isLoaded else { return false }
        let line = scrollView.verticalLineScroll
        let page = committed.unobscuredBottom - committed.unobscuredTop - scrollView.verticalPageScroll
        let contentHeight = heights.contentHeight
        let target: CGFloat
        switch selector {
        case #selector(NSResponder.scrollLineUp(_:)), #selector(NSResponder.moveUp(_:)):
            target = committed.offset - line
        case #selector(NSResponder.scrollLineDown(_:)), #selector(NSResponder.moveDown(_:)):
            target = committed.offset + line
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            target = committed.offset - page
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            target = committed.offset + page
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            target = committed.minOffset
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            target = committed.maxOffset(contentHeight: contentHeight)
        default:
            return false
        }
        scroll(to: committed.clamped(target, contentHeight: contentHeight))
        return true
    }

    func documentView(_ documentView: ListDocumentView, prepareContentIn rect: NSRect) {
        appKitPrepared = rect
        guard isLoaded, !isAdjusting else { return }
        remount()
    }

    func numberOfAccessibilityRows(in documentView: ListDocumentView) -> Int {
        numberOfRows
    }

    func documentView(_ documentView: ListDocumentView, accessibilityRowAt row: Int) -> Any {
        if let container = placement.container(forRow: row) { return container }
        if let element = accessibilityElements[row] { return element }
        let element = UnmountedRowElement(row: row, parent: documentView)
        element.owner = self
        accessibilityElements[row] = element
        return element
    }

    func accessibilityVisibleRows(in documentView: ListDocumentView) -> Range<Int> {
        guard isLoaded else { return 0..<0 }
        return heights.rows(intersecting: committed.unobscuredTop, committed.unobscuredBottom)
    }
}

extension ExactListView: RowPlacementOwner {

    func placement(_ placement: RowPlacement, viewForRow row: Int) -> NSView {
        callDelegate { $0.listView(self, viewForRow: row) }
    }

    func placement(_ placement: RowPlacement, reloadingRow row: Int, showing view: NSView) -> NSView {
        pool.enqueue(view)
        let replacement = callDelegate { $0.listView(self, viewForRow: row) }
        if replacement === view {
            pool.withdraw(view)
        } else {
            callDelegate { $0.listView(self, didRemove: view, forRow: row) }
        }
        return replacement
    }

    func placement(_ placement: RowPlacement, didRemove view: NSView, forRow row: Int) {
        callDelegate { $0.listView(self, didRemove: view, forRow: row) }
        pool.enqueue(view)
    }
}

extension ExactListView: MotionAnimatorOwner {

    /// S3: one frame of an animated scroll, which is a scroll like the
    /// reader's, except that it is the list's own.
    func motionAnimator(_ animator: MotionAnimator, scrollTo offset: CGFloat) {
        guard isLoaded else { return }
        adjusting { moveClip(to: committed.clamped(offset, contentHeight: heights.contentHeight)) }
        didScroll()
    }

    /// The retired containers wait in the document for the placement that
    /// follows, which gives them to arriving rows or hides them.
    func motionAnimator(_ animator: MotionAnimator, didFinishCommitRetiring retired: [RowContainerView]) {
        for container in retired { placement.retire(container) }
        remount()
    }
}

extension ExactListView: StaleRowRefresherOwner {

    func refreshStaleRows(within budget: TimeInterval) -> Bool {
        guard isLoaded, !stale.isEmpty, width > 0 else { return false }
        let anchor = heights.firstRow(endingBelow: committed.unobscuredTop) ?? 0
        let started = ProcessInfo.processInfo.systemUptime
        var measured: [Int: CGFloat] = [:]
        for row in stale.refreshOrder(around: anchor, limit: 1024) {
            measured[row] = measure(row)
            if ProcessInfo.processInfo.systemUptime - started >= budget { break }
        }
        commit(map: identityMap(), measured: measured)
        return !stale.isEmpty
    }
}

extension ExactListView: UnmountedRowElementOwner {

    func screenFrame(ofAccessibilityRow row: Int) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect(ofRow: row), to: nil))
    }

    func scrollAccessibilityRowToVisible(_ row: Int) {
        scrollRowToVisible(row)
    }
}

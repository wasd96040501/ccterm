import AppKit
import ExactListCore

/// A vertical list of host views with exact geometry, anchored scrolling and
/// CoreAnimation motion. It uses `NSTableView`'s vocabulary. SPEC.md is
/// normative, and each member names the requirements it implements.
///
/// This is the only view a host mounts. It owns its scroll view, clip view and
/// document view, and none of them is public (L2). It loads by itself, at the
/// first layout that has a window and a width (L3, L4).
@MainActor
public final class ExactListView: NSView {

    /// Re-exported from Core so a host needs only `import ExactList`.
    public typealias Anchoring = ExactListCore.Anchoring

    // MARK: - Lifecycle (§4)

    /// L1: both are held weakly and can't be replaced afterwards. Nothing is
    /// asked of either before the load point (L3).
    public init(dataSource: ExactListViewDataSource, delegate: ExactListViewDelegate) {
        fatalError("unimplemented: SPEC L1, L2")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// L1. Weak, the AppKit ownership, and never reassigned.
    public private(set) weak var dataSource: ExactListViewDataSource?

    /// L1. Weak, the AppKit ownership, and never reassigned.
    public private(set) weak var delegate: ExactListViewDelegate?

    public override var isFlipped: Bool { true }

    public override func layout() {
        fatalError("unimplemented: SPEC L3, L4, L7")
    }

    public override func viewDidMoveToWindow() {
        fatalError("unimplemented: SPEC L8")
    }

    // MARK: - Configuration (§6.4)

    /// `s`, the gap between two rows. Named after `NSGridView.rowSpacing`. A
    /// change is an anchored commit that doesn't animate (V3). Default 0.
    public var rowSpacing: CGFloat {
        get { fatalError("unimplemented: SPEC V3") }
        set { fatalError("unimplemented: SPEC V3") }
    }

    /// `NSScrollView.contentInsets`. A change is an anchored commit that doesn't
    /// animate, and the tail stays the tail (V2).
    public var contentInsets: NSEdgeInsets {
        get { fatalError("unimplemented: SPEC V2") }
        set { fatalError("unimplemented: SPEC V2") }
    }

    /// Whether the viewport stays at the end as rows arrive and grow while it
    /// sits there (A1, A8). Default `false`, the `NSTableView` behaviour.
    public var automaticallyFollowsTail: Bool {
        get { fatalError("unimplemented: SPEC V4") }
        set { fatalError("unimplemented: SPEC V4") }
    }

    /// A8: `automaticallyFollowsTail`, and the viewport at the tail.
    public var isFollowingTail: Bool {
        fatalError("unimplemented: SPEC A8")
    }

    // MARK: - Rows (§7)

    /// `n`. 0 before the load point (L5).
    public var numberOfRows: Int {
        fatalError("unimplemented: SPEC L5")
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
        fatalError("unimplemented: SPEC U1, U3, U8")
    }

    /// `NSTableView.insertRows(at:withAnimation:)`: a batch of one (U4).
    public func insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        fatalError("unimplemented: SPEC U4")
    }

    /// `NSTableView.removeRows(at:withAnimation:)`: a batch of one (U4).
    public func removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        fatalError("unimplemented: SPEC U4")
    }

    /// `NSTableView.moveRow(at:to:)`: a batch of one (U4).
    public func moveRow(at oldIndex: Int, to newIndex: Int) {
        fatalError("unimplemented: SPEC U4")
    }

    /// `NSTableView.reloadData(forRowIndexes:columnIndexes:)`, without the
    /// columns: asks the mounted rows among `indexes` for their views again.
    /// Heights are not asked (U6).
    public func reloadData(forRowIndexes indexes: IndexSet) {
        fatalError("unimplemented: SPEC U6")
    }

    /// `NSTableView.noteHeightOfRows(withIndexesChanged:)`: asks these rows for
    /// their height again at commit. Animated unless inside a duration-0 group,
    /// as in a view-based table (M1).
    public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        fatalError("unimplemented: SPEC U4, U5")
    }

    /// `NSTableView.reloadData()`: everything asked for again, never animated
    /// (U7, A9).
    public func reloadData() {
        fatalError("unimplemented: SPEC U7")
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
        fatalError("unimplemented: SPEC P4")
    }

    /// The mounted view for `row`, or `nil` (P7).
    ///
    /// *Deviation:* there is no `makeIfNecessary`, because building a view for
    /// a row that isn't mounted would break P1.
    public func view(atRow row: Int) -> NSView? {
        fatalError("unimplemented: SPEC P7")
    }

    /// The row of a mounted view or any of its descendants, else −1
    /// (`NSTableView.row(for:)`, P6).
    public func row(for view: NSView) -> Int {
        fatalError("unimplemented: SPEC P6")
    }

    /// Every mounted row's view, with its row
    /// (`NSTableView.enumerateAvailableRowViews(_:)`). Views that are animating
    /// out are not included.
    public func enumerateAvailableRowViews(_ body: (NSView, Int) -> Void) {
        fatalError("unimplemented: SPEC P1")
    }

    // MARK: - Geometry (§5), in this view's own flipped coordinates

    /// G4: `NSTableView.rect(ofRow:)`, in this view's coordinates. `.zero` when
    /// out of range, or before the load point.
    public func rect(ofRow row: Int) -> NSRect {
        fatalError("unimplemented: SPEC G4")
    }

    /// G4: `NSTableView.row(at:)`. −1 in a spacing gap, outside the rows, or
    /// before the load point.
    public func row(at point: NSPoint) -> Int {
        fatalError("unimplemented: SPEC G4")
    }

    /// G4: `NSTableView.rows(in:)`, as a `Range<Int>`.
    public func rows(in rect: NSRect) -> Range<Int> {
        fatalError("unimplemented: SPEC G4")
    }

    // MARK: - Scrolling (§11)

    /// S1: the least scroll that brings `row` fully into view, or its top when
    /// it is taller than the view. Animated only under `allowsImplicitAnimation`
    /// (M1).
    public func scrollRowToVisible(_ row: Int) {
        fatalError("unimplemented: SPEC S1")
    }

    /// S2: aligns `row` to `.top`, `.centeredVertically`, `.bottom` or
    /// `.nearestHorizontalEdge`, clamped to the scroll range.
    ///
    /// *Deviation:* `NSTableView` has no landing position; this is
    /// `NSCollectionView.scrollToItems(at:scrollPosition:)`'s shape.
    public func scrollToRow(_ row: Int, at position: NSCollectionView.ScrollPosition) {
        fatalError("unimplemented: SPEC S2")
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
        fatalError("unimplemented: SPEC W1, V1, V2")
    }
}

extension ExactListView: ListClipViewOwner {

    /// P1, W4, A8: mount against the new `P`, measuring stale rows first, and
    /// re-evaluate tail following.
    func clipViewDidScroll(_ clipView: ListClipView) {
        fatalError("unimplemented: SPEC P1, W4, A8")
    }
}

extension ExactListView: ListDocumentViewOwner {

    func documentView(_ documentView: ListDocumentView, doCommandBy selector: Selector) -> Bool {
        fatalError("unimplemented: SPEC K1")
    }

    func documentView(_ documentView: ListDocumentView, prepareContentIn rect: NSRect) {
        fatalError("unimplemented: SPEC P1")
    }

    func numberOfAccessibilityRows(in documentView: ListDocumentView) -> Int {
        fatalError("unimplemented: SPEC X1")
    }

    func documentView(_ documentView: ListDocumentView, accessibilityRowAt row: Int) -> Any {
        fatalError("unimplemented: SPEC X2, X3")
    }

    func accessibilityVisibleRows(in documentView: ListDocumentView) -> Range<Int> {
        fatalError("unimplemented: SPEC X1")
    }
}

extension ExactListView: RowPlacementOwner {

    func placement(_ placement: RowPlacement, viewForRow row: Int) -> NSView {
        fatalError("unimplemented: SPEC P2")
    }

    func placement(_ placement: RowPlacement, didRemove view: NSView, forRow row: Int) {
        fatalError("unimplemented: SPEC P3")
    }
}

extension ExactListView: MotionAnimatorOwner {

    func motionAnimator(_ animator: MotionAnimator, didFinishCommitRetiring retired: [RowContainerView]) {
        fatalError("unimplemented: SPEC M10, P3")
    }
}

extension ExactListView: StaleRowRefresherOwner {

    func refreshStaleRows(within budget: TimeInterval) -> Bool {
        fatalError("unimplemented: SPEC W5")
    }
}

extension ExactListView: UnmountedRowElementOwner {

    func screenFrame(ofAccessibilityRow row: Int) -> NSRect {
        fatalError("unimplemented: SPEC X2")
    }

    func scrollAccessibilityRowToVisible(_ row: Int) {
        fatalError("unimplemented: SPEC X3")
    }
}

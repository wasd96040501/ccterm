import AppKit

/// A vertically scrolling chat transcript driven by a data source, in the
/// style of `NSTableView`.
///
/// This is the package's only view. The data source answers row count and
/// content (`TranscriptRowContent`); the host announces every data mutation
/// through `insertRows` / `removeRows` / `reloadRows` (or `reloadData`), and
/// invalidates a height that changed on its own through
/// `noteHeightOfRows(withIndexesChanged:)`.
///
/// ## Composition
///
/// Inside is an `NSTableView` in an `NSScrollView`, its content centred.
///
/// `TranscriptView` is that table's data source and delegate. Rows carrying
/// `.markdown` / `.userMessage` / `.image` it answers itself — measuring and
/// drawing them; `.view` rows it forwards to the host's
/// `TranscriptViewDelegate` (`heightOfRow`, `viewForRow`).
///
/// `NSTableView` asks every row for its height, not just the visible ones.
/// Hosts absorb that by inserting in batches spread over several main-queue
/// hops instead of in one call — see §5 of the package's CLAUDE.md.
///
/// Rows drawn by host views recycle: the transcript keeps roughly a
/// screenful of instances alive and cycles them across rows as the user
/// scrolls, so transcript length costs rows, not views. The host takes part
/// through `makeView(withIdentifier:make:)` inside its delegate's
/// `viewForRow`, and — if a view starts anything that must be stopped —
/// `TranscriptViewDelegate.transcriptView(_:didRemove:forRow:)`.
///
/// ## Scroll anchoring
///
/// Changing row geometry never moves what the reader is looking at. Two
/// rules, both built in, neither configurable:
///
/// 1. **Sitting at the bottom — follow the tail.** Appended rows and growing
///    content keep the newest content visible.
/// 2. **Anywhere else — hold the viewport still.** The transcript compensates
///    its scroll offset for geometry changes landing *above* the visible
///    content, and leaves changes below it alone. Prepending a page of
///    history, or a row above the viewport growing taller, doesn't shift what
///    is on screen.
///
/// Which rule applies is decided by where the scroll offset is *right now*,
/// never by which method last ran. A user dragging to the bottom re-engages
/// tail following exactly the way an explicit scroll to the last row does;
/// there is no flag being set and nothing to keep in sync.
///
/// Both rules cover every mutation that moves row geometry — `insertRows`,
/// `removeRows`, `reloadRows`, `noteHeightOfRows`. `scrollToRow(at:scrollPosition:)`
/// is the deliberate exception: it means "leave where you are and go here."
///
/// `NSTableView` promises none of this. Its `insertRows(at:withAnimation:)`
/// documents only that `numberOfRows` grows, and says nothing about the scroll
/// offset — so inserting above the viewport shifts the content under the
/// reader. That is fine for the lists it was built for, where the top is
/// stable; a transcript grows upward, so it isn't. No platform's stock list
/// control solves this (UIKit and RecyclerView both leave it to the caller,
/// and the web only got `overflow-anchor` recently), which is why the
/// behaviour is defined here rather than inherited.
///
/// All API is main-thread only. The view embeds its own scroller — install
/// it directly with Auto Layout; do not wrap it in another `NSScrollView`.
@MainActor
public final class TranscriptView: NSView {

    /// Row mutation animations, mirroring `NSTableView.AnimationOptions`.
    public struct AnimationOptions: OptionSet, Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// Fade the affected rows in (insert) or out (remove).
        public static let effectFade = AnimationOptions(rawValue: 1 << 0)

        /// Slide the affected rows in from above, or out upwards.
        public static let slideUp = AnimationOptions(rawValue: 1 << 1)

        /// Slide the affected rows in from below, or out downwards.
        public static let slideDown = AnimationOptions(rawValue: 1 << 2)
    }

    /// Where a row lands when scrolled to — the vertical half of
    /// `NSCollectionView.ScrollPosition`, as an enum.
    ///
    /// AppKit models this as an `OptionSet` so that one vertical and one
    /// horizontal position can be or-ed together, and then has to warn in the
    /// header that combining two from the *same* group raises
    /// `NSInvalidArgumentException`. A transcript is one column scrolling one
    /// axis, so the choice is genuinely four-way; an enum says that outright
    /// instead of deferring it to a runtime trap. AppKit's `.none` is dropped
    /// for a related reason: it exists because `selectItems(at:scrollPosition:)`
    /// reuses the type to mean "select without scrolling," which has no
    /// meaning as an argument to a method named `scrollToRow`.
    public enum ScrollPosition {

        /// The row's top edge at the viewport's top. AppKit: `.top`.
        case top

        /// The row centred in the viewport. AppKit: `.centeredVertically` —
        /// the axis suffix carries no information on a single-axis view.
        case center

        /// The row's bottom edge at the viewport's bottom. AppKit: `.bottom`.
        case bottom

        /// Scroll the least amount that brings the row fully into view;
        /// no movement if it already is.
        ///
        /// AppKit spells this `.nearestHorizontalEdge` and has to gloss it
        /// "Nearer of Top,Bottom" — the name describes the *edges* being
        /// horizontal, which reads backwards outside a two-axis view, so the
        /// axis word is dropped here. Equivalent to
        /// `NSTableView.scrollRowToVisible(_:)`, which is therefore not
        /// offered separately.
        case nearestEdge
    }

    // MARK: - Collaborators

    /// The single source of truth for row count and content. Held weakly and
    /// re-queried on demand; setting it does not refresh the view — call
    /// `reloadData()` after wiring.
    public weak var dataSource: TranscriptViewDataSource?

    /// Answers how rows look, and observes display-side events.
    public weak var delegate: TranscriptViewDelegate?

    // MARK: - Row answers

    /// The cell `viewForRow` is currently filling, so that `makeView` can hand
    /// back the hosted view already inside it. Non-nil only for the duration of
    /// that delegate call.
    private var configuringCell: TranscriptCellView?

    /// How tall row `row` is. `.view` rows are the delegate's to measure; the
    /// three the transcript draws itself measure to nothing until the typesetter
    /// lands.
    fileprivate func height(ofRow row: Int) -> CGFloat {
        guard case .view = dataSource?.transcriptView(self, contentForRow: row),
            let delegate
        else { return 0 }
        return delegate.transcriptView(self, heightOfRow: row, width: contentWidth)
    }

    /// The cell for row `row`: the transcript's own cell view, with the hosted
    /// view inside it. `nil` for the rows the transcript draws itself, which have
    /// nothing to draw yet.
    fileprivate func view(forRow row: Int) -> NSView? {
        guard case .view = dataSource?.transcriptView(self, contentForRow: row),
            let delegate
        else { return nil }

        let cell =
            tableView.makeView(withIdentifier: TranscriptCellView.identifier, owner: nil)
            as? TranscriptCellView ?? TranscriptCellView()

        configuringCell = cell
        defer { configuringCell = nil }
        let hosted = delegate.transcriptView(self, viewForRow: row)

        cell.install(hosted, minWidth: minContentWidth, maxWidth: maxContentWidth)
        return cell
    }

    /// Reports the row leaving the viewport. What goes back into the pool is the
    /// cell, but what the host has work to stop on is the view it supplied — so
    /// that is what it hears about.
    fileprivate func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? TranscriptCellView,
            let hosted = cell.hostedView
        else { return }
        delegate?.transcriptView(self, didRemove: hosted, forRow: row)
    }

    // MARK: - Table

    /// Full width on purpose: the wheel has to keep working over the side
    /// margins that centred content leaves, and the overlay scroller belongs at
    /// the window's edge — so centring cannot come from narrowing this.
    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        // Legacy scrollers only — with "always show scroll bars" on, a
        // transcript shorter than the viewport would otherwise hang a disabled
        // scroller there and take 15pt of content width for it.
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The host owns the background; the transcript draws none of its own.
        scroll.drawsBackground = false
        // Left true, AppKit rewrites `contentInsets` on every tile to clear an
        // overlapping title bar — silently reverting the insets the host set to
        // clear its own overlays, one resize later.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        // No selection API on the transcript, so no selection to draw.
        table.selectionHighlightStyle = .none
        // Rows are measured edge to edge; spacing between them belongs to the
        // content, not to the table.
        table.intercellSpacing = .zero
        // Already the default, and stated anyway because it picks the height
        // model: left on, the table measures cell views with Auto Layout and
        // never asks for a row height at all.
        table.usesAutomaticRowHeights = false
        // `.automatic` resolves to a style that insets rows and rounds the
        // selection — the transcript wants the row it measured.
        if #available(macOS 11.0, *) { table.style = .plain }
        table.addTableColumn(NSTableColumn(identifier: Self.columnIdentifier))
        return table
    }()

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("TranscriptKit.column")

    /// Answers the table's data source and delegate callbacks on the
    /// transcript's behalf, so that AppKit's table protocols stay off the
    /// package's public surface — and so a host can't be handed the transcript
    /// as a data source for a table of its own. Owned here; the table refers to
    /// it weakly.
    private lazy var tableAdapter = TableAdapter(transcript: self)

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Hierarchy.
        scrollView.documentView = tableView
        addSubview(scrollView)

        // Constraints.
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Safe before any content exists: the row count is 0 until the host
        // calls `reloadData()`, so the queries this provokes cost nothing.
        tableView.dataSource = tableAdapter
        tableView.delegate = tableAdapter

        // Every source that can move the content width lands on the table's
        // frame, so watching that one thing covers all of them — window and
        // split-view resizes, a scroller appearing, `contentInsets`. Watching
        // this view's own frame instead would miss the scroller, which changes
        // the clip's width without changing ours.
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(tableViewFrameDidChange),
            name: NSView.frameDidChangeNotification, object: tableView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TranscriptView is code-only; init(coder:) is unavailable")
    }

    // MARK: - Row access

    /// The number of rows the view currently knows about — the data source's
    /// answer as of the last `reloadData()` / mutation call.
    public var numberOfRows: Int {
        tableView.numberOfRows
    }

    /// The row currently displaying `view`, or `-1` when the transcript is not
    /// showing it.
    ///
    /// Recycling makes the view↔row binding temporary, and insertions and
    /// removals shift indices under a view that is standing still — so a
    /// hosted view that needs to invalidate its own height (a disclosure
    /// opening, an image finishing its decode) has to ask rather than reuse
    /// the index it was handed at configure time. Mirrors
    /// `NSTableView.row(for:)`.
    public func row(for view: NSView) -> Int {
        tableView.row(for: view)
    }

    // MARK: - Content width

    /// The narrowest the content column is allowed to get, default `0`.
    ///
    /// Below this the content stops following the viewport and stays centred,
    /// with its edges clipped — the trade a layout makes when it has a width it
    /// cannot usefully go under (a table, a code block). `0` means it always
    /// follows.
    public var minContentWidth: CGFloat = 0 {
        didSet { contentWidthBoundsChanged() }
    }

    /// The widest the content column is allowed to get, default unbounded.
    ///
    /// Past this the window keeps the extra space as margin and the content
    /// stays centred, which is also where resizing gets cheap: the content width
    /// stops changing, so no row's height goes stale.
    public var maxContentWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { contentWidthBoundsChanged() }
    }

    /// The width the transcript's content currently occupies: the row width
    /// clamped into `minContentWidth ... maxContentWidth`.
    ///
    /// Read-only because it is derived, the way `NSTableColumn.width` is derived
    /// from its own bounds while `minWidth` / `maxWidth` are the settable pair.
    /// This is the number `heightOfRow` is asked against and the number the
    /// hosted view is laid out at.
    public var contentWidth: CGFloat {
        TranscriptCellView.contentWidth(
            forRowWidth: tableView.bounds.width,
            minWidth: minContentWidth,
            maxWidth: maxContentWidth)
    }

    /// The content width the currently cached row heights were measured at.
    /// `.nan` compares unequal to everything, so the first check invalidates.
    private var measuredContentWidth: CGFloat = .nan

    /// Set when a live resize re-measured only the rows on screen; the rest
    /// still carry heights from an earlier width, caught on mouse-up.
    private var hasStaleOffscreenHeights = false

    private func contentWidthBoundsChanged() {
        // Live cells hold the bounds they were installed with.
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? TranscriptCellView)?.updateContentWidthBounds(
                minWidth: minContentWidth, maxWidth: maxContentWidth)
        }
        contentWidthDidChange()
    }

    /// Re-measures the rows whose height was answered at a width that no longer
    /// applies.
    ///
    /// The delegate is asked `heightOfRow(_:width:)` and answers for *that*
    /// width; the width is the transcript's, derived from its own bounds, so a
    /// host has no way to notice it moved. `NSTableView` won't re-ask either —
    /// its `heightOfRow` takes no width, so a row height is a constant as far
    /// as the table is concerned. Which leaves this.
    ///
    /// The comparison is against the *clamped* width, not the table's: past
    /// `maxContentWidth` the number handed to the delegate stops moving, so a
    /// window resize above the clamp invalidates nothing at all.
    private func contentWidthDidChange() {
        let width = contentWidth
        guard width != measuredContentWidth else { return }
        measuredContentWidth = width
        guard numberOfRows > 0 else { return }

        // `noteHeightOfRows` re-asks the delegate for every index it is handed,
        // so a full pass is O(rows) — nothing once, a freeze sixty times a
        // second through a drag. Mid-drag only the rows on screen are
        // re-measured, and the offsets that shifts settle on mouse-up.
        guard inLiveResize else {
            hasStaleOffscreenHeights = false
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
            return
        }
        hasStaleOffscreenHeights = true
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
    }

    @objc private func tableViewFrameDidChange(_ notification: Notification) {
        contentWidthDidChange()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard hasStaleOffscreenHeights, numberOfRows > 0 else { return }
        hasStaleOffscreenHeights = false
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
    }

    // MARK: - Geometry

    /// Margins added to the scrollable range, for host chrome the transcript
    /// scrolls underneath. Mirrors `NSScrollView.contentInsets`.
    ///
    /// This does **not** shrink the transcript: rows stay full-bleed and pass
    /// under the chrome as they scroll, which is what lets a host blur or fade
    /// over live content. What it adds is room at the ends of the scroll — so a
    /// bottom inset of an input bar's height plus a gap makes the last row come
    /// to rest above that bar instead of behind it.
    ///
    /// The host owns these. A floating input bar that changes height reports the
    /// new height up to its controller, and the controller writes the inset here
    /// in the same pass — nothing in the transcript watches for chrome.
    ///
    /// Writing this re-tiles, so compare before assigning if the call site can
    /// run on every layout pass.
    public var contentInsets: NSEdgeInsets {
        get { scrollView.contentInsets }
        set {
            scrollView.contentInsets = newValue
            // Content and scrollers inset separately; without this the knob's
            // track still runs to the edge and disappears behind the chrome.
            scrollView.scrollerInsets = newValue
        }
    }

    /// The rectangle the given row occupies, in the scrolled content's
    /// coordinate space — row 0 at `y == 0`, growing downwards, unaffected by
    /// the scroll offset; `NSZeroRect` for an out-of-range row or one the first
    /// layout pass hasn't placed yet. `NSTableView.rect(ofRow:)`'s space and
    /// values exactly.
    ///
    /// Spans the full row width, insets included; the content inside is
    /// narrower by those insets. There is no `frameOfCell(atColumn:row:)`
    /// counterpart, because that method's whole job is picking one column out
    /// of a row and a transcript has no columns.
    public func rect(ofRow row: Int) -> NSRect {
        tableView.rect(ofRow: row)
    }

    // MARK: - View row recycling

    /// Returns a view previously used by a `.view` row and since retired, or
    /// builds a fresh one with `make` when nothing is pooled under
    /// `identifier`. The recycling counterpart to
    /// `NSTableView.makeView(withIdentifier:owner:)`.
    ///
    /// Call this from `TranscriptViewDelegate.transcriptView(_:viewForRow:)`
    /// and nowhere else — taking an instance outside that call takes one the
    /// transcript is still counting on. The transcript tags what it hands back
    /// with `identifier` itself, so a view always finds its way home to the
    /// right pool: no registration step, and no `identifier` the host has to
    /// remember to assign (forgetting that on `NSTableView` is what silently
    /// disables recycling there).
    ///
    /// One identifier means one view type. `V` is resolved at the call site,
    /// so the host writes no `as?` cast and pooling two types under one
    /// identifier fails loudly rather than mis-rendering.
    public func makeView<V: NSView>(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        make: () -> V
    ) -> V {
        // Hosted views ride inside the cell the table pooled, so the pool to
        // look in is the cell currently being configured — hosted views never
        // become cell views themselves, so the table's own reuse queue never
        // sees them.
        guard let cell = configuringCell else {
            assertionFailure(
                "makeView(withIdentifier:make:) called outside "
                    + "transcriptView(_:viewForRow:); nothing is being configured, so nothing "
                    + "can be recycled.")
            let view = make()
            view.identifier = identifier
            return view
        }
        if let pooled = cell.hostedView, pooled.identifier == identifier {
            guard let view = pooled as? V else {
                preconditionFailure(
                    "Identifier \(identifier.rawValue) pooled a \(type(of: pooled)), but this call "
                        + "asked for a \(V.self). One identifier means one view type.")
            }
            return view
        }
        let view = make()
        view.identifier = identifier
        return view
    }

    // MARK: - Data mutations

    /// Discards all row state and re-queries the data source from scratch.
    ///
    /// This is the coarse path — it drops every measured height and rebuilds
    /// every visible row. For incremental changes, prefer the index-based
    /// mutations below.
    ///
    /// Nothing is laid out or scrolled inside the call: it marks state stale
    /// and the work lands on the next layout pass. That is what makes
    ///
    /// ```swift
    /// transcript.reloadData()
    /// transcript.scrollToRow(at: anchorRow, scrollPosition: .center)
    /// ```
    ///
    /// atomic — both take effect in the same pass, with no frame in between
    /// showing the transcript somewhere else. Scroll anchoring does not apply
    /// across a reload (every row is new, so there is no anchor to hold); the
    /// transcript lands at the tail unless a `scrollToRow` in the same tick
    /// says otherwise.
    public func reloadData() {
        tableView.reloadData()
    }

    /// Announces rows newly inserted at `indexes` (positions in the
    /// post-mutation data source).
    public func insertRows(at indexes: IndexSet, withAnimation animation: AnimationOptions = []) {
        tableView.insertRows(at: indexes, withAnimation: animation.tableViewOptions)
    }

    /// Announces rows removed at `indexes` (positions in the pre-mutation
    /// data source).
    public func removeRows(at indexes: IndexSet, withAnimation animation: AnimationOptions = []) {
        tableView.removeRows(at: indexes, withAnimation: animation.tableViewOptions)
    }

    /// Announces in-place content changes: the rows at `indexes` are
    /// re-queried from the data source and re-rendered, keeping row identity.
    /// Heights are re-resolved too — a self-sizing row is re-measured, a
    /// `.view` row is re-asked through the delegate's `heightOfRow`.
    public func reloadRows(at indexes: IndexSet) {
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        // `reloadData(forRowIndexes:)` re-asks for the row's view but keeps the
        // height it already has, and changed content is a different height.
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
    }

    /// Invalidates the cached heights of the rows at `indexes` without
    /// re-rendering them: self-sizing rows are re-measured, and `.view` rows
    /// are re-asked through the delegate's `heightOfRow`, on the next layout
    /// pass. Mirrors `NSTableView.noteHeightOfRows(withIndexesChanged:)`.
    ///
    /// Only needed when a height changed but the content did not — a hosted
    /// view opening a disclosure, say. `reloadRows(at:)` already re-resolves
    /// height, and a content-width change is handled by the transcript
    /// itself; neither needs this call.
    public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
    }

    // MARK: - Batching

    /// Begins coalescing mutation calls into one layout pass; pair with
    /// `endUpdates()`. Mirrors `NSTableView.beginUpdates()`.
    ///
    /// The scroll anchor is sampled here and restored at `endUpdates()`, so a
    /// batch holds the viewport still **once** for the whole group instead of
    /// once per call — which is what makes "insert two runs and delete a
    /// third" land on a single, well-defined offset. A mutation outside any
    /// batch samples and restores around itself.
    public func beginUpdates() {
        tableView.beginUpdates()
    }

    /// Ends a `beginUpdates()` group, applies the coalesced mutations, and
    /// restores the scroll anchor sampled at `beginUpdates()`.
    public func endUpdates() {
        tableView.endUpdates()
    }

    // MARK: - Scrolling

    /// Scrolls so the row at `row` lands at `scrollPosition`. Mirrors
    /// `NSCollectionView.scrollToItems(at:scrollPosition:)`, narrowed to a
    /// single row.
    ///
    /// This is the one deliberate break in scroll anchoring: every other
    /// geometry change holds the viewport still, this one moves it on purpose.
    /// Landing on the last row at `.bottom` re-engages tail following — but
    /// only as a consequence of leaving the offset at the bottom, not because
    /// this method sets anything.
    ///
    /// Animation follows AppKit convention rather than a parameter: wrap the
    /// call in `NSAnimationContext.runAnimationGroup`.
    ///
    /// `NSTableView` has no counterpart. Its entire scroll surface is
    /// `scrollRowToVisible(_:)` / `scrollColumnToVisible(_:)`, neither of
    /// which can express a landing position — so the shape is borrowed from
    /// `NSCollectionView`, and `scrollRowToVisible`'s behaviour is folded in
    /// as `.nearestEdge`.
    public func scrollToRow(at row: Int, scrollPosition: ScrollPosition) {
    }
}

/// `NSTableView`'s data source and delegate, forwarded to a `TranscriptView`.
///
/// Not a conformance on `TranscriptView` itself: that type is public, so the
/// conformance would be too, putting AppKit's table callbacks on the package's
/// surface next to three near-identically named row-count methods. Holds the
/// transcript weakly — the transcript owns this, the table only refers to it.
@MainActor
private final class TableAdapter: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var transcript: TranscriptView?

    init(transcript: TranscriptView) {
        self.transcript = transcript
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let transcript else { return 0 }
        return transcript.dataSource?.numberOfRows(in: transcript) ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        transcript?.height(ofRow: row) ?? 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        transcript?.view(forRow: row)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        transcript?.didRemove(rowView, forRow: row)
    }
}

extension TranscriptView.AnimationOptions {

    /// The `NSTableView` options these stand for — same bits, one type per layer
    /// so the package's surface doesn't hand out AppKit's.
    fileprivate var tableViewOptions: NSTableView.AnimationOptions {
        var options: NSTableView.AnimationOptions = []
        if contains(.effectFade) { options.insert(.effectFade) }
        if contains(.slideUp) { options.insert(.slideUp) }
        if contains(.slideDown) { options.insert(.slideDown) }
        return options
    }
}

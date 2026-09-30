import AppKit
import ExactList

/// A vertically scrolling chat transcript driven by a data source, in the
/// style of `NSTableView`.
///
/// This is the package's only view. The data source answers row count and
/// content (`TranscriptRowContent`); the host announces every data mutation
/// through `insertRows` / `removeRows` / `reloadRows` (or `reloadData`), groups
/// them with `performBatchUpdates`, and invalidates a height that changed on its
/// own through `noteHeightOfRows(withIndexesChanged:)`.
///
/// ## Composition
///
/// Inside is an `ExactListView`: exact row heights, anchored scrolling, and row
/// motion on AppKit's animation engine. Its spec (`ExactList/SPEC.md`) is where
/// geometry, anchoring and motion are defined; this view adds what a transcript
/// is on top of it.
///
/// `TranscriptView` answers the list's data source and delegate (through
/// `ListAdapter`). Rows carrying `.markdown` / `.userMessage` it answers itself —
/// measuring and drawing them; `.view` rows it forwards to the host's
/// `TranscriptViewDelegate` (`heightOfRow`, `viewForRow`).
///
/// What is not list glue lives in collaborators it owns: `FindSession` (a
/// find), `SelectionTracker` (the text selection) and `RemeasureScheduler` (the
/// off-main re-measure after a width change), with `RowCache` holding the
/// measurements all of them share.
///
/// The list asks for the height of **every** row when it loads and on
/// `reloadData()`, and measures exactly. A host loading thousands of rows
/// measures them off the main actor first (`prepareRows(_:)`) — see §5 of the
/// package's CLAUDE.md.
///
/// Rows drawn by host views recycle: the transcript keeps roughly a screenful
/// of instances alive and cycles them across rows as the user scrolls. The host
/// takes part through `makeView(withIdentifier:make:)` inside its delegate's
/// `viewForRow`, and — if a view starts anything that must be stopped —
/// `TranscriptViewDelegate.transcriptView(_:didRemove:forRow:)`.
///
/// ## Scroll anchoring
///
/// Changing row geometry never moves what the reader is looking at, unless the
/// host asks. At the tail, the transcript follows it: appended rows and growing
/// content keep the newest content visible. Anywhere else a mutation holds the
/// first visible row still, and `performBatchUpdates(anchoring:_:)` can name
/// another row instead — the one the reader clicked. `scrollToRow` is the
/// deliberate exception: it means "leave where you are and go here."
///
/// All API is main-thread only. The view embeds its own scroller — install it
/// directly with Auto Layout; do not wrap it in another `NSScrollView`.
@MainActor
public final class TranscriptView: NSView, NSUserInterfaceValidations {

    /// Where a row lands when scrolled to — the vertical half of
    /// `NSCollectionView.ScrollPosition`, as an enum.
    ///
    /// AppKit models this as an `OptionSet` so that one vertical and one
    /// horizontal position can be or-ed together, and then has to warn in the
    /// header that combining two from the *same* group raises
    /// `NSInvalidArgumentException`. A transcript is one column scrolling one
    /// axis, so the choice is genuinely four-way; an enum says that outright.
    public enum ScrollPosition {

        /// The row's top edge at the viewport's top. AppKit: `.top`.
        case top

        /// The row centred in the viewport. AppKit: `.centeredVertically`.
        case center

        /// The row's bottom edge at the viewport's bottom. AppKit: `.bottom`.
        case bottom

        /// Scroll the least amount that brings the row fully into view; no
        /// movement if it already is. AppKit: `.nearestHorizontalEdge`, which
        /// is `NSTableView.scrollRowToVisible(_:)`'s behaviour.
        case nearestEdge

        fileprivate var listPosition: NSCollectionView.ScrollPosition {
            switch self {
            case .top: .top
            case .center: .centeredVertically
            case .bottom: .bottom
            case .nearestEdge: .nearestHorizontalEdge
            }
        }
    }

    /// What a batch holds still on screen. `NSTableView` has no counterpart: it
    /// holds the scroll offset, and the content moves under the reader.
    public enum Anchoring: Equatable {

        /// The tail while the transcript is following it; otherwise the first
        /// visible row, at its current screen position.
        case automatic

        /// Row `r`, by its index before the batch, at its current screen
        /// position — how a host keeps the row the reader acted on under the
        /// pointer.
        case row(Int)

        fileprivate var listAnchoring: ExactListView.Anchoring {
            switch self {
            case .automatic: .automatic
            case .row(let row): .row(row)
            }
        }
    }

    // MARK: - Collaborators

    /// The single source of truth for row count and content. Held weakly and
    /// re-queried on demand; setting it does not refresh the view — call
    /// `reloadData()` after wiring.
    public weak var dataSource: TranscriptViewDataSource?

    /// Answers how rows look, and observes display-side events.
    public weak var delegate: TranscriptViewDelegate?

    // MARK: - The list

    /// Full width on purpose: the wheel has to keep working over the side
    /// margins that centred content leaves, and the scroller belongs at the
    /// edge — so centring is each row's (`TranscriptCellView`).
    private lazy var list: ExactListView = {
        let list = ExactListView(dataSource: listAdapter, delegate: listAdapter)
        list.rowSpacing = Self.rowSpacing
        list.automaticallyFollowsTail = true
        // Overlay whatever "Show scroll bars" says. The content is centred
        // within `maxContentWidth`, and a legacy scroller is a track carved out
        // of the viewport at the window's edge, far from the column: it shunts
        // the whole document off-centre. An overlay one floats over the margin
        // the centring already left.
        list.scrollerStyle = .overlay
        list.translatesAutoresizingMaskIntoConstraints = false
        return list
    }()

    /// Answers the list's data source and delegate on the transcript's behalf,
    /// so that the list's protocols stay off the package's public surface.
    /// Owned here; the list refers to it weakly.
    private lazy var listAdapter = ListAdapter(owner: self)

    /// The gap between two entries, unless the host gives a row its own
    /// (`transcriptView(_:customSpacingAboveRow:)`).
    ///
    /// A row's box is exactly its content — a document's first paragraph starts
    /// at the top edge and a hosted bubble ends at the bottom one — so nothing
    /// inside a row contributes to the gap, and the list adds all of it.
    ///
    /// Wider than the 12 two paragraphs of one document sit apart
    /// (`MarkdownBlockBuilder.blockSpacing`), because a row boundary is where
    /// the speaker changes and the hard-edged things that live in rows —
    /// bubbles, cards, images — have no glyph leading around them to read as
    /// part of the gap.
    private static let rowSpacing: CGFloat = 14

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(list)
        list.addFloatingSubview(findSession.overlay, for: .horizontal)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TranscriptView is code-only; init(coder:) is unavailable")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFocus()
    }

    // MARK: - Row answers

    /// The cell `viewForRow` is currently filling, so that `makeView` can hand
    /// back the hosted view already inside it. Non-nil only for the duration of
    /// that delegate call.
    private var configuringCell: TranscriptCellView?

    /// What each self-drawn row cost to build, so that the height answer and the
    /// view answer share one tree instead of each building their own.
    private let rowCache = RowCache()

    /// `row`'s content, built and measured at the current content width — or
    /// handed back from the cache, which is the usual case: the list asks for a
    /// height and then, for the rows it is about to show, a view. `nil` for
    /// content the transcript does not draw itself.
    ///
    /// **Nothing here names a recipe** — which case gets built how lives on the
    /// case, in `RowCache.Entry.init(measuring:width:reusing:)`, so that the
    /// background path and this one cannot describe a row differently.
    func measuredBlock(for row: TranscriptRow) -> MeasuredBlock? {
        rowCache.measured(for: row, width: contentWidth)
    }

    /// The list refuses a height that is not positive, and a host answering `0`
    /// for a collapsed row, a content case the transcript cannot draw, or a data
    /// source that went away while mounted can all produce one.
    private static let minimumRowHeight: CGFloat = 1

    /// The view a self-drawn row is served through, bound to `block`.
    ///
    /// Recycled through the cell it was already installed in, so a row
    /// scrolling back into view rebuilds no constraints. A fresh one only for a
    /// new cell — drawn rows have a pool of their own — and that is the one
    /// moment its delegate is set.
    private func blockView(
        in cell: TranscriptCellView, showing block: MeasuredBlock, forRow row: Int
    ) -> BlockView {
        let view = cell.hostedView as? BlockView ?? makeBlockView()
        view.configure(with: block)
        view.selectedRange = selectionTracker.range(inRow: row, length: block.length)
        boundRows.setObject(row as NSNumber, forKey: view)
        return view
    }

    private func makeBlockView() -> BlockView {
        let view = BlockView()
        view.delegate = self
        return view
    }

    /// The row each self-drawn view was last bound to, for the one moment
    /// `row(for:)` cannot answer: a view that has already left the list — the
    /// hover it was showing ends as it goes, and that report still names a row.
    /// Weak keys, so a view the pool lets go takes its entry with it.
    private let boundRows = NSMapTable<BlockView, NSNumber>.weakToStrongObjects()

    /// The row `view` is showing now, or the one it was last bound to once it has
    /// left the list.
    fileprivate func row(of view: BlockView) -> Int {
        let current = row(for: view)
        return current >= 0 ? current : boundRows.object(forKey: view)?.intValue ?? current
    }

    // MARK: - Row access

    /// The number of rows the view currently knows about — the data source's
    /// answer as of the last `reloadData()` / mutation call.
    public var numberOfRows: Int {
        list.numberOfRows
    }

    /// The row currently displaying `view`, or `-1` when the transcript is not
    /// showing it. Mirrors `NSTableView.row(for:)`.
    ///
    /// A hosted view that needs to invalidate its own height (a disclosure
    /// opening, an image finishing its decode) asks this rather than reusing the
    /// index it was handed at configure time: insertions and removals shift
    /// indices under a view that is standing still.
    public func row(for view: NSView) -> Int {
        list.row(for: view)
    }

    /// The row at `index` as the data source describes it, or `nil` with none.
    func row(at index: Int) -> TranscriptRow? {
        dataSource?.transcriptView(self, rowAt: index)
    }

    // MARK: - Content width

    /// The narrowest the content column is allowed to get, default `0`.
    ///
    /// Internal: no host sets one (§3). It becomes public the day one does, as
    /// `maxContentWidth`'s counterpart.
    var minContentWidth: CGFloat = 0 {
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

    /// The width the list last measured rows at — its committed width, which
    /// during a layout pass can be ahead of `bounds`. `nil` before it has asked.
    private var rowWidth: CGFloat?

    /// The width the transcript's content occupies: the row width less a margin
    /// either side (`TranscriptCellView.margin`), clamped into
    /// `minContentWidth ... maxContentWidth`. The number `heightOfRow` is asked
    /// against and the number the hosted view is laid out at.
    ///
    /// Taken from the width the list measures at rather than from `bounds`:
    /// the list's scroller may take room from the rows, and the list knows how
    /// much.
    var contentWidth: CGFloat {
        TranscriptCellView.contentWidth(
            forRowWidth: rowWidth ?? list.bounds.width, minWidth: minContentWidth, maxWidth: maxContentWidth)
    }

    /// The content width the off-main re-measure last ran for. `.nan` compares
    /// unequal to everything, so the first width counts as a change.
    private var measuredContentWidth: CGFloat = .nan

    /// Set when a live resize changed the width; the off-main re-measure waits
    /// for the drag to end rather than starting sixty times inside it.
    private var hasStaleOffscreenHeights = false

    private func contentWidthBoundsChanged() {
        // Live cells hold the bounds they were installed with.
        list.enumerateAvailableRowViews { view, _ in
            (view as? TranscriptCellView)?.updateContentWidthBounds(
                minWidth: minContentWidth, maxWidth: maxContentWidth)
        }
        guard list.numberOfRows > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            list.noteHeightOfRows(withIndexesChanged: IndexSet(0..<list.numberOfRows))
        }
        contentWidthDidChange()
    }

    /// Starts warming the cache for the new width, off the main actor, and walks
    /// a find again once the width has settled.
    ///
    /// The list does the rest: it re-measures the rows on screen inside the pass
    /// that changed the width and the others on idle turns (ExactList W4, W5),
    /// and each of those questions finds its answer already in the cache once
    /// `RemeasureScheduler` has been by. Mid-drag, nothing is warmed — the rows
    /// on screen are the whole job there.
    ///
    /// Reached from inside the list's height question, so it starts work and
    /// changes nothing the list can see.
    private func contentWidthDidChange() {
        let width = contentWidth
        guard width != measuredContentWidth else { return }
        measuredContentWidth = width
        guard !inLiveResize else {
            hasStaleOffscreenHeights = true
            return
        }
        settleContentWidth()
    }

    private func settleContentWidth() {
        remeasureScheduler.beginRemeasuringOffscreenRows(at: contentWidth)
        findSession.refreshFindAfterWidthChange()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard hasStaleOffscreenHeights else { return }
        hasStaleOffscreenHeights = false
        settleContentWidth()
    }

    /// Warms `RowCache` off the main actor after a width change; see
    /// `RemeasureScheduler`.
    private lazy var remeasureScheduler = RemeasureScheduler(owner: self, rowCache: rowCache, list: list)

    /// The re-measure in flight, or `nil` — what a test waits on.
    var remeasuring: Task<Void, Never>? { remeasureScheduler.task }

    /// Re-measures the self-drawn rows on screen among `rows` and hands each cell
    /// the result, without rebuilding any views. Answers with the rows it
    /// handled.
    ///
    /// **`remeasured` or `configure`** is the one judgement here, and it is what
    /// keeps a reader's selection alive through a streaming row. `configure` is
    /// the recycling entry point: it drops the hover band. `remeasured` keeps it,
    /// on the grounds that the indices still name the same characters. That holds
    /// exactly when the new source **extends** the old one: the blocks before the
    /// divergence parse the same, so they occupy the same flat index space they
    /// did. A source that is not an extension gets `configure`, and if an end of
    /// the selection is in that row, the selection goes too.
    ///
    /// Not airtight: an arriving line can retroactively change what an *earlier*
    /// block is — three dashes turn the paragraph above them into a heading — and
    /// the selection then covers the wrong characters until the reader clicks
    /// again. The alternative is dropping every selection on every frame of every
    /// stream.
    @discardableResult
    private func rebindVisibleRows(in rows: IndexSet) -> IndexSet {
        var rebound = IndexSet()
        let selected = selectionTracker.selection
        list.enumerateAvailableRowViews { cell, row in
            guard rows.contains(row),
                let view = (cell as? TranscriptCellView)?.hostedView as? BlockView,
                let described = dataSource?.transcriptView(self, rowAt: row)
            else { return }
            // The cache holds the source a row was last built from, so reading it
            // either side of the measure gives both versions. Keyed on the
            // identity, so a renumbered row still finds its own previous version.
            let previous = rowCache.source(for: described.id)
            guard let block = measuredBlock(for: described) else { return }
            let extended = previous.flatMap { rowCache.source(for: described.id)?.hasPrefix($0) } ?? false
            if extended {
                view.remeasured(to: block)
            } else {
                view.configure(with: block)
                selectionTracker.dropSelection(endingIn: described.id)
            }
            view.selectedRange = selectionTracker.range(inRow: row, length: block.length)
            rebound.insert(row)
        }
        // Rows handled before the selection was dropped still show their part.
        if selectionTracker.selection != selected { selectionTracker.pushSelection() }
        if !rebound.isEmpty { findSession.setNeedsFindLayout() }
        return rebound
    }

    // MARK: - Geometry

    /// Margins added to the scrollable range, for host chrome the transcript
    /// scrolls underneath. Mirrors `NSScrollView.contentInsets`.
    ///
    /// This does **not** shrink the transcript: rows stay full-bleed and pass
    /// under the chrome as they scroll. What it adds is room at the ends of the
    /// scroll — so a bottom inset of an input bar's height plus a gap makes the
    /// last row come to rest above that bar instead of behind it. Positions and
    /// anchoring are measured against the area the chrome leaves visible.
    ///
    /// A write is anchored like a row mutation: at the tail the transcript stays
    /// at the tail, anywhere else the content holds still. Writing the value
    /// already set does nothing, so a controller may assign on every layout pass.
    public var contentInsets: NSEdgeInsets {
        get { list.contentInsets }
        set {
            guard !NSEdgeInsetsEqual(newValue, list.contentInsets) else { return }
            list.contentInsets = newValue
        }
    }

    /// The rectangle row `row` occupies, measured from the transcript's top-left
    /// corner with y growing downwards, the scroll offset applied — a row on
    /// screen has a rectangle inside `bounds`. `NSZeroRect` for an out-of-range
    /// row, or before the first layout.
    ///
    /// *Deviation:* `NSTableView.rect(ofRow:)` answers in the table's own space,
    /// which is the scrolled document; this transcript's document is private,
    /// so the answer is in the only space a host can use it in (the list's).
    /// Spans the full row width; the content inside is narrower by the margins.
    public func rect(ofRow row: Int) -> NSRect {
        list.rect(ofRow: row)
    }

    // MARK: - Scrolling

    /// Scrolls so the row at `row` lands at `scrollPosition`, measured against
    /// the area the host's chrome leaves visible and clamped to the scroll
    /// range. An out-of-range row does nothing. Mirrors
    /// `NSCollectionView.scrollToItems(at:scrollPosition:)`, narrowed to a row;
    /// `NSTableView` has only `scrollRowToVisible(_:)`, which is `.nearestEdge`.
    ///
    /// The one deliberate break in scroll anchoring. Landing on the last row at
    /// `.bottom` re-engages tail following, as a consequence of where the offset
    /// ends up. Animated inside an `NSAnimationContext` group that sets
    /// `allowsImplicitAnimation`, as an `NSClipView` scroll is.
    public func scrollToRow(at row: Int, scrollPosition: ScrollPosition) {
        guard row >= 0, row < list.numberOfRows else { return }
        list.scrollToRow(row, at: scrollPosition.listPosition)
    }

    // MARK: - View row recycling

    /// Returns a view previously used by a `.view` row and since retired, or
    /// builds a fresh one with `make` when nothing is pooled under
    /// `identifier`. The recycling counterpart to
    /// `NSTableView.makeView(withIdentifier:owner:)`.
    ///
    /// Call this from `TranscriptViewDelegate.transcriptView(_:viewForRow:)`
    /// and nowhere else. The transcript tags what it hands back with
    /// `identifier` itself, so a view always finds its way home to the right
    /// pool: no registration step, and no `identifier` the host has to remember
    /// to assign (forgetting that on `NSTableView` is what silently disables
    /// recycling there).
    ///
    /// One identifier means one view type. `V` is resolved at the call site,
    /// so the host writes no `as?` cast and pooling two types under one
    /// identifier fails loudly rather than mis-rendering.
    public func makeView<V: NSView>(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        make: () -> V
    ) -> V {
        // Hosted views ride inside the cell the list pooled, so the pool to look
        // in is the cell currently being configured.
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

    /// Re-queries the data source from scratch: every row's height is asked
    /// again and every visible row rebuilt. Never animated. The offset stays
    /// where it was, or at the tail when the transcript was following it.
    ///
    /// **This does not discard what rows cost to build.** Measurements are
    /// filed under the identity the data source gives each row, and a reload does
    /// not change who a row is — so a transcript reloaded after a reorder or a
    /// re-fetch that returned the same messages re-measures nothing. What it
    /// does drop is entries for identities the data source no longer has.
    ///
    /// **Mount and lay out before loading.** The list measures at the width it
    /// has when it first lays out; add the view, activate its constraints,
    /// `layoutSubtreeIfNeeded()`, then call this.
    public func reloadData() {
        sweepCache()
        list.reloadData()
        // Any row may hold anything now, and nothing says which — so a find up
        // walks again, in place.
        findSession.refreshFind()
        findSession.reportFind()
    }

    /// Drops cache entries, hits and selection ends for rows the data source no
    /// longer has. Two callers, the two mutations after which an identity can
    /// name nothing — `removeRows` and `reloadData`.
    ///
    /// One `rowAt` per row: 5.1 ms to remove three rows from ten thousand, inside
    /// an operation that is O(rows) anyway. If it stops being affordable, a
    /// second data source requirement answering the identity alone is the wrong
    /// fix: a protocol method only one rare call site uses is not a real seam.
    private func sweepCache() {
        guard let dataSource else {
            rowCache.removeAll()
            selectionTracker.keepSelection([:])
            return
        }
        let count = dataSource.numberOfRows(in: self)
        var live = Set<TranscriptRow.ID>(minimumCapacity: count)
        // The selection's two ends, found by identity on the same walk — a
        // removal or a reload says which rows are left, not where they went.
        let ends = selectionTracker.endIDs
        var located: [TranscriptRow.ID: Int] = [:]
        for row in 0..<count {
            let id = dataSource.transcriptView(self, rowAt: row).id
            live.insert(id)
            if !ends.isEmpty, ends.contains(id) { located[id] = row }
        }
        rowCache.keep(live)
        findSession.keepFind(live)
        selectionTracker.keepSelection(located)
    }

    /// Groups mutations into one commit: the calls `updates` makes land
    /// together, before this returns, held still by `anchoring` and animated
    /// together. Mirrors `NSCollectionView.performBatchUpdates(_:completionHandler:)`
    /// and `NSTableView`'s `beginUpdates()` / `endUpdates()`.
    ///
    /// Inside `updates`, call this view's `insertRows`, `removeRows`,
    /// `reloadRows` and `noteHeightOfRows`, with indexes following
    /// `NSTableView`'s incremental rules; nothing else on the transcript is
    /// asked for or changed until it returns. Nested calls join the outermost.
    ///
    /// `anchoring` is how a host keeps the row the reader acted on under the
    /// pointer: `.row(r)` holds row `r` (its index before the batch) where it is
    /// on screen, even at the tail.
    public func performBatchUpdates(anchoring: Anchoring = .automatic, _ updates: () -> Void) {
        let outer = isInBatch
        isInBatch = true
        defer { isInBatch = outer }
        holdingRowsStillForFind {
            list.performBatchUpdates(anchoring: anchoring.listAnchoring) {
                // The host's calls to this view's update methods record straight
                // into the list's open batch.
                updates()
            }
        }
    }

    /// Whether a `performBatchUpdates` closure is running. Inside one, a mounted
    /// view is still at its row from before the batch, while the indexes a host
    /// passes follow the batch's edits so far: only the list can pair them.
    private var isInBatch = false

    /// No row moves while a find is up: its overlay reads where the rows are
    /// when it lays out, and a row sliding under it would leave its highlights
    /// behind. A group of duration 0 is how AppKit says "no motion".
    private func holdingRowsStillForFind(_ body: () -> Void) {
        guard findSession.isFinding else { return body() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            body()
        }
    }

    /// Announces rows newly inserted at `indexes` (positions after the
    /// insertion). Mirrors `NSTableView.insertRows(at:withAnimation:)`: with
    /// `[]` the rows appear in place; with an effect they open a gap that the
    /// rows below slide away from. Either way the viewport holds still (see
    /// Scroll anchoring) — the list moves the offset with the motion.
    public func insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        selectionTracker.shift(byRowsInserted: indexes)
        holdingRowsStillForFind { list.insertRows(at: indexes, withAnimation: options) }
        findSession.shiftFind(byRowsInserted: indexes)
    }

    /// Announces rows newly inserted at `indexes`, warming the transcript's
    /// measurement cache with `prepared` on the way through.
    ///
    /// Identical to `insertRows(at:)` in every observable way. What differs is
    /// only what the call has to compute: `insertRows(at:)` parses and typesets
    /// each new row inside this call; this one finds those answers in hand.
    ///
    /// `indexes` says where rows appeared; `prepared` says which rows have
    /// already been measured. Nothing pairs them — a measurement is filed under
    /// the identity of the row it was made for, so anything at all may happen
    /// to the transcript between preparing a batch and announcing it.
    ///
    /// One call rather than a `warm(_:)` you could make yourself, because
    /// warming has to land before the list measures, and a separate call written
    /// *after* the insert would be a silent no-op. Fusing the two makes the
    /// wrong order unrepresentable (§4).
    ///
    /// **The one rule:** between mutating your model and calling this, there
    /// must be **no `await`** — prepare first, then mutate and insert together:
    ///
    /// ```swift
    /// let prepared = await transcript.prepareRows(rows)
    /// // ↓ no suspension point between these two lines ↓
    /// messages.insert(contentsOf: batch, at: 0)
    /// transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
    /// ```
    ///
    /// The rule is `NSTableView`'s, and applies to `insertRows(at:)` as much:
    /// the list keeps its own row count while the data source answers from the
    /// model, and a layout landing while the two disagree reads row *n* out of a
    /// model where *n* means something else.
    public func insertRows(
        at indexes: IndexSet, warming prepared: PreparedRows,
        withAnimation options: NSTableView.AnimationOptions = []
    ) {
        // An entry carries the width it was measured at, so the cache would
        // reject a stale one on read anyway; this only saves the merge.
        if prepared.width == contentWidth {
            rowCache.merge(prepared.entries)
        }
        insertRows(at: indexes, withAnimation: options)
    }

    /// Announces rows removed at `indexes` (positions before the removal).
    /// Mirrors `NSTableView.removeRows(at:withAnimation:)`.
    public func removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions = []) {
        sweepCache()
        holdingRowsStillForFind { list.removeRows(at: indexes, withAnimation: options) }
        findSession.shiftFind(byRowsRemoved: indexes)
        // Out here rather than in the sweep: see `keepFind(_:)`.
        findSession.reportFind()
    }

    /// Announces in-place content changes: the rows at `indexes` are re-queried
    /// from the data source and re-rendered, keeping row identity, and their
    /// heights are re-resolved. Never animated: this is
    /// `NSTableView.reloadData(forRowIndexes:columnIndexes:)` plus the height
    /// that changed with the content.
    ///
    /// **This is also the streaming path**, called once per frame with the one
    /// row that grew:
    ///
    /// - A row whose markdown is **unchanged** costs a string comparison.
    /// - A row whose markdown **grew** re-typesets only the blocks that changed
    ///   (`MarkdownMemo`).
    /// - A row whose markdown grew **keeps the reader's selection and the link
    ///   under the pointer** (`rebindVisibleRows(in:)`).
    ///
    /// What a host still owns is *what* to hand over: an unclosed ``` turns the
    /// rest of the message into code, so holding an incomplete structure back
    /// until it seals is the host's policy.
    public func reloadRows(at indexes: IndexSet) {
        // Rows the transcript draws itself are handed their new tree in place
        // rather than rebuilt, which is what preserves selection and hover —
        // outside a batch, where a mounted view's row is the row it names.
        let rest = isInBatch ? indexes : indexes.subtracting(rebindVisibleRows(in: indexes))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            list.performBatchUpdates {
                // Everything the pass above did not take: `.view` rows, rows off
                // screen, and a row that changed which kind it is.
                if !rest.isEmpty { list.reloadData(forRowIndexes: rest) }
                list.noteHeightOfRows(withIndexesChanged: indexes)
            }
        }
        findSession.refileFind(inRows: indexes)
    }

    /// Asks the rows at `indexes` for their heights again, without re-rendering
    /// them. Mirrors `NSTableView.noteHeightOfRows(withIndexesChanged:)`,
    /// including its animation: a changed height moves over AppKit's default
    /// duration, or the enclosing animation group's, and not at all inside a
    /// group of duration 0.
    ///
    /// Only needed when a height changed but the content did not — a hosted
    /// view opening a disclosure, say.
    public func noteHeightOfRows(withIndexesChanged indexes: IndexSet) {
        holdingRowsStillForFind { list.noteHeightOfRows(withIndexesChanged: indexes) }
    }

    // MARK: - Off-main measurement

    /// Measures `rows` off the main actor, ready for `insertRows(at:warming:)`.
    ///
    /// **What this is for.** The list measures every row it is told about, and
    /// measuring a document is parsing and typesetting it — a ten-thousand-row
    /// load is seconds of main thread. This moves that onto the cooperative
    /// pool, across every core, while the main thread keeps drawing.
    ///
    /// **Rows, not indices.** The rows do not exist yet; what identifies a
    /// measurement is the `TranscriptRow.ID` it carries. Hand over the same
    /// values the data source will later answer with. `.view` rows pass through
    /// and produce no measurement.
    ///
    /// ## How a host loads a long transcript
    ///
    /// ```swift
    /// // 1. Mount and lay out, then load one screen synchronously.
    /// root.layoutSubtreeIfNeeded()
    /// messages = await store.loadTail(count: 20)
    /// transcript.reloadData()
    /// transcript.scrollToRow(at: messages.count - 1, scrollPosition: .bottom)
    ///
    /// // 2. Then the history, oldest-ward, a chunk at a time.
    /// while let batch = await store.loadOlder(before: messages.first, count: 500) {
    ///     let prepared = await transcript.prepareRows(
    ///         batch.map { TranscriptRow(id: $0.id, content: .markdown($0.text)) })
    ///     if Task.isCancelled { return }
    ///
    ///     messages.insert(contentsOf: batch, at: 0)
    ///     transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
    /// }
    /// ```
    ///
    /// Scroll anchoring is what makes phase 2 invisible: each chunk lands above
    /// the viewport and the content holds still. **Chunk it** — a batch is
    /// dropped whole by a resize (see `PreparedRows`) and cancelled whole by a
    /// session switch, so a chunk is the unit of work you are willing to lose.
    ///
    /// **Lay out before preparing**: a transcript that has not been through Auto
    /// Layout has no width, and everything measured against it is dropped.
    /// **Cancellation stops the work**: rows still queued return nothing, so
    /// check `Task.isCancelled` after the `await` and drop the batch.
    public func prepareRows(_ rows: [TranscriptRow]) async -> PreparedRows {
        // Read on the main actor and captured, so every row in the batch is
        // measured into one number.
        let width = contentWidth
        return await PreparedRows.measuring(rows, width: width)
    }

    // MARK: - Find

    /// The find, its walk and its presentation; see `FindSession`.
    private lazy var findSession = FindSession(owner: self, rowCache: rowCache, list: list)

    /// The number of matches found so far. Still climbing until the delegate
    /// reports `isComplete`.
    ///
    /// Internal: a host hears the count through
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)`, the one channel a
    /// find's state crosses by.
    var numberOfFindMatches: Int { findSession.numberOfMatches }

    /// Which match the reader is on, counting from zero, or `nil` when none is
    /// selected.
    var indexOfSelectedFindMatch: Int? { findSession.indexOfSelectedMatch }

    /// The walk in flight — what a test waits on.
    var finding: Task<Void, Never>? { findSession.finding }

    /// Highlights every occurrence of `query` and selects the first at or after
    /// the reader, replacing any find already up. An empty query ends one.
    ///
    /// Shown the way AppKit's find bar shows an incremental search — the content
    /// dimmed, every match lit through it, the selected one raised in yellow —
    /// by the transcript, over every row (`FindOverlayView`). Case, diacritics
    /// and width are folded, as in `NSTextView`'s own find.
    ///
    /// **It returns immediately.** The walk runs a slice at a time with the
    /// matching on the cooperative pool, reporting through
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)` — once straight away,
    /// at zero, and then as the count climbs.
    ///
    /// **`.view` rows are searched by their host**, through the delegate's
    /// `transcriptView(_:findMatchesOf:inRow:)`, and drawn again by their view
    /// through `TranscriptFindHighlighting`.
    ///
    /// **A find follows the transcript.** Rows inserted are searched, rows
    /// `reloadRows(at:)` announces are searched again, rows removed take their
    /// hits with them. `reloadData()` and a settled change of width walk the
    /// whole transcript again in place. While a find is up, rows don't animate.
    public func find(_ query: String) {
        findSession.find(query)
    }

    /// Takes the highlights away and stops the walk.
    ///
    /// **Reports, though the host asked for it.** The callback means *this is
    /// the find's state now*, and a state it is only sometimes told about is a
    /// state it has to track twice.
    public func endFind() {
        findSession.endFind()
    }

    /// Moves to the next match, wrapping at the end, and scrolls it into view.
    /// With none selected, that is the first match at or after the reader.
    public func findNext() { findSession.findNext() }

    /// Moves to the previous match, wrapping at the start, and scrolls it into
    /// view. With none selected, that is the last match above the reader.
    public func findPrevious() { findSession.findPrevious() }

    /// Brings a hit on screen — the hit, not only its row, because a row is a
    /// whole message and a long one is several screens tall.
    ///
    /// A hit already wholly in view stays where it is; one that is not is
    /// centred, which is where Safari and Xcode put a match they move to. The
    /// row is brought on screen first if it is not, then its cell scrolls the
    /// hit to the centre with AppKit's own `NSView.scroll(_:)`, which moves the
    /// clip view the cell is inside.
    ///
    /// A `.view` row's geometry is its host's, so there the row is brought to
    /// its nearest edge instead.
    func scrollFindMatchToVisible(_ range: Range<Int>, inRow row: Int) {
        guard row >= 0, row < list.numberOfRows else { return }
        guard let described = dataSource?.transcriptView(self, rowAt: row),
            let block = measuredBlock(for: described),
            let hit = block.rects(from: range.lowerBound, to: range.upperBound)
                .reduce(nil, { (union: CGRect?, rect) in union?.union(rect) ?? rect })
        else {
            return list.scrollToRow(row, at: .nearestHorizontalEdge)
        }
        let insets = list.contentInsets
        let visibleHeight = list.bounds.height - insets.top - insets.bottom
        // The block is drawn from the row's top edge.
        let rowTop = list.rect(ofRow: row).minY
        if rowTop + hit.minY >= insets.top, rowTop + hit.maxY <= insets.top + visibleHeight { return }
        if list.view(atRow: row) == nil { list.scrollToRow(row, at: .centeredVertically) }
        guard let cell = list.view(atRow: row) else { return }
        // Where the viewport's top goes, in the list's coordinates, so the hit
        // sits at the centre of what the chrome leaves visible. The cell scrolls
        // its clip view there, clamped to the scroll range.
        let top = list.rect(ofRow: row).minY + hit.midY - insets.top - visibleHeight / 2
        cell.scroll(cell.convert(NSPoint(x: 0, y: top), from: list))
    }

    // MARK: - Selection

    /// The reader's selection and the gestures that make it; see
    /// `SelectionTracker`.
    private lazy var selectionTracker = SelectionTracker(owner: self, rowCache: rowCache, list: list)

    /// A press no row consumed reaches here up the responder chain, after the
    /// list has taken focus for it: the selection is tracked to its release.
    public override func mouseDown(with event: NSEvent) {
        selectionTracker.trackSelection(from: event)
    }

    /// Copies the selection. The list's document view is the first responder,
    /// and the command comes up the chain to here.
    @objc public func copy(_ sender: Any?) {
        selectionTracker.copySelection()
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return false }
        return selectionTracker.canCopySelection
    }

    /// Watches the window's first responder, so the selection goes when the
    /// focus leaves the list — how a selection in one transcript goes away when
    /// the reader starts one in another, as `NSTextView`'s does.
    private var focusObservation: NSKeyValueObservation?

    private func observeFocus() {
        focusObservation = window?.observe(\.firstResponder, options: [.old, .new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self, let old = change.oldValue as? NSView, old.isDescendant(of: self.list),
                    old.enclosingScrollView?.documentView === old,
                    change.newValue as? NSView !== old
                else { return }
                self.selectionTracker.selectionDidResign()
            }
        }
    }
}

extension TranscriptView: BlockViewDelegate {

    func blockView(_ view: BlockView, didActivate link: InlineLink) {
        switch link.destination {
        case .url(let url):
            delegate?.transcriptView(self, didActivate: url, inRow: row(of: view))

        case .more:
            delegate?.transcriptView(self, didActivateMoreInRow: row(of: view))
        }
    }

    func blockView(_ view: BlockView, didHover url: URL?, at point: CGPoint) {
        delegate?.transcriptView(
            self, didHover: url, at: convert(point, from: view), inRow: row(of: view))
    }

    /// Not `delegate?.transcriptView(…) ?? menu`: optional-chaining a method that
    /// itself returns an optional flattens the two, so a host answering "show no
    /// menu" would be indistinguishable from having no delegate.
    func blockView(_ view: BlockView, menu: NSMenu, for event: NSEvent) -> NSMenu? {
        // Before the host sees the menu: what it acts on is decided here.
        selectionTracker.selectForContextMenu(with: event, in: view)
        guard let delegate else { return menu }
        return delegate.transcriptView(self, menu: menu, forRow: row(of: view))
    }

    /// The row's width changed under the view — the list is wider or narrower,
    /// or the content bounds moved — so it gets its row's tree at the new width.
    /// Same content, so its selection and hover stay.
    func blockViewDidChangeWidth(_ view: BlockView) {
        let row = row(for: view)
        guard row >= 0, let described = self.row(at: row), let block = measuredBlock(for: described),
            block.size.width != view.block?.size.width
        else { return }
        view.remeasured(to: block)
        view.selectedRange = selectionTracker.range(inRow: row, length: block.length)
        findSession.setNeedsFindLayout()
    }
}

extension TranscriptView: ListAdapterOwner {

    var numberOfRowsInDataSource: Int {
        dataSource?.numberOfRows(in: self) ?? 0
    }

    /// `.view` rows are the delegate's to measure; the self-drawn cases the
    /// transcript measures itself, from the same tree it will later draw — the
    /// height alone, which the cache keeps for every row, not the tree, which it
    /// keeps only for the rows being drawn.
    func height(ofRow row: Int, rowWidth: CGFloat) -> CGFloat {
        if rowWidth != self.rowWidth {
            self.rowWidth = rowWidth
            contentWidthDidChange()
        }
        let answer: CGFloat
        switch dataSource?.transcriptView(self, rowAt: row) {
        case .some(let described) where described.content == .view:
            answer = delegate?.transcriptView(self, heightOfRow: row, width: contentWidth) ?? 0
        case .some(let described):
            answer = rowCache.height(for: described, width: contentWidth) ?? 0
        case .none:
            answer = 0
        }
        return max(answer, Self.minimumRowHeight)
    }

    /// The host's answer: the transcript has no spacing of its own but
    /// `rowSpacing`, the default.
    func customSpacing(aboveRow row: Int) -> CGFloat? {
        delegate?.transcriptView(self, customSpacingAboveRow: row)
    }

    /// The cell for row `row`: the transcript's own cell view, with either a
    /// host-supplied view or the transcript's own self-drawn one inside it.
    func view(forRow row: Int) -> NSView {
        guard let described = dataSource?.transcriptView(self, rowAt: row) else {
            return list.makeView(withIdentifier: Self.emptyRow) { NSView() }
        }
        let pool: NSUserInterfaceItemIdentifier =
            switch described.content {
            case .markdown, .userMessage: TranscriptCellView.Pool.drawn
            case .view: TranscriptCellView.Pool.hosted
            }
        let hosted: NSView
        let cell = list.makeView(withIdentifier: pool) { TranscriptCellView(pool: pool) }
        switch described.content {
        case .markdown, .userMessage:
            guard let block = measuredBlock(for: described) else {
                return list.makeView(withIdentifier: Self.emptyRow) { NSView() }
            }
            hosted = blockView(in: cell, showing: block, forRow: row)

        case .view:
            guard let delegate else { return list.makeView(withIdentifier: Self.emptyRow) { NSView() } }
            configuringCell = cell
            defer { configuringCell = nil }
            hosted = delegate.transcriptView(self, viewForRow: row)
        }
        cell.install(hosted, minWidth: minContentWidth, maxWidth: maxContentWidth)
        // A row arriving is a row the find may have matches in; the overlay asks
        // every row on screen when it next lays out.
        findSession.setNeedsFindLayout()
        return cell
    }

    /// What a row with nothing to show is served through: no data source any
    /// more, or content the transcript could not build.
    private static let emptyRow = NSUserInterfaceItemIdentifier("TranscriptKit.emptyRow")

    /// What the host has work to stop on is the view it supplied, not the cell
    /// that goes back into the pool — so that is what it hears about. A
    /// self-drawn row's view is the transcript's own and is not reported.
    func didRemove(_ view: NSView, forRow row: Int) {
        findSession.setNeedsFindLayout()
        guard let hosted = (view as? TranscriptCellView)?.hostedView, !(hosted is BlockView) else { return }
        delegate?.transcriptView(self, didRemove: hosted, forRow: row)
    }

    func didChangeTailFollowing(_ isFollowingTail: Bool) {
        delegate?.transcriptView(self, didChangeTailFollowing: isFollowingTail)
    }

    /// The host is offered every command first; the list answers the scrolling
    /// ones, and passes every other key up the responder chain as the event.
    func doCommand(by selector: Selector) -> Bool {
        delegate?.transcriptView(self, doCommandBy: selector) ?? false
    }

    func didScroll() {
        findSession.placeFindOverlay()
    }
}

extension TranscriptView: RemeasureSchedulerOwner {}

extension TranscriptView: SelectionTrackerOwner {}

extension TranscriptView: RowDataSource {}

extension TranscriptView: FindSessionDelegate {}

extension TranscriptView: FindSessionOwner {

    func findMatches(of query: String, inRow row: Int) -> [Range<Int>] {
        delegate?.transcriptView(self, findMatchesOf: query, inRow: row) ?? []
    }

    func findDidUpdate(matches: Int, isComplete: Bool) {
        delegate?.transcriptView(self, didUpdateFindMatches: matches, isComplete: isComplete)
    }
}

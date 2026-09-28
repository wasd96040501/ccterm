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
/// `.markdown` / `.userMessage` it answers itself — measuring and
/// drawing them; `.view` rows it forwards to the host's
/// `TranscriptViewDelegate` (`heightOfRow`, `viewForRow`).
///
/// `NSTableView` asks for the height of **far more rows than are visible**, but
/// not all of them: measured, a ten-thousand-row reload asked about 305, and the
/// document height it published was that sample's average extrapolated across the
/// rest — a non-uniform transcript's scroll range came out four times too small
/// until scrolling to the tail forced the real numbers out. So the working set is
/// a few hundred rows, it grows as the reader moves around, and a mutation
/// re-asks about a few hundred more. Hosts absorb that by inserting in batches
/// spread over several main-queue hops, or by measuring off the main actor first
/// (`prepareRows(_:)`) — see §5 of the package's CLAUDE.md.
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
/// A window resize is half in and half out, and the seam is not arbitrary. The
/// pass that changes the width re-measures the rows on screen from inside the
/// scroll view's own tile, where holding the viewport still would mean writing a
/// scroll offset into the layout producing it — so that half is unanchored, and
/// the content settles where the new width puts it. The rest of the transcript is
/// corrected afterwards, on later turns and in batches (see
/// `beginRemeasuringOffscreenRows(at:)`), and every one of those *is* anchored:
/// they land nowhere near the tile, and a batch changing the height of rows above
/// the viewport is exactly what rule 2 is for.
///
/// Working out the offset to restore needs the geometry the mutation produced, so
/// those four methods resolve it before they return rather than on the next
/// layout pass — anything later is a frame drawn at the old offset. Which means
/// the host is asked for row heights from inside its own `insertRows` call: the
/// model has to be consistent *before* the call, not merely by the end of the
/// tick. The other side of the same property is that `rect(ofRow:)` is already
/// correct when the call returns.
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

    /// What each self-drawn row cost to build, so that the height answer and the
    /// view answer below share one tree instead of each building their own.
    private let rowCache = RowCache()

    /// `row`'s content, built and measured at the current content width — or
    /// handed back from the cache, which is the usual case: `NSTableView` asks for
    /// a height and then, for the rows it is about to show, a view. `nil` for
    /// content the transcript does not draw itself.
    ///
    /// Three callers — the height answer, the view answer, and the rebind a width
    /// or a content change forces — and the only thing this adds over calling the
    /// cache directly is `contentWidth`, which is the transcript's to know.
    ///
    /// The whole `TranscriptRow` goes to the cache rather than only a way to
    /// rebuild: the identity is what the entry is filed under and the content is
    /// what it is believed against, which is what lets the cache notice a content
    /// change instead of being told about one. **Nothing here names a recipe** —
    /// which case gets built how lives on the case, in
    /// `RowCache.Entry.init(measuring:width:reusing:)`, so that the background path
    /// and this one cannot describe a row differently.
    private func measuredBlock(for row: TranscriptRow) -> MeasuredBlock? {
        rowCache.measured(for: row, width: contentWidth)
    }

    /// How tall row `row` is. `.view` rows are the delegate's to measure; the
    /// self-drawn cases the transcript measures itself, from the same tree it
    /// will later draw.
    func height(ofRow row: Int) -> CGFloat {
        let answer: CGFloat
        switch dataSource?.transcriptView(self, rowAt: row) {
        case .some(let described) where described.content == .view:
            guard let delegate else { return Self.minimumRowHeight }
            answer = delegate.transcriptView(self, heightOfRow: row, width: contentWidth)

        case .some(let described):
            // The height alone, which the cache keeps for every row — not the
            // tree, which it keeps only for the rows being drawn.
            answer = rowCache.height(for: described, width: contentWidth) ?? 0

        case .none:
            answer = 0
        }
        return max(answer, Self.minimumRowHeight)
    }

    /// `NSTableView` throws from inside its own layout when a row measures to
    /// zero — not at the call that reported it, but at the next pass that tiles,
    /// which in practice is a window resize several seconds later. Every path
    /// that can produce a zero goes through the clamp above: a host answering
    /// `heightOfRow` with `0` for a collapsed row, a content case the transcript
    /// cannot draw yet, a data source that went away while the transcript was
    /// still mounted.
    ///
    /// Clamping rather than asserting because the failure it replaces is not one
    /// the host can act on — the exception surfaces in AppKit's layout, with
    /// nothing in the trace naming the row that caused it.
    private static let minimumRowHeight: CGFloat = 1

    /// The cell for row `row`: the transcript's own cell view, with either a
    /// host-supplied view or the transcript's own self-drawn one inside it.
    func view(forRow row: Int) -> NSView? {
        guard let described = dataSource?.transcriptView(self, rowAt: row) else {
            return nil
        }

        let cell =
            tableView.makeView(withIdentifier: TranscriptCellView.identifier, owner: nil)
            as? TranscriptCellView ?? TranscriptCellView()

        let hosted: NSView
        switch described.content {
        case .markdown, .userMessage:
            guard let block = measuredBlock(for: described) else { return nil }
            hosted = blockView(in: cell, showing: block, forRow: row)

        case .view:
            guard let delegate else { return nil }
            configuringCell = cell
            defer { configuringCell = nil }
            hosted = delegate.transcriptView(self, viewForRow: row)
        }

        cell.install(hosted, minWidth: minContentWidth, maxWidth: maxContentWidth)
        // A row arriving is a row the find may have matches in. Nothing is handed
        // to the view — the overlay asks every row on screen where its matches are
        // when it next lays out, so a recycled view has nothing stale to carry.
        setNeedsFindLayout()
        return cell
    }

    /// The view a self-drawn row is served through, bound to `block`.
    ///
    /// One path for every self-drawn case rather than one per case: what differs
    /// between a document and a user's bubble is the tree, and the tree is settled
    /// by the time this runs. Nothing here has to know which case it is serving,
    /// so nothing here has to be revisited when another one lands.
    private func blockView(
        in cell: TranscriptCellView, showing block: MeasuredBlock, forRow row: Int
    ) -> BlockView {
        // Recycled through the cell it was already installed in, so a row
        // scrolling back into view rebuilds no constraints. A fresh one only when
        // the pool hands over a cell that was serving a `.view` row — and that is
        // the one moment its delegate is set.
        let view = cell.hostedView as? BlockView ?? makeBlockView()
        view.configure(with: block)
        // Its part of the selection — the row may have scrolled out mid-selection
        // and be coming back, or be a new row landing inside one.
        view.selectedRange = selection?.range(inRow: row, length: block.length)
        boundRows.setObject(row as NSNumber, forKey: view)
        return view
    }

    private func makeBlockView() -> BlockView {
        let view = BlockView()
        view.delegate = self
        return view
    }

    /// The row each self-drawn view was last bound to, for the one moment
    /// `row(for:)` cannot answer: a view that has already left the table — the
    /// hover it was showing ends as it goes, and that report still names a row.
    /// Weak keys, so a view the pool lets go takes its entry with it.
    private let boundRows = NSMapTable<BlockView, NSNumber>.weakToStrongObjects()

    /// The row `view` is showing now, or the one it was last bound to once it has
    /// left the table.
    fileprivate func row(of view: BlockView) -> Int {
        let current = row(for: view)
        return current >= 0 ? current : boundRows.object(forKey: view)?.intValue ?? current
    }

    /// Reports the row leaving the viewport. What goes back into the pool is the
    /// cell, but what the host has work to stop on is the view it supplied — so
    /// that is what it hears about.
    func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
        setNeedsFindLayout()
        guard let cell = rowView.view(atColumn: 0) as? TranscriptCellView,
            let hosted = cell.hostedView,
            // A self-drawn row's view is the transcript's own. Reporting it
            // would hand the host something it never supplied and cannot have
            // started work on.
            !(hosted is BlockView)
        else { return }
        delegate?.transcriptView(self, didRemove: hosted, forRow: row)
    }

    // MARK: - Table

    /// Full width on purpose: the wheel has to keep working over the side
    /// margins that centred content leaves, and the overlay scroller belongs at
    /// the window's edge — so centring cannot come from narrowing this.
    private lazy var scrollView: NSScrollView = {
        let scroll = OverlayScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        // The host owns the background; the transcript draws none of its own.
        scroll.drawsBackground = false
        // Left true, AppKit rewrites `contentInsets` on every tile to clear an
        // overlapping title bar — silently reverting the insets the host set to
        // clear its own overlays, one resize later.
        scroll.automaticallyAdjustsContentInsets = false
        // The find overlay floats here and is taller than the viewport on purpose
        // (see `FindOverlayView`); unclipped, its dimming spills onto whatever the
        // host put above or below the transcript — a find bar, a tab bar.
        scroll.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    /// The gap between two rows.
    ///
    /// A row's box is exactly its content — a document's first paragraph starts
    /// at the top edge and a hosted bubble ends at the bottom one — so nothing
    /// inside a row contributes to the gap, and the table adds all of it.
    ///
    /// Wider than the 12 two paragraphs of one document sit apart
    /// (`MarkdownBlockBuilder.blockSpacing`), because a row boundary is where
    /// the speaker changes and the hard-edged things that live in rows —
    /// bubbles, cards, images — have no glyph leading around them to read as
    /// part of the gap. Both numbers are the app transcript's, where a row is a
    /// single block and each side carries its own half of the gap: 6 below a
    /// paragraph, 8 above a user bubble.
    ///
    /// `NSTableView` splits it — the cell sits centred in a row rect this much
    /// taller, so consecutive rows are `rowSpacing` apart and the first and last
    /// get half of it against the document's edges. Two consequences worth
    /// knowing before reading a number out of `rect(ofRow:)`: a row rect is its
    /// content plus this, and a `scrollToRow` position lands that rect, so
    /// `.bottom` leaves the half gap showing below the row.
    private static let rowSpacing: CGFloat = 14

    private lazy var tableView: TranscriptTableView = {
        let table = TranscriptTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        // Rows are never selected — text is, and each row draws its own part of
        // that (see Selection) — so the table has no selection to draw.
        table.selectionHighlightStyle = .none
        // Rows are measured edge to edge, so the gap between two of them is the
        // table's to add — see `rowSpacing`.
        table.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        // Already the default, and stated anyway because it picks the height
        // model: left on, the table measures cell views with Auto Layout and
        // never asks for a row height at all.
        table.usesAutomaticRowHeights = false
        // `.automatic` resolves to a style that insets rows and rounds the
        // selection — the transcript wants the row it measured.
        if #available(macOS 11.0, *) { table.style = .plain }
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        // Defaults to 10, which would floor the table's width there while the
        // clip kept shrinking — and `contentWidth` reads the clip, on the
        // understanding that the two are the same number. Zero makes that
        // identity hold at every width instead of every width above 10.
        column.minWidth = 0
        table.addTableColumn(column)
        return table
    }()

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("TranscriptKit.column")

    /// A find's presentation — the dimming, the lit matches, the current one's
    /// bubble. Mounted once, as a floating subview of the scroll view, and hidden
    /// while no find is up. See `FindOverlayView`.
    private let findOverlay: FindOverlayView = {
        let overlay = FindOverlayView()
        overlay.isHidden = true
        return overlay
    }()

    /// Answers the table's data source and delegate callbacks on the
    /// transcript's behalf, so that AppKit's table protocols stay off the
    /// package's public surface — and so a host can't be handed the transcript
    /// as a data source for a table of its own. Owned here; the table refers to
    /// it weakly.
    private lazy var tableAdapter = TableViewAdapter(owner: self)

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Hierarchy.
        scrollView.documentView = tableView
        scrollView.addFloatingSubview(findOverlay, for: .horizontal)
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

        // Every source that can move the content width lands on the clip's
        // frame, so watching that one thing covers all of them — window and
        // split-view resizes, a scroller appearing, `contentInsets`. Watching
        // this view's own frame instead would miss the scroller, which changes
        // the clip's width without changing ours; watching the table's would put
        // the invalidation inside the table's own layout.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        // A find's overlay covers what is on screen; see `placeFindOverlay()`.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        findOverlay.rows = { [weak self] in self?.findRowsOnScreen() ?? [] }
        tableView.owner = self
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
    /// with its edges clipped — the trade a block makes when it has a width it
    /// cannot usefully go under (a table, a code block). `0` means it always
    /// follows.
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

    /// The width the transcript's content currently occupies: the row width less
    /// a margin either side (`TranscriptCellView.margin`), clamped into
    /// `minContentWidth ... maxContentWidth`. This is the number
    /// `heightOfRow` is asked against and the number the hosted view is laid out
    /// at.
    ///
    /// Not public: nothing outside needs it. A host learns the width as the
    /// argument to `heightOfRow`, which is the only place it has a use for one.
    ///
    /// Measured from the clip rather than from the table, even though the two
    /// agree: the scroll view rewrites the document view's width to the clip's on
    /// every tile, so the table's width is a copy and the clip's is the original.
    /// Reading the original is what lets the invalidation below run before the
    /// table has laid out, instead of during.
    private var contentWidth: CGFloat {
        TranscriptCellView.contentWidth(
            forRowWidth: scrollView.contentView.bounds.width,
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
    ///
    /// Goes to the table directly rather than through this view's own
    /// `noteHeightOfRows(withIndexesChanged:)`, which would hold the viewport
    /// still through the reflow — tempting, because a resize *does* shift the
    /// content under the reader. It is not available here: this runs from the
    /// clip's frame-change notification, inside the scroll view's tile, and
    /// restoring an anchor there would write a scroll offset from inside the very
    /// layout that is producing it.
    ///
    /// What it does keep from `mutate` is the suppressed animation. Mid-drag AppKit
    /// animates nothing anyway; any other width change — a second editor opening
    /// beside this one, a zoom — otherwise slides the rows on screen to their new
    /// heights over a fifth of a second, with their glyphs already laid out for the
    /// new width: text that visibly squashes and springs back.
    private func contentWidthDidChange() {
        let width = contentWidth
        guard width != measuredContentWidth else { return }
        measuredContentWidth = width
        guard numberOfRows > 0 else { return }

        NSAnimationContext.beginGrouping()
        suppressImplicitAnimation()
        defer { NSAnimationContext.endGrouping() }

        rebindVisibleRows(in: nil)
        noteHeightOfVisibleRows()

        // Mid-drag the rows on screen are the whole job: the reader is looking at
        // them, and the rest is re-measured once the drag ends rather than sixty
        // times inside it.
        guard !inLiveResize else {
            hasStaleOffscreenHeights = true
            return
        }
        beginRemeasuringOffscreenRows(at: width)
        refreshFindAfterWidthChange()
    }

    /// Invalidates the heights of the rows on screen, which is cheap and is what
    /// keeps the viewport correct while everything else is still catching up.
    ///
    /// Goes to the table directly for the same reason `contentWidthDidChange`
    /// does: this runs from the clip's frame-change notification, inside the
    /// scroll view's own tile, and anchoring there would write a scroll offset
    /// from inside the layout producing it.
    private func noteHeightOfVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(
                integersIn: visible.location..<(visible.location + visible.length)))
    }

    /// Re-measures the self-drawn rows on screen — all of them, or the ones in
    /// `rows` — and hands each cell the result, without rebuilding any views.
    /// Answers with the rows it handled.
    ///
    /// Two callers, for the two things that change a row's geometry without
    /// changing which row it is: the content width moving, and the host
    /// announcing that a row's content changed. Neither re-runs `viewForRow` on
    /// its own — `noteHeightOfRows` updates a row's *height* and leaves its view
    /// holding the tree it was configured with, which at
    /// `layerContentsRedrawPolicy = .never` is not even repainted, just a stale
    /// bitmap stretched to the new size.
    ///
    /// Every self-drawn case, not one of them: a case reached through
    /// `measuredBlock(for:)` everywhere except here would keep its
    /// height in step with the width and its glyphs at the old one, which is the
    /// half of a reflow nothing complains about.
    ///
    /// Affordable only because of `RowCache`: the height pass that follows asks
    /// for the same rows at the same width and gets these trees back rather than
    /// measuring a second time.
    ///
    /// Off-screen rows need nothing — they are re-measured when they scroll in,
    /// through `viewForRow`.
    ///
    /// **`remeasured` or `configure`** is the one judgement here, and it is what
    /// keeps a reader's selection alive through a streaming row. `configure` is
    /// the recycling entry point: it drops the hover band, because a pooled cell
    /// arriving with a highlight over the previous document's words is a bug.
    /// `remeasured` keeps it, on the grounds that the indices still name the same
    /// characters. That holds exactly when the new source **extends** the old
    /// one: the blocks before the divergence parse the same, so they occupy the
    /// same flat index space they did. A source that is not an extension gets
    /// `configure`, which covers a rewrite, a retry, and a row that swapped
    /// identity under a `reloadData` — and if an end of the selection is in that
    /// row, the selection goes too: its index names text that is not there any
    /// more.
    ///
    /// Not airtight, and worth saying where it gives: an arriving line can
    /// retroactively change what an *earlier* block is — three dashes turn the
    /// paragraph above them into a heading, a delimiter row turns one into a
    /// table — and a table reserves index positions a paragraph does not. The
    /// selection then covers the wrong characters until the reader clicks again.
    /// The alternative is dropping every selection on every frame of every
    /// stream, which is the failure people would actually meet.
    @discardableResult
    private func rebindVisibleRows(in rows: IndexSet?) -> IndexSet {
        var rebound = IndexSet()
        let selected = selection
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, rows?.contains(row) ?? true,
                let cell = rowView.view(atColumn: 0) as? TranscriptCellView,
                let view = cell.hostedView as? BlockView,
                let described = dataSource?.transcriptView(self, rowAt: row)
            else { return }
            // The cache holds the source a row was last built from, so reading it
            // either side of the measure is what gives both versions. Asked there
            // rather than by switching over the content again, which would be the
            // second copy of a mapping that lives on the content case. Keyed
            // on the identity, so a row that was renumbered under
            // this pass still finds its own previous version rather than its
            // neighbour's.
            let previous = rowCache.source(for: described.id)
            guard let block = measuredBlock(for: described) else { return }
            // A row nothing had measured yet has no previous source to extend, so
            // it takes the same path a replacement does.
            let extended =
                previous.flatMap { self.rowCache.source(for: described.id)?.hasPrefix($0) } ?? false

            if extended {
                view.remeasured(to: block)
            } else {
                view.configure(with: block)
                if selection?.ends(in: described.id) == true { selection = nil }
            }
            view.selectedRange = selection?.range(inRow: row, length: block.length)
            rebound.insert(row)
        }
        // Rows handled before the selection was dropped still show their part.
        if selection != selected { pushSelection() }
        // Either way the glyphs may have moved without the row's height changing,
        // which no re-tile would report.
        if !rebound.isEmpty { setNeedsFindLayout() }
        return rebound
    }

    /// The clip has resized and has not yet resized the document view, so the
    /// table has not laid out at the new width — invalidating here marks the
    /// heights stale *before* that pass rather than during it.
    ///
    /// Observing the table instead put this inside the table's own layout, where
    /// `noteHeightOfRows` re-enters its delegate: AppKit warns that it will
    /// become an assert, and the observable symptom was one pass measuring at
    /// two different widths.
    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        contentWidthDidChange()
        placeFindOverlay()
        reportTailFollowing()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        placeFindOverlay()
        reportTailFollowing()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard hasStaleOffscreenHeights, numberOfRows > 0 else { return }
        hasStaleOffscreenHeights = false
        beginRemeasuringOffscreenRows(at: contentWidth)
        refreshFindAfterWidthChange()
    }

    /// Walks a find again once the width has settled, if it was walked at another.
    ///
    /// Only a user message cut at its line cap searches differently at a new width
    /// — how far it is shown depends on how its lines broke — and nothing cheaper
    /// than a walk can say which rows those are. Settled rather than per frame of a
    /// drag, for the reason the off-screen re-measure waits for mouse-up.
    private func refreshFindAfterWidthChange() {
        guard let find, find.width != contentWidth else { return }
        refreshFind()
    }

    // MARK: - Re-measuring a width change off the main actor

    /// The re-measure in flight, or `nil`.
    ///
    /// Held for two reasons, and neither is correctness. A second width change
    /// cancels the first, so the loser stops burning cores for an answer that
    /// would be rejected anyway — measured against the alternative, letting it run
    /// costs the work and nothing else, because `publish(_:at:)` drops a batch
    /// whose width has been superseded and `RowCache` would reject the entries
    /// even if it did not. And it is what a test waits on: the corrections land on
    /// later turns, and there is no honest way to know they all have except to wait
    /// for the thing that publishes them.
    private(set) var remeasuring: Task<Void, Never>?

    /// Re-measures everything a width change invalidated, off the main actor,
    /// nearest the reader first, publishing each batch as it fills rather than the
    /// whole job at the end.
    ///
    /// **Why this is not `prepareRows` pointed at a resize.** That one is the
    /// host's to call, so the `await` lands at the host's own call site. A resize
    /// has no host call site — it is the transcript's own invalidation, arriving
    /// through `viewDidEndLiveResize` — so the transcript has to own a `Task`, and
    /// that `Task` spans main-actor turns during which the host may do anything at
    /// all. What makes that safe is that the answers are filed by identity and
    /// checked against the content they were made from: see
    /// `RowCache.merge(remeasured:at:)`, where every way it can go stale is
    /// enumerated, and every one of them costs the work rather than the render.
    ///
    /// **Nothing is invalidated until answers are in.** Calling `noteHeightOfRows`
    /// first would make the table re-ask immediately and measure the whole working
    /// set on the main thread, which is the freeze this exists to remove. So the
    /// rows off screen keep heights from the old width until a batch covering them
    /// lands, and the visible ones are already correct — `contentWidthDidChange`
    /// re-measures those synchronously, every frame of the drag and again on
    /// mouse-up.
    ///
    /// **What that window costs, precisely.** A row scrolled into while this runs
    /// gets its glyphs at the new width, because `viewForRow` misses the cache and
    /// re-measures on demand — but its *rectangle* is the table's own cached
    /// number from the old width, and the table has no reason to re-ask, since its
    /// `heightOfRow` takes no width. New glyphs in an old rect, until a batch
    /// covering that row lands. It is confined to rows the table has already
    /// measured: one it has not is asked about on the spot and comes out right.
    /// Whether that window is short enough to be beneath noticing is not something
    /// an assertion can answer — `make demo-kit` on ten thousand rows is where it
    /// gets looked at.
    ///
    /// **The window is what the order and the batching are both about.** A
    /// transcript the reader has been through for an hour has tens of thousands of
    /// measured rows, and one batch at the end would mean the whole of that before
    /// anything is corrected. Two things shorten what the reader can actually meet:
    /// the walk starts where they are looking
    /// (`staleRowsOutwardFromViewport(at:)`), and each batch is published as it
    /// fills (`publishInterval`) rather than at the end. Together
    /// those make the *relevant* window the time to correct the next screenful,
    /// which does not grow with the transcript at all — the total still does, and
    /// is spent on rows nobody is looking at.
    private func beginRemeasuringOffscreenRows(at width: CGFloat) {
        remeasuring?.cancel()

        let stale = staleRowsOutwardFromViewport(at: width)
        guard !stale.isEmpty else {
            // Nothing was ever measured, so there is nothing to prepare from and
            // nothing to wait for. The table's own re-ask does the work, exactly
            // as it did before any of this existed. Goes to the table directly
            // rather than through `noteHeightOfEveryRow(at:)`: this path can run
            // inside the scroll view's own tile, where anchoring is not available.
            remeasuring = nil
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
            return
        }

        // Built out here rather than inside the `Task` so that it can hold the
        // transcript weakly: written in there, `self` is already the outer
        // capture's optional and weakening it again reads as a puzzle.
        let publish: @MainActor @Sendable (Batch) -> UInt64 = { [weak self] batch in
            self?.publish(batch, at: width) ?? 0
        }
        remeasuring = Task { [weak self] in
            await Self.remeasure(stale, at: width, publish: publish)
            // A cancelled run has already been replaced; clearing here would clear
            // its successor.
            guard !Task.isCancelled, let self else { return }
            remeasuring = nil
            noteHeightOfEveryRow(at: width)
        }
    }

    /// One batch of answers: what each row now measures to, and which row that was
    /// when the walk passed it.
    ///
    /// The row number is not what the answer is filed under — that is the identity,
    /// and `RowCache` still holds no positions. It is only what the table has to be
    /// told changed, and it is allowed to be wrong: see `publish(_:at:)`.
    private typealias Batch = [(row: Int, id: TranscriptRow.ID, entry: RowCache.Entry)]

    /// Everything a width change invalidated, in the order it should be corrected:
    /// the rows on screen, then one below, one above, one below, out to both ends.
    ///
    /// **Why the order is the point.** Row 0 of a ten-thousand-row transcript is
    /// nine thousand rows of scrolling away from mattering; the row just past the
    /// bottom edge is one flick away. Working outward from the reader is what makes
    /// the window they can actually meet the time to correct the next screenful,
    /// which does not grow with the transcript — where the cache's own dictionary
    /// order would put that row anywhere at all.
    ///
    /// **Why the transcript does this and the cache does not.** `RowCache` is keyed
    /// on identity and holds no positions — that is the whole of what the identity
    /// bought (see its `What the identity deleted`). Which row an entry belongs to
    /// is therefore a question only the data source can answer, and only on the main
    /// actor, so this is where it gets asked.
    ///
    /// **It costs a walk, and the walk stops early.** One `rowAt` per row passed,
    /// as `sweepCache()` also does, until every stale entry has been claimed. What
    /// bounds it is not the transcript's length but how far the *farthest measured
    /// row* is from the viewport — a reader who has stayed near the tail is a few
    /// hundred rows, one who has read the whole thing is all of it. Measured on ten
    /// thousand rows with every one of them measured, which is that worst case:
    /// **12 ms**, against the 1.9 s of measuring whose order it is deciding.
    ///
    /// Entries left over belong to rows the data source no longer has — an id a
    /// `removeRows` orphaned and no sweep has reached yet. They are dropped rather
    /// than measured: nothing will ever ask for them.
    private func staleRowsOutwardFromViewport(at width: CGFloat) -> Batch {
        var pending = rowCache.entries(measuredAtWidthOtherThan: width)
        guard !pending.isEmpty, let dataSource else { return [] }

        // Clamped rather than trusted: the table answers about the geometry it last
        // laid out, and answers `NSNotFound` for a viewport with no rows in it.
        let onScreen = tableView.rows(in: tableView.visibleRect)
        let visible =
            onScreen.length > 0
            ? (onScreen.location..<(onScreen.location + onScreen.length))
                .clamped(to: 0..<numberOfRows)
            : 0..<0

        var ordered: Batch = []
        ordered.reserveCapacity(pending.count)
        var inside = visible.makeIterator()
        var below = visible.upperBound
        var above = visible.lowerBound - 1
        // Flipped by each step that takes the side it names, so a side that has run
        // out is skipped without flipping it and the survivor runs on alone. A tie
        // goes downwards, because a transcript is read downwards.
        var takesBelow = true
        while !pending.isEmpty {
            let row: Int
            if let onScreen = inside.next() {
                row = onScreen
            } else if below < numberOfRows, takesBelow || above < 0 {
                row = below
                below += 1
                takesBelow = false
            } else if above >= 0 {
                row = above
                above -= 1
                takesBelow = true
            } else {
                break
            }
            let id = dataSource.transcriptView(self, rowAt: row).id
            if let entry = pending.removeValue(forKey: id) { ordered.append((row, id, entry)) }
        }
        return ordered
    }

    /// The shortest a batch may collect for, whatever the rule below works out.
    ///
    /// One frame at 60 Hz. Two batches inside one frame is one batch nobody saw,
    /// and it is the *only* floor that matters — a small transcript's publish costs
    /// so little that the rule below would otherwise publish per result.
    ///
    /// Nanoseconds off `DispatchTime` rather than a `Duration` off
    /// `ContinuousClock`, which is macOS 13 and this package is 12.
    private nonisolated static let publishFloor: UInt64 = 16_000_000

    /// How many times as long a batch collects for as the last one took to apply,
    /// which is what actually paces this.
    ///
    /// **Neither a fixed count of rows nor a fixed slice of time, and both were
    /// tried.** A row count is the wrong currency outright: a row here is a
    /// one-line paragraph and a row there is a four-hundred-line code fence, so any
    /// count is either a batch too small to be worth the hop or one long enough to
    /// be the whole job again. A fixed slice is better and still wrong, because
    /// what a batch *costs* is not fixed — applying one is `noteHeightOfRows` plus
    /// a layout, which is work proportional to the transcript, on a main thread
    /// whose speed depends on what else the machine is doing. Measured on the
    /// demo's ten thousand rows, one publish cost 5 ms on a quiet machine and 15 ms
    /// on a loaded one; at a fixed 8 ms slice that was 609 publishes and **1.9 s**
    /// of main thread, which is a tenth of the freeze this whole design removed,
    /// handed back.
    ///
    /// Pacing off the cost fixes both ends at once: the share of the main thread is
    /// pinned wherever this number puts it, on any transcript and any machine, and
    /// nothing has to know how long a row takes or how many there are. Twenty gives
    /// the correction about 5% of the window — measured, **77 publishes and 0.41 s**
    /// over the same ten thousand rows, in hops of 0.5 to 13 ms.
    private nonisolated static let publishInterval: UInt64 = 20

    /// How many rows are being measured at once.
    ///
    /// **Not a throughput knob — the collecting task is what this protects.** Every
    /// row queued at once is what `prepareRows` does, on the reasoning that the pool
    /// runs only as many as there are cores and the rest cost a task object each.
    /// That reasoning misses this loop: the task doing the collecting is itself on
    /// the pool, so ten thousand runnable children make it one starved job among ten
    /// thousand. Measured, on the demo's ten thousand: the collector took **78
    /// results in 10.8 s**, then the remaining 9 900 in the 90 ms after the last
    /// child finished — which is to say the batching did nothing at all, and every
    /// correction arrived at the end exactly as if none of this existed.
    ///
    /// `prepareRows` keeps the unbounded version because it has no such loop: it
    /// collects into a dictionary, hops nowhere, and nobody is waiting on it
    /// part-way.
    private nonisolated static let inFlightLimit = ProcessInfo.processInfo.activeProcessorCount

    /// The stale entries, re-measured concurrently, handed over a batch at a time.
    ///
    /// `nonisolated` because a `static` member of a
    /// `@MainActor` type is isolated by default and this one must not be. What
    /// crosses is `RowCache.Entry`, which is `Sendable` and carries its own
    /// recipe — so this is line-breaking and nothing else. No parse, no shaping,
    /// no data source.
    ///
    /// **Order survives the fan-out, because only `inFlightLimit` rows are in the
    /// air.** Nearest-first in, nearest-first out to within a core count — near
    /// enough that a batch is a contiguous band around the viewport. Nothing depends
    /// on more than that: a row in the wrong batch is corrected one batch later.
    ///
    /// **`publish` is `@MainActor`, and that is the whole of the hand-over.** The
    /// hop is the `await` on it; between hops this runs on the pool. It answers what
    /// applying the batch cost, which is what sets how long the next one collects
    /// for — the cost of *applying*, not of getting on: waiting for a main thread
    /// that is busy with something else is already its own back-pressure, and
    /// charging for it too would back off twice.
    private nonisolated static func remeasure(
        _ stale: Batch, at width: CGFloat,
        publish: @escaping @MainActor @Sendable (Batch) -> UInt64
    ) async {
        await withTaskGroup(of: (row: Int, id: TranscriptRow.ID, entry: RowCache.Entry)?.self) {
            group in
            var next = 0
            func addNext() {
                guard next < stale.count else { return }
                let item = stale[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return (item.row, item.id, item.entry.remeasured(at: width))
                }
            }
            for _ in 0..<Swift.min(stale.count, inFlightLimit) { addNext() }

            var batch: Batch = []
            var interval = publishFloor
            var opened = DispatchTime.now().uptimeNanoseconds
            for await result in group {
                addNext()
                guard let result else { continue }
                batch.append(result)
                guard DispatchTime.now().uptimeNanoseconds - opened >= interval else { continue }
                interval = Swift.max(publishFloor, await publish(batch) * publishInterval)
                batch.removeAll(keepingCapacity: true)
                // Restarted after the hand-over rather than before it, so the
                // budget is a floor on *measuring* between publishes. Timing it
                // from before would let a slow publish schedule the next one
                // immediately, which is the opposite of what a budget is for.
                opened = DispatchTime.now().uptimeNanoseconds
            }
            if !batch.isEmpty { _ = await publish(batch) }
        }
    }

    /// Files one batch and tells the table, in that order and in one turn.
    ///
    /// **Only the rows this batch carried, and that is the whole difference between
    /// this working and this being the freeze again.** `noteHeightOfRows` is not a
    /// note — the table re-asks, inside the call, for the rows it is told about that
    /// it has heights for. When the batches were published one at a time and each
    /// invalidated the whole transcript, the first one therefore re-asked about ten
    /// thousand rows of which it had corrected seventy: the other 9 930 missed the
    /// cache and were re-measured on the main thread, one document at a time.
    /// Measured, on the demo's ten thousand: **2 466 ms in a single call**, which is
    /// worse than the whole-job freeze this design replaced. Invalidating exactly
    /// what was corrected is answered entirely from the cache — same transcript,
    /// **8 to 12 ms**.
    ///
    /// **The row numbers are allowed to be wrong.** They were read when the walk
    /// passed the row and the host may have inserted or removed since, so a note can
    /// land on the wrong row: an uncorrected row gets invalidated (it is re-measured
    /// on demand, correctly, one row's cost) and a corrected one does not (it keeps
    /// the old width's rectangle). The second is the one that would persist, which
    /// is what `noteHeightOfEveryRow(at:)` at the end of the run is for — by then
    /// everything is in the cache, so invalidating the lot is answered from it.
    ///
    /// **Anchored, unlike the synchronous half of a width change.** §2 puts a
    /// resize outside both anchoring rules, and the reason it gives is that the
    /// re-measure runs inside the scroll view's own tile, where writing a scroll
    /// offset would be writing into the layout producing it. That reason does not
    /// reach here: this runs on a later turn, from a task continuation, with the
    /// tile long finished. Anchoring matters more the smaller the batches get —
    /// each one changes the height of rows above the viewport, and unanchored that
    /// is the content stepping under the reader once per batch instead of once per
    /// resize.
    ///
    /// `mutate` also suppresses the implicit animation the row geometry would
    /// otherwise take (see `suppressImplicitAnimation`) — a hundred rows sliding
    /// to new positions over a quarter second, repeatedly, while the reader is
    /// trying to read.
    ///
    /// **What is left here is thrift.** Publishing a superseded batch, or one whose
    /// rows have moved on, is self-correcting: the entries carry the width they were
    /// measured at, so the very next read rejects them and measures again, inside
    /// the same pass — no frame is drawn wrong. The merge is likewise an
    /// optimisation and not a correctness step, since the invalidation makes the
    /// table re-ask and a row with no usable entry is simply measured then. Which is
    /// the whole point, and also why no assertion can see it: with the merge removed
    /// the transcript is still right, it is just measuring on the main thread again.
    /// The evidence for it is a measurement, in §6.
    /// - Returns: what this cost, in nanoseconds — the number that paces the next
    ///   batch. See `publishInterval`.
    @discardableResult
    private func publish(_ batch: Batch, at width: CGFloat) -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        guard width == contentWidth, numberOfRows > 0 else { return 0 }

        var rows = IndexSet()
        var entries: [(id: TranscriptRow.ID, entry: RowCache.Entry)] = []
        entries.reserveCapacity(batch.count)
        for item in batch {
            guard item.row < numberOfRows else { continue }
            rows.insert(item.row)
            entries.append((item.id, item.entry))
        }
        rowCache.merge(remeasured: entries, at: width)
        mutate(shiftedBy: .none) {
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }
        return DispatchTime.now().uptimeNanoseconds - started
    }

    /// Invalidates every row's height, once the run that corrected them has
    /// finished.
    ///
    /// Cheap exactly because it is last: every answer is in the cache by now, so
    /// the re-ask this provokes is a lookup per row rather than a measurement.
    /// **8 ms** on ten thousand rows, against the 2 466 ms the same call costs
    /// against a cache that is still mostly stale (see `publish(_:at:)`).
    ///
    /// It exists to catch the rows whose numbers moved under the batches.
    ///
    /// Anchored, for the reason `publish(_:at:)` gives — which is also why the
    /// "nothing was stale" path in `beginRemeasuringOffscreenRows(at:)` does not
    /// come through here despite wanting the same call: that one can run inside the
    /// scroll view's own tile, where anchoring is not available.
    private func noteHeightOfEveryRow(at width: CGFloat) {
        guard width == contentWidth, numberOfRows > 0 else { return }
        mutate(shiftedBy: .none) {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
        }
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
    /// in the same pass — nothing in the transcript watches for chrome. The
    /// transcript's own frame stays where it is; only the scrollable range moves.
    ///
    /// These also define where "at the top" and "centred" are: a row scrolled to
    /// `.top` lands below the top inset, not underneath the chrome, and scroll
    /// anchoring measures from the same edge.
    ///
    /// **A write is anchored like a row mutation**, because it moves the same
    /// geometry. At the tail the transcript stays at the tail, so a bar growing a
    /// line lifts the last row with it rather than covering it; anywhere else the
    /// content under the top inset holds still, so a bar growing under a reader
    /// in the history moves nothing. Writing the value already set does nothing,
    /// so a controller may assign on every layout pass.
    ///
    /// `scrollerInsets` is deliberately left alone: it is *added* to this, so
    /// mirroring the value here inset the scroller's track by twice the chrome's
    /// height. Measured — a 140pt bottom inset left the track ending 280pt short.
    /// Style-independent, so pinning the scrollers to overlay does not retire it.
    public var contentInsets: NSEdgeInsets {
        get { scrollView.contentInsets }
        set {
            guard !NSEdgeInsetsEqual(newValue, scrollView.contentInsets) else { return }
            mutate(shiftedBy: .none) { scrollView.contentInsets = newValue }
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

    /// The part of the scrolled content the host's chrome is not covering, in the
    /// document's coordinate space.
    ///
    /// `contentInsets` describes chrome the transcript scrolls *under*, so the
    /// clip's own bounds include area the reader cannot see. This is the rest of
    /// it, and therefore what a landing position and an anchor are both measured
    /// against.
    private var unobscuredRect: NSRect {
        let bounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        return NSRect(
            x: bounds.minX,
            y: bounds.minY + insets.top,
            width: bounds.width,
            height: max(0, bounds.height - insets.top - insets.bottom))
    }

    /// Scrolls so the unobscured area starts at `y` in the document's coordinate
    /// space, clamped to the scrollable range.
    private func scrollClip(toUnobscuredMinY y: CGFloat) {
        scrollClip(toBoundsMinY: y - scrollView.contentInsets.top)
    }

    /// Scrolls to the far end of the scrollable range.
    private func scrollClipToTail() {
        scrollClip(toBoundsMinY: maxBoundsMinY)
    }

    private func scrollClip(toBoundsMinY y: CGFloat) {
        let clip = scrollView.contentView
        guard y != clip.bounds.minY else { return }
        var proposed = clip.bounds
        proposed.origin.y = y
        // AppKit's own answer for the legal range, rather than measuring
        // `documentView.frame` against the clip's height: `contentInsets` extends
        // the scroll past both ends of the document, and this accounts for it.
        // The clamp has to happen here because `scroll(to:)` does none of its own
        // — measured, it goes exactly where it is told, off the end included.
        let origin = clip.constrainBoundsRect(proposed).origin
        guard origin.y != clip.bounds.minY else { return }
        // Deliberately not wrapped in a suppressed animation context, even though a
        // mutation's compensating scroll must never animate: the suppression sits
        // around the mutation instead, because `scrollToRow` reaches here too and
        // documents that a host can animate it by wrapping the call.
        clip.scroll(to: origin)
        // Without this the scroller's knob stays where it was.
        scrollView.reflectScrolledClipView(clip)
    }

    /// The clip origin at the far end of the scroll — asked of
    /// `constrainBoundsRect` rather than computed, for the reason above.
    private var maxBoundsMinY: CGFloat {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        // Any value past the end; the constraint turns it into the exact maximum.
        proposed.origin.y =
            (scrollView.documentView?.frame.height ?? 0) + scrollView.contentInsets.bottom
        return clip.constrainBoundsRect(proposed).minY
    }

    /// Whether the viewport is sitting at the end of the scroll — the whole
    /// judgement behind rule 1, read fresh from the offset each time it is asked.
    private var isScrolledToTail: Bool {
        scrollView.contentView.bounds.minY >= maxBoundsMinY - Self.tailTolerance
    }

    /// How far from the end still counts as being at the end. Sub-point residue
    /// is normal — a row height rounded up, a decelerating scroll landing on a
    /// fraction — and an exact comparison would drop tail following on the
    /// strength of a rounding error.
    private static let tailTolerance: CGFloat = 1

    /// What the delegate last heard from `didChangeTailFollowing`. Starts `true`:
    /// an empty transcript is at its end, so a host starts from "following" and
    /// hears only departures from it.
    private var reportedTailFollowing = true

    /// Tells the delegate if `isScrolledToTail` has changed since it last heard.
    ///
    /// Called wherever the answer can move — the clip scrolling or resizing, the
    /// table re-tiling its rows — and silenced inside a mutation, where the
    /// document has grown but the anchor hasn't been restored yet: a row appended
    /// at the tail would otherwise report leaving it and coming back in one call.
    /// `endAnchoring()` asks once the restore has landed.
    fileprivate func reportTailFollowing() {
        guard anchorDepth == 0 else { return }
        let following = isScrolledToTail
        guard following != reportedTailFollowing else { return }
        reportedTailFollowing = following
        delegate?.transcriptView(self, didChangeTailFollowing: following)
    }

    // MARK: - Keyboard

    /// Answers a key the reader scrolls with — ↑ ↓, Page Up / Down, Home / End,
    /// ⌘↑ ⌘↓, as the standard key bindings name them; `false` for every other
    /// command, which the table then passes up the responder chain as the key it
    /// came from.
    ///
    /// The steps are the scroll view's own (`verticalLineScroll`,
    /// `verticalPageScroll`) and are measured against the area the host's chrome
    /// leaves visible, so a page never scrolls a line out from under a bar.
    /// Going to the end is going to the tail, so it re-engages tail following the
    /// way scrolling there by hand does.
    fileprivate func performScrollCommand(_ selector: Selector) -> Bool {
        let visible = unobscuredRect
        let line = scrollView.verticalLineScroll
        let page = max(visible.height - scrollView.verticalPageScroll, line)
        switch selector {
        case #selector(moveUp(_:)):
            scrollClip(toUnobscuredMinY: visible.minY - line)
        case #selector(moveDown(_:)):
            scrollClip(toUnobscuredMinY: visible.minY + line)
        case #selector(scrollPageUp(_:)):
            scrollClip(toUnobscuredMinY: visible.minY - page)
        case #selector(scrollPageDown(_:)):
            scrollClip(toUnobscuredMinY: visible.minY + page)
        case #selector(moveToBeginningOfDocument(_:)), #selector(scrollToBeginningOfDocument(_:)):
            scrollClip(toUnobscuredMinY: 0)
        case #selector(moveToEndOfDocument(_:)), #selector(scrollToEndOfDocument(_:)):
            scrollClipToTail()
        default:
            return false
        }
        return true
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
    /// across a reload — an anchor is expressed in row indices and a reload may
    /// renumber arbitrarily, so there is nothing to shift it by; the transcript
    /// lands at the tail unless a `scrollToRow` in the same tick says otherwise.
    ///
    /// **This no longer discards what rows cost to build.** Measurements are
    /// filed under the identity the data source gives each row, and a reload does
    /// not change who a row is — so a transcript reloaded after a reorder, a
    /// filter, or a re-fetch that returned the same messages re-measures nothing
    /// at all. What it does drop is entries for identities the new data source no
    /// longer has, which is what keeps the store bounded now that rows are not
    /// positional (see `RowCache.keep(_:)`).
    ///
    /// This is also the one mutation that lays nothing out before returning,
    /// precisely because it has no anchor to restore.
    ///
    /// **Mount and lay out before loading.** Rows are measured at the content
    /// width the transcript has when the table first lays out, so a load that
    /// happens before Auto Layout has run measures everything at a width of zero
    /// and again at the real one — and the correcting pass is a full-table
    /// `noteHeightOfRows`, which AppKit animates. The first screen arrives and
    /// then visibly settles. Add the view, activate its constraints,
    /// `layoutSubtreeIfNeeded()`, then call this. `NSTableView` behaves the same
    /// way whenever row height depends on width, which is why this is stated
    /// rather than absorbed: absorbing it would mean a view that quietly ignores
    /// calls until it is ready.
    public func reloadData() {
        sweepCache()
        tableView.reloadData()
        // Any row may hold anything now, and nothing says which — so a find up
        // walks again, in place.
        refreshFind()
        reportFind()
    }

    /// Drops cache entries for rows the data source no longer has.
    ///
    /// The dictionary's replacement for what the positional array used to get for
    /// free out of `remove(at:)`. Two callers, and they are exactly the two
    /// mutations after which an identity can name nothing — `removeRows` and
    /// `reloadData`. An insert or a reload of existing rows can only add or change
    /// entries, never orphan one.
    ///
    /// Asks the *data source* for the count rather than reading `numberOfRows`,
    /// which is the table's and is still the pre-mutation one at this point: the
    /// table is told immediately after this returns.
    ///
    /// **The one thing the identity made more expensive**, so here is the
    /// measurement rather than a claim. One `rowAt` call per row, which the
    /// array's memmove did not need: removing three rows from a ten-thousand-row
    /// transcript costs **5.1 ms**, against **0.7 ms** for the positional splice.
    /// Both are O(rows) and both run inside an operation that is already O(rows) —
    /// a removal re-tiles everything below it — so the shape is unchanged and the
    /// constant is about seven times worse. It stays under a frame at ten thousand
    /// rows, and removals are rare in a transcript, which is the whole of why
    /// nothing cleverer is here.
    ///
    /// If it ever stops being affordable, the tempting fix — a second data source
    /// requirement answering the identity alone — is the wrong one: a protocol
    /// method that only one rare call site would use is not a real seam, and it
    /// re-opens the disagreement `TranscriptRow` closes.
    private func sweepCache() {
        guard let dataSource else {
            rowCache.removeAll()
            keepSelection([:])
            return
        }
        let count = dataSource.numberOfRows(in: self)
        var live = Set<TranscriptRow.ID>(minimumCapacity: count)
        // The selection's two ends, found by identity on the same walk — a
        // removal or a reload says which rows are left, not where they went.
        let ends = selection.map { [$0.anchor.id, $0.focus.id] } ?? []
        var located: [TranscriptRow.ID: Int] = [:]
        for row in 0..<count {
            let id = dataSource.transcriptView(self, rowAt: row).id
            live.insert(id)
            if !ends.isEmpty, ends.contains(id) { located[id] = row }
        }
        rowCache.keep(live)
        keepFind(live)
        keepSelection(located)
    }

    /// Announces rows newly inserted at `indexes` (positions in the
    /// post-mutation data source).
    ///
    /// There is no animation parameter, unlike `NSTableView`'s. Its options all
    /// animate *row geometry*, which is the one thing scroll anchoring exists to
    /// hold still — a row sliding into place over a quarter second while the
    /// compensating offset is already final is exactly the shake anchoring
    /// prevents, and the two cannot both be honoured. A host that wants an arrival
    /// to be visible animates inside its own view, where nothing moves the rows.
    public func insertRows(at indexes: IndexSet) {
        mutate(shiftedBy: .inserted(indexes)) {
            tableView.insertRows(at: indexes, withAnimation: [])
        }
    }

    /// Announces rows newly inserted at `indexes`, warming the transcript's
    /// measurement cache with `prepared` on the way through.
    ///
    /// Identical to `insertRows(at:)` in every observable way — same row count
    /// afterwards, same scroll anchoring, same `rect(ofRow:)` correct on
    /// return. What differs is only what the call has to compute: `insertRows(at:)`
    /// parses and typesets each new row inside this call, because the table asks
    /// for heights while it lays out and there is no estimate to give it. This one
    /// finds those answers already in hand.
    ///
    /// ## The two arguments have nothing to do with each other
    ///
    /// `indexes` says where rows appeared. `prepared` says which rows have already
    /// been measured. Neither their sizes nor their orders need agree, and nothing
    /// pairs them — a batch of five hundred may be announced three at a time, and
    /// the remaining measurements simply stay warm for whoever asks next.
    ///
    /// They were paired once, the *k*-th entry to the *k*-th smallest index, and
    /// `PreparedRows` records what that cost. Now that a measurement is filed under
    /// the identity the data source gave the row it was made for, **anything at all
    /// may happen to the transcript between preparing a batch and announcing it.**
    ///
    /// It is one call rather than a `warm(_:)` you could make yourself, and the
    /// reason is ordering: warming has to land before the table lays out, and a
    /// separate call written *after* the insert is a silent no-op — every row has
    /// already been measured the expensive way by then, and the merge overwrites
    /// the results with equal values. Fusing the two makes the wrong order
    /// unrepresentable instead of documented (§4).
    ///
    /// ## The one rule
    ///
    /// > Between mutating your model and calling this, there must be **no
    /// > `await`**.
    ///
    /// Which reads as: prepare *first*, from the rows you are about to insert,
    /// then mutate and insert together.
    ///
    /// ```swift
    /// let rows = batch.map { TranscriptRow(id: $0.id, content: .markdown($0.text)) }
    /// let prepared = await transcript.prepareRows(rows)
    /// // ↓ no suspension point between these two lines ↓
    /// messages.insert(contentsOf: batch, at: 0)
    /// transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
    /// ```
    ///
    /// **This rule is `NSTableView`'s, not this package's**, and it applies to
    /// `insertRows(at:)` just as much. `transcriptView(_:rowAt:)` is asked on
    /// demand and answered from the host's array by index, with nothing cached in
    /// between, while the table caches its own row count. Mutate before the
    /// `await` and, for as long as it suspends, the table believes in the old
    /// count while the data source answers from the new one — so any layout
    /// landing in that window (a scroll, a resize, another row's `reloadRows`)
    /// reads row *n* out of a model where *n* means something else. Prepending is
    /// where it shows; appending happens to survive it, because appending leaves
    /// every existing index meaning what it meant.
    ///
    /// What preparation used to add on top of that — a second reason to hold the
    /// order, about whether the batch would still land on the rows it was
    /// measured for — is gone. A host no longer has to reason about the batch at
    /// all: another row may stream, messages may arrive and announce themselves,
    /// the window may resize, and none of it invalidates anything here beyond the
    /// batch's own width check.
    ///
    /// ## Getting it wrong
    ///
    /// A host that mutates before the `await` anyway does not corrupt anything: a
    /// frame drawn inside that window can show a row's neighbour's content, and
    /// the next layout pass converges on the correct render without being told
    /// to, because every entry is re-validated against the content it is being
    /// asked for. The failure mode is a visible glitch, not a wrong steady state —
    /// which is why this is documented rather than asserted.
    public func insertRows(at indexes: IndexSet, warming prepared: PreparedRows) {
        mutate(shiftedBy: .inserted(indexes)) {
            // Before the table's call, not after: that call lays out, and laying
            // out asks for heights, which read the cache.
            //
            // The width comparison is the batch's only guard, and it is thrift
            // rather than correctness — an entry carries the width it was measured
            // at, so the cache would reject it on read anyway. See `PreparedRows`.
            if prepared.width == contentWidth {
                rowCache.merge(prepared.entries)
            }
            tableView.insertRows(at: indexes, withAnimation: [])
        }
    }

    /// Announces rows removed at `indexes` (positions in the pre-mutation
    /// data source). No animation parameter, for the reason on `insertRows`.
    public func removeRows(at indexes: IndexSet) {
        mutate(shiftedBy: .removed(indexes)) {
            sweepCache()
            tableView.removeRows(at: indexes, withAnimation: [])
        }
        // Out here rather than in the sweep: see `keepFind(_:)`.
        reportFind()
    }

    /// Announces in-place content changes: the rows at `indexes` are
    /// re-queried from the data source and re-rendered, keeping row identity.
    /// Heights are re-resolved too — a self-sizing row is re-measured, a
    /// `.view` row is re-asked through the delegate's `heightOfRow`.
    ///
    /// **This is also the streaming path**, called once per frame with the one
    /// row that grew, and three properties are what make that reasonable rather
    /// than merely possible:
    ///
    /// - A row whose markdown is **unchanged** costs a string comparison and
    ///   nothing else. A host may announce on a timer without checking first.
    /// - A row whose markdown **grew** re-typesets only the blocks that changed;
    ///   the settled ones above are handed back from the previous frame. See
    ///   `MarkdownMemo`.
    /// - A row whose markdown grew **keeps the reader's selection and the link
    ///   under the pointer**, because the blocks before the divergence still
    ///   occupy the same index space. See `rebindVisibleRows(in:)`, which is
    ///   also where the limits of that are written down.
    ///
    /// What a host still owns is *what* to hand over: markdown reflows violently
    /// while a fence or a table row is half-written — an unclosed ``` turns the
    /// rest of the message into code — so holding an incomplete structure back
    /// until it seals is the host's policy to have, and not one this package can
    /// have on its behalf.
    public func reloadRows(at indexes: IndexSet) {
        mutate(shiftedBy: .none) {
            // Rows the transcript draws itself are handed their new tree in place
            // rather than rebuilt, which is what preserves selection and hover.
            let rebound = rebindVisibleRows(in: indexes)
            let rest = indexes.subtracting(rebound)
            if !rest.isEmpty {
                // Everything the pass above did not take: `.view` rows, rows off
                // screen, and a row that changed which kind it is. An off-screen
                // markdown row lands here and costs nothing — there is no view to
                // rebuild, and its tree is rebuilt from the current source when it
                // scrolls back in.
                tableView.reloadData(forRowIndexes: rest, columnIndexes: IndexSet(integer: 0))
            }
            // `reloadData(forRowIndexes:)` re-asks for the row's view but keeps the
            // height it already has, and changed content is a different height.
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
        refileFind(inRows: indexes)
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
        mutate(shiftedBy: .none) {
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    // MARK: - Off-main measurement

    /// Measures `contents` off the main actor, ready for
    /// `insertRows(at:prepared:)`.
    ///
    /// **What this is for.** `NSTableView` measures a working set of a few
    /// hundred rows and extrapolates its scroll range from that sample, so a
    /// mutation does not cost the whole transcript — but it does cost several
    /// hundred documents parsed and typeset inside the call, and a
    /// ten-thousand-row load is twenty of those. Measured: 12.47 s of main
    /// thread, worst batch 665 ms. Spreading that over main-queue hops (§6)
    /// divides one freeze into twenty without removing any of the work. This
    /// removes it — the typesetting happens on the cooperative pool, across every
    /// core, while the main thread keeps drawing: same transcript, 0.12 s of main
    /// thread, worst batch 11 ms.
    ///
    /// The corollary of the table being lazy is that this **over-measures**: a
    /// ten-thousand-row load asks for roughly four thousand heights, and a batch
    /// prepared here measures all ten thousand. Background CPU for main-thread
    /// latency is still the trade to take, but it is a trade rather than a free
    /// win, and it is the first thing to look at if preparation ever becomes the
    /// bottleneck.
    ///
    /// **Rows, not indices.** The rows do not exist yet, and the indices they will
    /// occupy are not knowable until the model is mutated — which happens *after*
    /// this returns. What identifies a measurement is the `TranscriptRow.ID` it
    /// carries, so where the row ends up is not this call's business at all.
    ///
    /// **Hand over the same values the data source will later answer with.** The
    /// identity has to match or nothing is found, and the content is compared on
    /// every read — two `String`s sharing storage compare in constant time where
    /// two equal ones compare in linear time. In practice this is automatic:
    /// build the rows from the batch you are about to store, and hand the same
    /// batch to your data source.
    ///
    /// **`.view` rows pass through.** They produce no measurement — a host row's
    /// height is the delegate's, and asking for it here would mean calling
    /// main-actor code from a background task. They cost nothing to include, so a
    /// host with mixed content hands over the whole batch rather than filtering it
    /// out, and since the result is keyed by identity rather than by position
    /// there is nothing to re-interleave afterwards.
    ///
    /// ## How a host loads a long transcript
    ///
    /// Three phases, and the first one is not this method:
    ///
    /// ```swift
    /// // 1. Mount and lay out, then load one screen synchronously. A screenful
    /// //    is a dozen rows: `reloadData()` measures them in under a
    /// //    millisecond, and going through a background hop for that would only
    /// //    push the first paint a frame later.
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
    /// the viewport while the reader is already reading the tail, and rule 2
    /// holds the content still throughout. The two designs are a pair — neither
    /// is much use alone.
    ///
    /// **Chunk it**, and the reason is not the frame budget — this call blocks no
    /// frame. It is that a batch is invalidated whole by a resize (see
    /// `PreparedRows`) and cancelled whole by a session switch, so a chunk is the
    /// unit of work you are willing to lose. Five hundred rows is a reasonable
    /// place to start.
    ///
    /// **Lay out before preparing.** A transcript that has not been through Auto
    /// Layout has a content width of zero, and everything measured against it is
    /// dropped rather than merged — the same ordering `reloadData()` asks for,
    /// with a gentler penalty, since what gets wasted is background work rather
    /// than the main thread's.
    ///
    /// **Cancellation stops the work, not just its result.** Cancel the enclosing
    /// `Task` — a session switch, a window closing — and the rows still queued
    /// return nothing rather than being measured for a transcript nobody is
    /// looking at. What comes back is then a partly empty batch, which is not an
    /// error state: check `Task.isCancelled` after the `await` and drop it.
    public func prepareRows(_ rows: [TranscriptRow]) async -> PreparedRows {
        // Read on the main actor and captured, so every row in the batch is
        // measured into one number — which is what lets the whole batch be
        // accepted or dropped on a single comparison.
        let width = contentWidth
        return await PreparedRows.measuring(rows, width: width)
    }

    // MARK: - Find

    /// A find, running or settled.
    ///
    /// **Keyed on identity**, for the reason `RowCache` is: a hit is a place inside
    /// a row, and every insertion above a row renumbers it. The row numbers held
    /// here are the walk's own — its cursor and the slice it has out — and every
    /// mutation renumbers them on the way through (`shiftFind(byRowsInserted:)`),
    /// the way it renumbers the scroll anchor.
    private struct Find {

        let query: String

        /// What each row matched, for the rows that matched anything, filed with
        /// the content it was matched in — so a row whose content has moved on
        /// since is never drawn with ranges that name other characters now.
        var matches: [TranscriptRow.ID: RowMatches] = [:]

        /// How many hits that is, kept in step rather than derived — publishing a
        /// slice should cost the slice, not a walk of everything filed so far.
        var count = 0

        /// The hit the reader is on, by *where* it is: a row and a range, which no
        /// insertion or removal elsewhere can move.
        var selection: (row: TranscriptRow.ID, range: Range<Int>)?

        /// The selection's ordinal — the `4` in "4 of 51" less one — when it is
        /// known. **A cache, not a fact**: anything that changes which hits come
        /// before the selection clears it, and `indexOfSelectedFindMatch` works it
        /// out again when next asked. Kept in step instead, it would be one more
        /// number every mutation had to renumber correctly, and the review that
        /// found it wrong after a removal is why it is not.
        var ordinal: Int?

        /// The walk's cursor: every row above it has been searched.
        var next = 0

        /// The rows whose slice is on the pool right now. Cleared by a mutation
        /// that renumbers any of them, which is how the walk learns that the row
        /// numbers in the answer it is waiting for now name other rows.
        var pending: Range<Int>?

        /// Rows `reloadRows(at:)` searched again on the main actor while `pending`
        /// was out. What the pool answers for them was matched against the content
        /// before, so it is older than what is filed, and is dropped.
        var refiled: Set<TranscriptRow.ID> = []

        /// The width the walk matches at. Only a capped user message cares — see
        /// `RowCache.cachedMeasured(for:width:)` — and a change is what
        /// `refreshFind()` exists to catch.
        var width: CGFloat

        /// Whether the walk selects a hit when it reaches the reader. A new find's
        /// first pass does; any later pass — a refresh, new rows arriving — must
        /// not scroll someone who is already reading.
        var landsOnViewport = true

        var isComplete = false
    }

    /// One row's hits, and the content they were found in.
    private struct RowMatches: Equatable {
        let content: TranscriptRowContent
        let ranges: [Range<Int>]
    }

    private var find: Find?

    /// The walk in flight, held for the two reasons `remeasuring` is: a superseded
    /// walk should stop burning cores for an answer nothing will read, and a test
    /// has no other honest way to know the walk has finished.
    private(set) var finding: Task<Void, Never>?

    /// One slice of the walk, in rows.
    ///
    /// A row count, where `beginRemeasuringOffscreenRows(at:)` had to reject one in
    /// favour of pacing against the cost of applying a batch. The difference is
    /// what a publish costs: there it is `noteHeightOfRows`, whose work is
    /// proportional to the whole transcript however few rows the batch held; here
    /// it is a dictionary write per row and a repaint of whatever is on screen.
    /// Bounded by the slice, so the slice is a fair unit.
    private static let findSliceRows = 200

    /// One slice on its way to the pool: what to search, and either the tree to
    /// search it in when something has already built one, or — for a `.view` row —
    /// the host's answer, which was asked for on the main actor.
    private typealias FindSlice = [(
        row: Int, id: TranscriptRow.ID, content: TranscriptRowContent,
        measured: MeasuredBlock?, answered: [Range<Int>]?
    )]

    /// What comes back: every row of the slice with what it matched — nothing
    /// included — so a walk passing a row that no longer matches can take its old
    /// hits away.
    private typealias FindBatch = [(
        row: Int, id: TranscriptRow.ID, content: TranscriptRowContent, ranges: [Range<Int>]
    )]

    /// The number of matches found so far. Still climbing until the delegate
    /// reports `isComplete`.
    ///
    /// Internal, like the ordinal below: a host hears the count through
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)`, the one channel a
    /// find's state crosses by, so it never keeps a second copy to reconcile.
    var numberOfFindMatches: Int { find?.count ?? 0 }

    /// Which match the reader is on, counting from zero, or `nil` when none is
    /// selected — the walk has not reached the reader yet, there are no matches,
    /// or the one they were on went away.
    var indexOfSelectedFindMatch: Int? {
        guard let find, let selection = find.selection else { return nil }
        if let ordinal = find.ordinal { return ordinal }
        let ordinal = ordinal(of: selection, in: find)
        self.find?.ordinal = ordinal
        return ordinal
    }

    /// Highlights every occurrence of `query` and selects the first at or after
    /// the reader, replacing any find already up. An empty query ends one.
    ///
    /// Shown the way AppKit's find bar shows an incremental search — the content
    /// dimmed, every match lit through it, the selected one raised in yellow —
    /// by the transcript, over every row. The host draws nothing; see
    /// `FindOverlayView`.
    ///
    /// Case, diacritics and width are folded, so `cafe` finds `Café` and a
    /// half-width `ｱ` finds `ア` — what a reader typing into a find bar means, and
    /// what `NSTextView`'s own find does. There is no options parameter until
    /// something needs one.
    ///
    /// **It returns immediately.** The walk runs a slice at a time with the
    /// matching on the cooperative pool, reporting through
    /// `transcriptView(_:didUpdateFindMatches:isComplete:)` — once straight away,
    /// at zero, so a find bar never shows the previous query's count beside the
    /// new one — and then as the count climbs. A long transcript shows a climbing
    /// count against a window that still scrolls, rather than a total after a
    /// freeze: what a browser's counter is doing while it settles, and for the same
    /// reason.
    ///
    /// **`.view` rows are searched by their host**, through the delegate's
    /// `transcriptView(_:findMatchesOf:inRow:)`, and located and drawn again by
    /// their view through `TranscriptFindHighlighting`. A host that implements
    /// neither leaves them out.
    ///
    /// **A find follows the transcript.** Rows inserted are searched — a walk that
    /// had finished resumes for them — and rows `reloadRows(at:)` announces are
    /// searched again, so a streaming answer is found while it streams. Rows
    /// removed take their hits with them. `reloadData()`, which may have changed
    /// anything, and a settled change of width walk the whole transcript again in
    /// place, keeping the reader where they are.
    public func find(_ query: String) {
        guard !query.isEmpty else { return endFind() }

        find = Find(query: query, width: contentWidth)
        walkFind()
        rebindFind()
        reportFind()
    }

    /// Takes the highlights away and stops the walk.
    ///
    /// **Reports, though the host asked for it.** Staying silent was the first
    /// answer, on the grounds that a host ending a find knows it ended one — and
    /// the first host wired to this promptly left "1 of 15" on screen beside an
    /// empty search field. The callback means *this is the find's state now*, and a
    /// state it is only sometimes told about is a state it has to track twice.
    public func endFind() {
        finding?.cancel()
        finding = nil
        guard find != nil else { return }
        find = nil
        rebindFind()
        delegate?.transcriptView(self, didUpdateFindMatches: 0, isComplete: true)
    }

    /// Moves to the next match, wrapping at the end, and scrolls it into view.
    /// With none selected, that is the first match at or after the reader.
    public func findNext() { moveFindSelection(by: 1) }

    /// Moves to the previous match, wrapping at the start, and scrolls it into
    /// view. With none selected, that is the last match above the reader.
    public func findPrevious() { moveFindSelection(by: -1) }

    /// Starts the walk from the cursor, replacing one already running.
    private func walkFind() {
        finding?.cancel()
        guard find != nil else {
            finding = nil
            return
        }
        find?.pending = nil
        find?.isComplete = false
        finding = Task { [weak self] in
            await self?.scan()
        }
    }

    /// Walks a find again from the top, in place: what it had stays up until the
    /// walk reaches each row and replaces it, the reader keeps the hit they are
    /// on if it is still there, and nothing scrolls.
    ///
    /// For the two things that can change what matched without saying which rows:
    /// `reloadData()`, after which any row may hold anything, and the content width
    /// settling, which moves where a capped user message is cut. Cheap in the
    /// common case, because every row the last pass searched is answered from the
    /// cache.
    private func refreshFind() {
        guard find != nil else { return }
        find?.next = 0
        find?.width = contentWidth
        walkFind()
    }

    /// Walks the transcript from the cursor in order, matching each slice off the
    /// main actor and publishing it before the next one starts.
    ///
    /// **In order, rather than outward from the viewport** — the opposite of what
    /// `staleRowsOutwardFromViewport(at:)` chose, and the difference is what the
    /// two are racing. A width correction has a *window* the reader can meet, so it
    /// starts where they are looking. A find has an *ordinal*: "4 of 51" only means
    /// anything if the fourth hit is the fourth from the top, and hits arriving out
    /// of order would renumber themselves under the reader as the walk filled in.
    ///
    /// **The cursor lives in `find`, not here**, because the transcript can change
    /// under every `await`: a mutation renumbers it where it stands, and one that
    /// renumbers the slice out on the pool clears `pending` — so the answer is
    /// dropped and the slice taken again from wherever the cursor went, rather than
    /// filed against rows that have since moved.
    private func scan() async {
        while let slice = takeFindSlice() {
            let batch = await Self.match(slice.rows, query: slice.query, width: slice.width)
            guard !Task.isCancelled else { return }
            guard find?.pending == slice.range else { continue }
            publish(batch, covering: slice.range)
        }
        guard !Task.isCancelled else { return }
        completeFind()
    }

    /// The next slice from the cursor, marked as out — or `nil` once the walk has
    /// passed the last row.
    ///
    /// The cache is read **by content, and by width only where the width decides
    /// what is searchable** — see `RowCache.cachedMeasured(for:width:)`. A row it
    /// answers costs this walk a dictionary lookup; a row it does not is carried
    /// across as its content and built on the pool, which is the only part of a
    /// find that is ever expensive.
    private func takeFindSlice() -> (
        range: Range<Int>, rows: FindSlice, query: String, width: CGFloat
    )? {
        guard var find, let dataSource, find.next < numberOfRows else { return nil }
        let range = find.next..<min(find.next + Self.findSliceRows, numberOfRows)
        let rows: FindSlice = range.map { row in
            let described = dataSource.transcriptView(self, rowAt: row)
            switch described.content {
            case .markdown:
                let cached = rowCache.cachedMeasured(for: described, width: nil)
                return (row, described.id, described.content, cached, nil)
            case .userMessage:
                let cached = rowCache.cachedMeasured(for: described, width: find.width)
                return (row, described.id, described.content, cached, nil)
            case .view:
                let answered =
                    delegate?.transcriptView(self, findMatchesOf: find.query, inRow: row) ?? []
                return (row, described.id, described.content, nil, answered)
            }
        }
        find.pending = range
        find.refiled = []
        self.find = find
        return (range, rows, find.query, find.width)
    }

    /// One slice, matched across every core.
    ///
    /// `nonisolated` because a `static` member of a
    /// `@MainActor` type is main-actor isolated by default, and awaiting this from
    /// `scan` is what hops off. Everything crossing is `Sendable` — a
    /// `MeasuredBlock` because measuring is pure and nothing mutates one after it
    /// is built.
    ///
    /// **A tree built here is used and dropped, not filed.** Handing it to
    /// `RowCache` looks like thrift and is a change of behaviour: a find over a
    /// transcript nothing has read would push every row it passed through the
    /// resident budget, evicting the rows the reader has on screen to make room for
    /// rows nobody is looking at. What a hit actually needs is its range, which outlives
    /// the tree, and the one row the reader jumps to is re-measured on arrival for a
    /// fraction of a frame.
    private nonisolated static func match(
        _ slice: FindSlice, query: String, width: CGFloat
    ) async -> FindBatch {
        await withTaskGroup(of: FindBatch.Element?.self) { group in
            for row in slice {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    if let answered = row.answered {
                        return (row.row, row.id, row.content, answered)
                    }
                    // Nothing to reuse: this is either a row the cache already
                    // answered, or one nobody has measured at this width. Same
                    // call the cache would make, so the two cannot describe a row
                    // differently.
                    let measured =
                        row.measured
                        ?? RowCache.Entry(measuring: row.content, width: width, reusing: nil)?.measured
                    return (row.row, row.id, row.content, measured?.ranges(of: query) ?? [])
                }
            }
            var batch: FindBatch = []
            for await found in group {
                guard let found else { continue }
                batch.append(found)
            }
            // The pool answers in whatever order it finishes; the order a reader
            // navigates by is reading order, and this is the only place both are in
            // hand at once.
            return batch.sorted { $0.row < $1.row }
        }
    }

    /// Files a slice's hits, moves the cursor past it, shows what changed, and
    /// lands the selection if this is the slice the reader was looking at.
    ///
    /// **A find starts from where the reader is, not from the top.** Selecting the
    /// first hit the walk meets is what this did first, and it is wrong in the way
    /// that is obvious the moment it is used: search for a word that is on the
    /// screen in front of you, and the transcript jumps to the top of the history
    /// to show you a different one. Every find bar starts at the reader's position
    /// and wraps, so the hit that selects itself is the first one **at or after the
    /// first visible row**, and the wrap — for a query whose every hit is above
    /// them — happens once the walk is done, in `completeFind()`.
    ///
    /// The row numbers in `batch` are trusted here because `scan` only calls this
    /// while the slice is still `pending` — nothing has renumbered them.
    private func publish(_ batch: FindBatch, covering range: Range<Int>) {
        guard var find else { return }

        let viewport = firstVisibleRow
        var landing: (row: Int, id: TranscriptRow.ID, range: Range<Int>)?
        var changed = false

        for found in batch where !find.refiled.contains(found.id) {
            if Self.file(found.ranges, searched: found.content, for: found.id, in: &find) {
                changed = true
            }
            if find.landsOnViewport, find.selection == nil, landing == nil,
                found.row >= viewport, let first = found.ranges.first
            {
                landing = (found.row, found.id, first)
            }
        }
        find.next = range.upperBound
        find.pending = nil
        self.find = find

        if let landing {
            select(row: landing.row, id: landing.id, range: landing.range, ordinal: nil)
        } else if changed {
            rebindFind()
        }
        if changed { reportFind() }
    }

    /// Ends a walk that reached the last row.
    ///
    /// A first pass that found hits but none at or below the reader wraps to the
    /// first one — the same wrap `findNext()` makes off the end of the transcript,
    /// and what lets `publish` be strict about "at or after the viewport" without
    /// the case where nothing is falling through it.
    private func completeFind() {
        finding = nil
        guard var find else { return }
        find.isComplete = true
        let wraps = find.landsOnViewport && find.selection == nil && find.count > 0
        find.landsOnViewport = false
        self.find = find
        if wraps {
            // Reports on its way out, so this branch does not report twice.
            moveFindSelection(by: 1)
        } else {
            reportFind()
        }
    }

    /// Files what one row matched, keeping the count, the selection and the
    /// ordinal in step. Answers whether anything changed.
    ///
    /// **Replaces, never adds.** A row can be searched more than once — a refresh,
    /// a reload, a walk pulled back by an insertion — and the count has to move by
    /// the difference, not by the whole of each answer.
    private static func file(
        _ ranges: [Range<Int>], searched content: TranscriptRowContent,
        for id: TranscriptRow.ID, in find: inout Find
    ) -> Bool {
        let old = find.matches[id]
        let new = ranges.isEmpty ? nil : RowMatches(content: content, ranges: ranges)
        guard new != old else { return false }

        find.matches[id] = new
        find.count += ranges.count - (old?.ranges.count ?? 0)
        if new?.ranges != old?.ranges {
            // Conservative: a row after the selection cannot move its ordinal, but
            // knowing which side a row is on costs the walk this is saving.
            find.ordinal = nil
            if let selection = find.selection, selection.row == id,
                !ranges.contains(selection.range)
            {
                find.selection = nil
            }
        }
        return true
    }

    /// The topmost row the reader can see — where a fresh find starts looking.
    ///
    /// The table's own answer rather than a tracked one, and it is allowed to be
    /// approximate: a row half under the top inset counts as visible, which is the
    /// forgiving direction. `NSNotFound` is a viewport with no rows in it, which a
    /// transcript that has not laid out yet reports.
    private var firstVisibleRow: Int {
        let visible = tableView.rows(in: tableView.visibleRect)
        return visible.location == NSNotFound ? 0 : max(0, visible.location)
    }

    /// Tells the delegate where the find has got to.
    ///
    /// One funnel rather than a call beside every mutation: the call means *this
    /// is the find's state now*, so every path that changes it — the matches, the
    /// current one, the walk finishing — reports through here, and none can
    /// forget to.
    private func reportFind() {
        guard let find else { return }
        delegate?.transcriptView(
            self, didUpdateFindMatches: find.count, isComplete: find.isComplete)
    }

    /// Moves the selection `delta` hits along, wrapping at both ends — or, with
    /// nothing selected, onto the nearest hit from the reader in that direction.
    ///
    /// The order is re-derived here rather than kept, which costs one `rowAt` per
    /// row — the same walk `sweepCache()` makes, on a keystroke rather than in a
    /// loop. Keeping it instead would mean a list of positions that every insertion
    /// renumbers, which is the bookkeeping `RowCache`'s identity keying exists to
    /// have deleted; and it would still have to be rebuilt after any mutation, so
    /// what it saves is a walk the reader is waiting on either way.
    private func moveFindSelection(by delta: Int) {
        let hits = locatedHits()
        guard !hits.isEmpty else { return }

        let target: Int
        if let selection = find?.selection,
            let current = hits.firstIndex(where: {
                $0.id == selection.row && $0.range == selection.range
            })
        {
            target = ((current + delta) % hits.count + hits.count) % hits.count
        } else {
            let viewport = firstVisibleRow
            let after = hits.firstIndex { $0.row >= viewport } ?? hits.count
            target = delta > 0 ? after % hits.count : (after + hits.count - 1) % hits.count
        }
        let hit = hits[target]
        select(row: hit.row, id: hit.id, range: hit.range, ordinal: target)
        reportFind()
    }

    /// Every hit in transcript order, with where its row is now.
    ///
    /// Rows the data source no longer has simply do not turn up, so a hit in a row
    /// that went away is skipped rather than navigated to — the same shape as
    /// `staleRowsOutwardFromViewport(at:)` dropping entries a removal orphaned.
    private func locatedHits() -> [(row: Int, id: TranscriptRow.ID, range: Range<Int>)] {
        guard let find, !find.matches.isEmpty, let dataSource else { return [] }
        var hits: [(row: Int, id: TranscriptRow.ID, range: Range<Int>)] = []
        for row in 0..<numberOfRows {
            let id = dataSource.transcriptView(self, rowAt: row).id
            guard let ranges = find.matches[id]?.ranges else { continue }
            hits.append(contentsOf: ranges.map { (row, id, $0) })
        }
        return hits
    }

    /// How many hits come before `selection`, in transcript order.
    ///
    /// The walk `locatedHits()` makes, stopping at the selection's row — so what a
    /// find bar asking after every report costs is the distance to the reader, and
    /// only when something has cleared the cached answer.
    private func ordinal(
        of selection: (row: TranscriptRow.ID, range: Range<Int>), in find: Find
    ) -> Int? {
        guard let dataSource else { return nil }
        var before = 0
        for row in 0..<numberOfRows {
            let id = dataSource.transcriptView(self, rowAt: row).id
            guard let ranges = find.matches[id]?.ranges else { continue }
            if id == selection.row {
                return ranges.firstIndex(of: selection.range).map { before + $0 }
            }
            before += ranges.count
        }
        return nil
    }

    /// Makes one hit the current one: records it, brings it on screen, repaints.
    private func select(row: Int, id: TranscriptRow.ID, range: Range<Int>, ordinal: Int?) {
        find?.selection = (id, range)
        find?.ordinal = ordinal
        scrollFindMatchToVisible(range, inRow: row)
        rebindFind()
    }

    /// Brings a hit on screen — the hit, not only its row, because a row is a
    /// whole message and a long one is several screens tall: scrolling its nearest
    /// edge into view can leave the match itself a page away.
    ///
    /// A self-drawn row knows where a range is (`rects(from:to:)`), and it is
    /// asked of the tree rather than of a view, so a row nothing has tiled yet
    /// answers as well as one on screen. A hit already wholly in view stays where
    /// it is; one that is not is centred, which is where Safari and Xcode put a
    /// match they move to — the reader sees what surrounds it on both sides.
    ///
    /// A `.view` row's geometry is its host's, so there the row is brought to its
    /// nearest edge instead.
    private func scrollFindMatchToVisible(_ range: Range<Int>, inRow row: Int) {
        guard let described = dataSource?.transcriptView(self, rowAt: row),
            let block = measuredBlock(for: described),
            let hit = block.rects(from: range.lowerBound, to: range.upperBound)
                .reduce(nil, { (union: CGRect?, rect) in union?.union(rect) ?? rect })
        else {
            return scrollToRow(at: row, scrollPosition: .nearestEdge)
        }
        // The block is drawn from the cell's top edge, and the cell is the row's
        // rectangle less the row spacing — which `frameOfCell` already knows.
        let top = tableView.frameOfCell(atColumn: 0, row: row).minY
        let minY = top + hit.minY
        let maxY = top + hit.maxY
        let visible = unobscuredRect
        guard minY < visible.minY || maxY > visible.maxY else { return }
        scrollClip(toUnobscuredMinY: (minY + maxY - visible.height) / 2)
    }

    /// Shows the find as it stands now, or takes it away.
    ///
    /// Called wherever the find changes — its matches, its selection, its end.
    /// Every other reason the overlay has to look again is a row moving under it,
    /// and those reach `setNeedsFindLayout()` on their own.
    private func rebindFind() {
        findOverlay.isHidden = find == nil
        placeFindOverlay()
        setNeedsFindLayout()
    }

    /// Keeps the overlay over what is on screen: the clip's bounds, which are in
    /// the document's coordinates and so in the overlay's, with half a screen to
    /// spare either way.
    ///
    /// The overlay moves with the document on its own — AppKit carries a floating
    /// subview through a scroll the way it carries the rows — so this is not what
    /// keeps a lit match on its text. It is what keeps the *dimming* reaching the
    /// edge of the viewport as the reader travels further than the spare half
    /// screen, and what brings rows that have scrolled in under the overlay.
    ///
    /// A scroll inside the spare half screen changes nothing here: the rows it
    /// brings in report themselves as they arrive (`setNeedsFindLayout()`), so
    /// the overlay is not laid out — and its shade not redrawn — once per wheel
    /// event for nothing.
    private func placeFindOverlay() {
        guard find != nil else { return }
        let visible = scrollView.contentView.bounds
        guard !findOverlay.frame.contains(visible) || findOverlay.frame.width != visible.width
        else { return }
        findOverlay.frame = visible.insetBy(dx: 0, dy: -visible.height / 2)
        findOverlay.needsLayout = true
    }

    /// Asks the overlay to read the rows on screen again, if a find is up.
    fileprivate func setNeedsFindLayout() {
        guard find != nil else { return }
        findOverlay.needsLayout = true
    }

    /// The rows on screen that have matches, as the overlay asks for them.
    ///
    /// Filed matches are shown only for the content they were found in, so a row
    /// whose text has moved on since is lit nowhere rather than at ranges that name
    /// other characters now.
    private func findRowsOnScreen() -> [FindOverlayView.Row] {
        guard let find, let dataSource else { return [] }
        var rows: [FindOverlayView.Row] = []
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self,
                let cell = rowView.view(atColumn: 0) as? TranscriptCellView,
                let view = cell.hostedView as? NSView & TranscriptFindHighlighting
            else { return }
            let described = dataSource.transcriptView(self, rowAt: row)
            guard let filed = find.matches[described.id], filed.content == described.content
            else { return }
            let current = find.selection.flatMap { $0.row == described.id ? $0.range : nil }
            rows.append(.init(id: described.id, view: view, matches: filed.ranges, current: current))
        }
        return rows
    }

    /// Searches again the rows `reloadRows(at:)` announced changed — the ones the
    /// walk has passed or has out, since it will reach the rest on its own.
    ///
    /// On the main actor and on the spot, because the table is about to measure
    /// these rows anyway: a changed row is a changed height, so the tree this
    /// searches is the one its height is answered from. For the streaming row that
    /// is one search of one row a frame, and only while a find is up.
    private func refileFind(inRows rows: IndexSet) {
        guard var find, let dataSource else { return }
        let covered = min(find.pending?.upperBound ?? find.next, numberOfRows)
        var changed = false
        for row in rows where row < covered {
            let described = dataSource.transcriptView(self, rowAt: row)
            let ranges =
                described.content == .view
                ? delegate?.transcriptView(self, findMatchesOf: find.query, inRow: row) ?? []
                : measuredBlock(for: described)?.ranges(of: find.query) ?? []
            if find.pending?.contains(row) == true {
                find.refiled.insert(described.id)
            }
            if Self.file(ranges, searched: described.content, for: described.id, in: &find) {
                changed = true
            }
        }
        self.find = find
        guard changed else { return }
        rebindFind()
        reportFind()
    }

    /// Renumbers the walk for rows inserted at `indexes` (post-insertion
    /// positions), and resumes a walk that had finished so it takes them in.
    ///
    /// Rows landing *behind* the cursor pull it back to the first of them rather
    /// than past them: the walk re-reads what lies between, which the cache
    /// answers, and nothing inserted goes unsearched. A slice out on the pool that
    /// the insertion renumbered is abandoned — `scan` takes it again.
    ///
    /// Not reported: nothing has been found yet. The walk reports as it files, and
    /// `isComplete` goes back to `true` when it reaches the end again.
    private func shiftFind(byRowsInserted indexes: IndexSet) {
        guard var find, let first = indexes.first else { return }
        if let pending = find.pending, first < pending.upperBound {
            find.pending = nil
        }
        find.next = min(find.next, first)
        self.find = find
        if finding == nil { walkFind() }
    }

    /// Renumbers the walk for rows removed at `indexes` (pre-removal positions).
    /// Their hits went with the sweep `removeRows(at:)` makes first.
    private func shiftFind(byRowsRemoved indexes: IndexSet) {
        guard var find, let first = indexes.first else { return }
        if let pending = find.pending, first < pending.upperBound {
            find.pending = nil
        }
        find.next -= indexes.count(in: 0..<find.next)
        self.find = find
    }

    /// Drops hits for rows the data source no longer has.
    ///
    /// Called from `sweepCache()`, off the same walk and the same live set, because
    /// the two answer one question — which identities still name a row — and asking
    /// it twice is how the answers come to differ. Not reported here: this runs
    /// inside a mutation, before the table has been told, and anything read in
    /// answer to the report would walk rows the table does not have yet. The
    /// mutation reports once it is done.
    private func keepFind(_ live: Set<TranscriptRow.ID>) {
        guard var find else { return }
        let gone = find.matches.keys.filter { !live.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            find.count -= find.matches.removeValue(forKey: id)?.ranges.count ?? 0
        }
        find.ordinal = nil
        if let selection = find.selection, !live.contains(selection.row) {
            find.selection = nil
        }
        self.find = find
    }

    // MARK: - Selection
    //
    // A selection runs from a position in one row to a position in another, so it
    // is held here, where rows have identities and outlive their views, rather
    // than on the views — which is `NSTableView`'s split, the table holding the
    // selection and handing each row view its `isSelected`. A press on a
    // `BlockView` goes up the responder chain to the table, like any mouse event
    // a view does not take, and the view draws what it is handed
    // (`selectedRange`); nothing about it is on the public surface.
    //
    // The responder is the table, the scroll view's document view, the way it is
    // an `NSTextView` and not its scroll view: it takes first responder on a
    // press, answers Copy, and drops the selection when the focus moves on —
    // how a selection in one transcript goes away when the reader starts one in
    // another. Keyboard handling stays exactly what it was, because the row view
    // that used to hold the focus passed every key up to this same table.
    //
    // What it costs where the transcript is hot: nothing, until something is
    // selected. A row bound (`viewForRow`, `rebindVisibleRows`) reads its part —
    // arithmetic on four integers — and an insert renumbers two. Only a press or a
    // drag walks anything, and only when the focus moved: it walks the row views
    // on screen, repainting those whose part changed.

    /// The reader's selection, or a caret after a click, or `nil`.
    private var selection: TextSelection?

    /// A press, and everything until the button comes back up. The one way into a
    /// selection made with the mouse, reached from a row or from the table
    /// between rows through the responder chain.
    ///
    /// A tracking loop — `NSTextView`'s shape, and `NSTableView`'s — rather than
    /// drags dispatched to whichever view was pressed, because the focus is a
    /// function of two things: where the pointer is **and where the content is**.
    /// Either can move without the other, so the loop re-reads the focus on
    /// both: a drag moves the pointer; a periodic event scrolls the content under
    /// a pointer held past an edge, at a steady rate whether or not the mouse
    /// moves; and a scroll wheel does it at the reader's.
    ///
    /// Nothing between the press and the release is dispatched to a view, so no
    /// view has to outlive its row for the gesture to finish.
    fileprivate func trackSelection(from event: NSEvent) {
        beginSelection(with: event)
        guard let window, selection != nil else { return }

        // The press that started this, then each drag: where the pointer is in the
        // window, which is what autoscroll and the focus are both worked out from.
        var pointer = event
        NSEvent.startPeriodicEvents(afterDelay: Self.autoscrollDelay, withPeriod: Self.autoscrollPeriod)
        defer { NSEvent.stopPeriodicEvents() }
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .periodic, .scrollWheel],
            timeout: NSEvent.foreverDuration, mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            switch event.type {
            case .leftMouseDragged: pointer = event
            // Scrolls by how far past the edge the pointer is, so the reader sets
            // the speed by where they hold it; inside the viewport, nothing moved.
            case .periodic: guard tableView.autoscroll(with: pointer) else { return }
            case .scrollWheel: scrollView.scrollWheel(with: event)
            default:
                stop.pointee = true
                return
            }
            extendSelection(to: pointer)
        }
    }

    /// How soon a pointer held past an edge starts scrolling, and how often it
    /// scrolls again: a frame, so the rows arriving move as a scroll does.
    private static let autoscrollDelay: TimeInterval = 0.1
    private static let autoscrollPeriod: TimeInterval = 1.0 / 60

    /// Moves the selection's focus to what is under `pointer` now.
    private func extendSelection(to pointer: NSEvent) {
        guard var selection, let hit = selectionHit(at: pointer) else { return }
        selection.focus = .init(row: hit.row, id: hit.id, index: hit.block?.index(at: hit.point) ?? 0)
        guard selection != self.selection else { return }
        select(selection)
    }

    /// Starts a selection at a press: a caret, or — for a double- or triple-click
    /// — the word or paragraph under it. Which unit that is, is the block's to
    /// answer, and the **point** goes over for the two that take one: an index at
    /// a line boundary names two places, and only the point can tell them apart.
    private func beginSelection(with event: NSEvent) {
        window?.makeFirstResponder(tableView)
        guard let hit = selectionHit(at: event) else { return select(nil) }
        let range: Range<Int>
        switch (hit.block, event.clickCount) {
        case (let block?, 2): range = block.wordRange(at: hit.point)
        case (let block?, 3...): range = block.paragraphRange(at: hit.point)
        case (let block?, _):
            let index = block.index(at: hit.point)
            range = index..<index
        case (nil, _): range = 0..<0
        }
        select(TextSelection(row: hit.row, id: hit.id, range: range))
    }

    /// What a right-click acts on, settled before its menu is shown.
    ///
    /// Two things, and both are why this is not a pure getter. **The focus** moves
    /// to the selection's responder, because a menu item with a `nil` target
    /// dispatches from the window's first responder, not from the view the menu
    /// came from — right-clicking a row nobody has clicked would otherwise
    /// validate Copy against whatever held the focus. And **the word under the
    /// pointer** is selected, unless the click landed inside the selection, which
    /// is then what the reader is pointing at. `NSTextView` and WebKit both do
    /// this; the alternative is a menu whose only item is greyed out.
    ///
    /// Inside is tested in the index space rather than geometrically, which is
    /// `NSTextView`'s test too — and for a table, whose selection is a rectangle,
    /// the endpoints are what a copy would be taken from.
    fileprivate func selectForContextMenu(with event: NSEvent) {
        window?.makeFirstResponder(tableView)
        guard let hit = selectionHit(at: event), let block = hit.block else { return }
        if selection?.contains(row: hit.row, index: block.index(at: hit.point)) == true { return }
        select(TextSelection(row: hit.row, id: hit.id, range: block.wordRange(at: hit.point)))
    }

    /// The row under `event` and the point in its block's own coordinates.
    ///
    /// Clamped rather than failing: above the rows is the start of the first and
    /// below them the end of the last — `NSTextView`'s answer past its first and
    /// last lines — so a drag that leaves the rows selects to the end, and the
    /// block clamps a point beside its text the same way.
    /// Worked out from the table's geometry, not from a view, so a row with no
    /// view on screen answers as well as one with — and a drag keeps working when
    /// the view it started on has been recycled. `block` is `nil` for a `.view`
    /// row, whose content has no positions: the selection passes through it.
    private func selectionHit(
        at event: NSEvent
    ) -> (row: Int, id: TranscriptRow.ID, block: MeasuredBlock?, point: CGPoint)? {
        guard numberOfRows > 0, let dataSource else { return nil }
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: NSPoint(x: tableView.bounds.midX, y: point.y))
        let above = row < 0 && point.y < 0
        let clamped = row >= 0 ? row : above ? 0 : numberOfRows - 1

        let described = dataSource.transcriptView(self, rowAt: clamped)
        // The block is drawn from the cell's top edge, centred at the content
        // width — `TranscriptCellView`'s arrangement.
        let cell = tableView.frameOfCell(atColumn: 0, row: clamped)
        let local =
            row >= 0
            ? CGPoint(x: point.x - (cell.midX - contentWidth / 2), y: point.y - cell.minY)
            : above ? .zero : CGPoint(x: contentWidth, y: cell.height)
        return (
            clamped, described.id,
            described.content == .view ? nil : measuredBlock(for: described), local
        )
    }

    /// Makes `selection` the selection and shows it.
    private func select(_ selection: TextSelection?) {
        self.selection = selection
        pushSelection()
    }

    /// Hands every row view on screen its part of the selection. A view whose
    /// part did not change is not repainted (`BlockView.selectedRange`), so a drag
    /// inside one row repaints that row alone.
    private func pushSelection() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let view = (rowView.view(atColumn: 0) as? TranscriptCellView)?.hostedView as? BlockView,
                let block = view.block
            else { return }
            view.selectedRange = selection?.range(inRow: row, length: block.length)
        }
    }

    /// Finds the selection's rows again after a removal or a reload, or drops it
    /// when a row one of its ends was in has gone.
    ///
    /// Runs inside the mutation, before the table has been told — so it shows
    /// nothing unless the selection went. A selection that survived is still
    /// correct in every view on screen: what each shows is its part of the same
    /// text, whatever number its row now has.
    private func keepSelection(_ rows: [TranscriptRow.ID: Int]) {
        guard let selection else { return }
        self.selection = selection.relocated(to: rows)
        if self.selection == nil { pushSelection() }
    }

    /// The table stopped being first responder.
    fileprivate func selectionDidResign() {
        guard selection != nil else { return }
        select(nil)
    }

    /// Whether Copy has anything to copy.
    fileprivate var canCopySelection: Bool {
        selection.map { !$0.isEmpty } ?? false
    }

    /// Copies the selection as plain text, a blank line between rows.
    ///
    /// A row the selection covers that nothing has measured — it can run through
    /// rows the reader dragged past without the table ever asking about — is
    /// built for this and dropped, not filed: the same rule as a find's walk, for
    /// the same reason: filing it would push the rows on screen out of `RowCache`'s
    /// resident budget to make room for rows nobody is looking at. That includes a
    /// row whose tree the budget already evicted, which reads as unmeasured here and
    /// is rebuilt the same way. The flat index space depends on
    /// the content and not the width, so a tree measured at any width answers.
    /// `.view` rows contribute nothing; their content is the host's.
    fileprivate func copySelection() {
        guard let selection, !selection.isEmpty, let dataSource else { return }
        var parts: [String] = []
        for row in selection.rows where row < numberOfRows {
            let described = dataSource.transcriptView(self, rowAt: row)
            guard
                let block = rowCache.cachedMeasured(for: described, width: nil)
                    ?? RowCache.Entry(measuring: described.content, width: contentWidth, reusing: nil)?
                    .measured,
                let range = selection.range(inRow: row, length: block.length)
            else { continue }
            let text = block.text(from: range.lowerBound, to: range.upperBound)
            if !text.isEmpty { parts.append(text) }
        }
        guard !parts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
    }

    // MARK: - Scroll anchoring

    /// How a mutation renumbers the rows the anchor is expressed in.
    private enum AnchorShift {

        /// Row indices are unchanged: content or height moved, identity didn't.
        case none

        /// Positions in the post-insertion data, as `insertRows` takes them.
        case inserted(IndexSet)

        /// Positions in the pre-removal data, as `removeRows` takes them.
        case removed(IndexSet)
    }

    /// The anchor sampled for the mutation currently in flight — `nil` between
    /// mutations. Not state that outlives a call; see `ScrollAnchor`.
    private var anchor: ScrollAnchor?

    /// How many nested mutations are in flight. The outermost samples and
    /// restores; every inner one shifts the anchor and otherwise stands aside.
    ///
    /// Which makes nesting harmless rather than merely documented: `reloadRows`
    /// calling the table twice, a host wrapping three mutations in
    /// `beginUpdates()`, or both at once all reduce to one sample and one
    /// restore, and no call has to know what it might be nested inside.
    private var anchorDepth = 0

    /// Runs `body` with the viewport held: the anchor is sampled before it,
    /// renumbered by `shift` after it, and restored once the outermost mutation
    /// finishes.
    ///
    /// A closure rather than a sample/restore pair at each call site because the
    /// pair can be got wrong and this cannot — but the pair still exists, because
    /// `beginUpdates()` / `endUpdates()` spans two calls the host makes and no
    /// closure can reach across that.
    private func mutate(shiftedBy shift: AnchorShift, _ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        suppressImplicitAnimation()
        defer { NSAnimationContext.endGrouping() }

        beginAnchoring()
        // Before `body`, not after it like the anchor: the table may ask for a
        // new row's view inside its own call, and that view's part of the
        // selection is read against these indices. A removal is renumbered by
        // identity instead, in the sweep `removeRows` runs inside `body`.
        if case .inserted(let indexes) = shift {
            selection = selection?.shifted(byRowsInserted: indexes)
        }
        body()
        switch shift {
        case .none: break
        case .inserted(let indexes):
            anchor = anchor?.shifted(byRowsInserted: indexes)
            shiftFind(byRowsInserted: indexes)
        case .removed(let indexes):
            anchor = anchor?.shifted(byRowsRemoved: indexes)
            shiftFind(byRowsRemoved: indexes)
        }
        endAnchoring()
    }

    /// Turns layer animations off for the animation grouping the caller has opened.
    ///
    /// Load-bearing for anchoring, and the reason is worth stating because no
    /// geometry assertion can catch a regression here — only the layers'
    /// `animationKeys()` can, which is what `ResizeRemeasureTests` reads for the
    /// width-change path. In a layer-backed window — which any
    /// `NSVisualEffectView` in the tree makes it — the row geometry a mutation
    /// changes is an animatable property, so the rows slide to their new positions
    /// over a quarter second while the compensating scroll offset is written
    /// instantly. The content visibly shakes and settles, and every number involved
    /// is already final while it happens: `frame` reads the end state, and the
    /// animation is in the presentation layer, where a test cannot see it.
    ///
    /// So the pair has to land in one visual state, and suppressing is the half to
    /// pick: a compensating scroll is not something anyone asked to see. There is no
    /// escape hatch on purpose — an animated row mutation and a held viewport are
    /// mutually exclusive, so the mutations don't offer the animation (see
    /// `insertRows(at:)`).
    private func suppressImplicitAnimation() {
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)
    }

    private func beginAnchoring() {
        anchorDepth += 1
        guard anchorDepth == 1 else { return }
        anchor = sampledAnchor()
    }

    private func endAnchoring() {
        // Unbalanced `endUpdates()`: the table raises its own objection, and
        // decrementing past zero here would leave every later mutation off by one.
        guard anchorDepth > 0 else { return }
        anchorDepth -= 1
        guard anchorDepth == 0, let anchor else { return }
        self.anchor = nil
        restore(anchor)
        reportTailFollowing()
    }

    /// Where the viewport is now, as something that can be re-found afterwards.
    private func sampledAnchor() -> ScrollAnchor {
        guard numberOfRows > 0, !isScrolledToTail else { return .tail }
        let visible = unobscuredRect
        let rows = tableView.rows(in: visible)
        guard rows.length > 0 else { return .tail }
        return .row(
            rows.location, offsetFromTop: visible.minY - tableView.rect(ofRow: rows.location).minY)
    }

    /// Restores immediately rather than on the next layout pass — waiting would be
    /// a frame drawn at the old offset.
    ///
    /// The flush is not for the numbers. `rect(ofRow:)` and the document view's
    /// height both resolve the mutation's geometry on demand, so the arithmetic
    /// below is right without it — measured, by deleting it and watching every
    /// offset assertion still pass. It is here so the table has positioned its row
    /// views before the offset moves, on the reasoning that moving the viewport
    /// past rows that are still at their old positions is a frame worth not
    /// drawing. That last part is reasoning, not a measurement: the flicker it was
    /// first added for turned out to be an implicit animation instead (see
    /// `suppressImplicitAnimation`), and no assertion can tell the difference.
    private func restore(_ anchor: ScrollAnchor) {
        tableView.layoutSubtreeIfNeeded()
        switch anchor {
        case .tail:
            scrollClipToTail()
        case .row(let row, let offsetFromTop):
            guard numberOfRows > 0 else { return }
            // A removal that reached the end can leave the anchor past the last
            // row; the clamp is here rather than in the shift so the shift stays
            // arithmetic on indices and needs no row count.
            let clamped = min(row, numberOfRows - 1)
            scrollClip(toUnobscuredMinY: tableView.rect(ofRow: clamped).minY + offsetFromTop)
        }
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
        beginAnchoring()
        tableView.beginUpdates()
    }

    /// Ends a `beginUpdates()` group, applies the coalesced mutations, and
    /// restores the scroll anchor sampled at `beginUpdates()`.
    public func endUpdates() {
        // The coalesced geometry lands here, so this is where it has to be kept in
        // the same visual state as the restore that follows it.
        NSAnimationContext.beginGrouping()
        suppressImplicitAnimation()
        // The table's coalesced mutations have to land before the anchor is
        // restored against the geometry they produce.
        tableView.endUpdates()
        endAnchoring()
        NSAnimationContext.endGrouping()
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
    ///
    /// Positions are measured against the area the host's chrome is *not*
    /// covering, so `.top` lands the row below a top `contentInsets`, not
    /// underneath it. An out-of-range row does nothing, and a position the scroll
    /// cannot reach lands as close as the range allows.
    public func scrollToRow(at row: Int, scrollPosition: ScrollPosition) {
        guard row >= 0, row < numberOfRows else { return }
        // No layout pass forced first: `rect(ofRow:)` resolves row geometry on
        // demand, `reloadData()` in the same tick included — measured, by
        // reloading a longer transcript and scrolling to a row that only exists
        // after the reload.
        let rowRect = tableView.rect(ofRow: row)
        let visible = unobscuredRect

        switch scrollPosition {
        case .top:
            scrollClip(toUnobscuredMinY: rowRect.minY)
        case .center:
            scrollClip(toUnobscuredMinY: rowRect.midY - visible.height / 2)
        case .bottom:
            scrollClip(toUnobscuredMinY: rowRect.maxY - visible.height)
        case .nearestEdge:
            // A row taller than the viewport cannot be brought fully in, so its
            // start is shown — `NSTableView.scrollRowToVisible(_:)`'s behaviour,
            // and the only reading of "least amount" that terminates.
            if rowRect.height >= visible.height || rowRect.minY < visible.minY {
                scrollClip(toUnobscuredMinY: rowRect.minY)
            } else if rowRect.maxY > visible.maxY {
                scrollClip(toUnobscuredMinY: rowRect.maxY - visible.height)
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
    /// menu" would be indistinguishable from having no delegate — and would
    /// silently get the default menu instead.
    func blockView(_ view: BlockView, menu: NSMenu, for event: NSEvent) -> NSMenu? {
        // Before the host sees the menu: what it acts on is decided here.
        selectForContextMenu(with: event)
        guard let delegate else { return menu }
        return delegate.transcriptView(self, menu: menu, forRow: row(of: view))
    }
}

extension TranscriptView: TableViewAdapterOwner {

    var numberOfRowsInDataSource: Int {
        dataSource?.numberOfRows(in: self) ?? 0
    }
}

extension TranscriptView: TranscriptTableViewOwner {

    func tableViewDidTile(_ tableView: TranscriptTableView) {
        setNeedsFindLayout()
        reportTailFollowing()
    }

    func tableViewDidLayout(_ tableView: TranscriptTableView) {
        setNeedsFindLayout()
    }

    func tableView(_ tableView: TranscriptTableView, trackSelectionFrom event: NSEvent) {
        trackSelection(from: event)
    }

    func tableViewDidResignFirstResponder(_ tableView: TranscriptTableView) {
        selectionDidResign()
    }

    func tableView(_ tableView: TranscriptTableView, performScrollCommand selector: Selector) -> Bool {
        performScrollCommand(selector)
    }

    func tableViewCopySelection(_ tableView: TranscriptTableView) {
        copySelection()
    }

    func tableViewCanCopySelection(_ tableView: TranscriptTableView) -> Bool {
        canCopySelection
    }
}

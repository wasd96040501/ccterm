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
/// (`prepareRows(_:)`) — see §6 of the package's CLAUDE.md.
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
/// A window resize is outside both: the content width moving reflows every row,
/// and holding the viewport still through that would mean writing a scroll offset
/// from inside the scroll view's own tile.
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

    /// Row `row`'s content, built and measured at the current content width — or
    /// handed back from the cache, which is the usual case: `NSTableView` asks for
    /// a height and then, for the rows it is about to show, a view. `nil` for
    /// content the transcript does not draw itself.
    ///
    /// **The one place a content case names a block recipe.** Three callers need
    /// that mapping — the height answer, the view answer, and the re-measure a
    /// width or a content change forces — and a second copy of it is how one of
    /// them comes to be missing a case: not as a failure, but as a row that
    /// quietly stops being re-measured.
    ///
    /// Both self-drawn cases hand their **source** to the cache rather than only a
    /// way to rebuild, which is what lets the cache notice a content change
    /// instead of being told about one. What differs is the rebuild: a document
    /// reuses the blocks that did not move (`MarkdownMemo`), a bubble is one block
    /// and is rebuilt whole.
    private func measuredBlock(forRow row: Int, content: TranscriptRowContent) -> MeasuredBlock? {
        switch content {
        case .markdown(let source):
            return rowCache.measuredMarkdown(forRow: row, source: source, width: contentWidth)

        // The recipe named here has to be the one
        // `TranscriptRowContent.measured(width:)` applies, or a prepared row and
        // an on-demand one answer the same question differently. Held by
        // `PreparedRowsTests.testPreparedAndOnDemandAgree` rather than by this
        // comment; a recipe is what the cache wants and a measurement is what a
        // background task can carry, so the two call sites cannot be one.
        case .userMessage(let text):
            return rowCache.measuredBlock(forRow: row, source: text, width: contentWidth) {
                UserMessage(text)
            }

        // A `.view` row is the host's, block and all.
        case .view:
            return nil
        }
    }

    /// How tall row `row` is. `.view` rows are the delegate's to measure; the
    /// self-drawn cases the transcript measures itself, from the same tree it
    /// will later draw.
    fileprivate func height(ofRow row: Int) -> CGFloat {
        let answer: CGFloat
        switch dataSource?.transcriptView(self, contentForRow: row) {
        case .view:
            guard let delegate else { return Self.minimumRowHeight }
            answer = delegate.transcriptView(self, heightOfRow: row, width: contentWidth)

        case .some(let content):
            answer = measuredBlock(forRow: row, content: content)?.size.height ?? 0

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
    fileprivate func view(forRow row: Int) -> NSView? {
        guard let content = dataSource?.transcriptView(self, contentForRow: row) else {
            return nil
        }

        let cell =
            tableView.makeView(withIdentifier: TranscriptCellView.identifier, owner: nil)
            as? TranscriptCellView ?? TranscriptCellView()

        let hosted: NSView
        switch content {
        case .markdown, .userMessage:
            guard let block = measuredBlock(forRow: row, content: content) else { return nil }
            hosted = blockView(in: cell, showing: block, forRow: row)

        case .view:
            guard let delegate else { return nil }
            configuringCell = cell
            defer { configuringCell = nil }
            hosted = delegate.transcriptView(self, viewForRow: row)
        }

        cell.install(hosted, minWidth: minContentWidth, maxWidth: maxContentWidth)
        return cell
    }

    /// The view a self-drawn row is served through, bound to `block`.
    ///
    /// One path for every self-drawn case rather than one per case: what differs
    /// between a document and a user's bubble is the tree, and the tree is settled
    /// by the time this runs. A bubble carries no links today, so three of these
    /// four lines do nothing for it — which is the point. Nothing here has to know
    /// which case it is serving, so nothing here has to be revisited when another
    /// one lands.
    private func blockView(
        in cell: TranscriptCellView, showing block: MeasuredBlock, forRow row: Int
    ) -> BlockView {
        // Recycled through the cell it was already installed in, so a row
        // scrolling back into view rebuilds no constraints. Falls back to a fresh
        // instance when the pool hands over a cell that was serving a `.view` row.
        let view = cell.hostedView as? BlockView ?? BlockView()
        view.configure(with: block)
        // Re-bound on every pass rather than once at construction: the view is
        // recycled, and `row` is captured only as the fallback for a lookup that
        // can fail once the view has left the table.
        view.onLinkActivated = { [weak self] view, link in
            guard let self else { return }
            let current = self.row(for: view)
            switch link.destination {
            case .url(let url):
                self.delegate?.transcriptView(
                    self, didActivate: url, inRow: current >= 0 ? current : row)

            case .more:
                self.delegate?.transcriptView(
                    self, didActivateMoreInRow: current >= 0 ? current : row)
            }
        }
        view.onLinkHovered = { [weak self] view, url, point in
            guard let self else { return }
            let current = self.row(for: view)
            self.delegate?.transcriptView(
                self, didHover: url, at: self.convert(point, from: view),
                inRow: current >= 0 ? current : row)
        }
        // Not `delegate?.transcriptView(…) ?? menu`: optional-chaining a method
        // that itself returns an optional flattens the two, so a host answering
        // "show no menu" would be indistinguishable from having no delegate — and
        // would silently get the default menu instead.
        view.onContextMenu = { [weak self] view, menu in
            guard let self, let delegate = self.delegate else { return menu }
            let current = self.row(for: view)
            return delegate.transcriptView(
                self, menu: menu, forRow: current >= 0 ? current : row)
        }
        return view
    }

    /// Reports the row leaving the viewport. What goes back into the pool is the
    /// cell, but what the host has work to stop on is the view it supplied — so
    /// that is what it hears about.
    fileprivate func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
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

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        // No selection API on the transcript, so no selection to draw.
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

    /// Answers the table's data source and delegate callbacks on the
    /// transcript's behalf, so that AppKit's table protocols stay off the
    /// package's public surface — and so a host can't be handed the transcript
    /// as a data source for a table of its own. Owned here; the table refers to
    /// it weakly.
    private lazy var tableAdapter = TableViewAdapter(transcript: self)

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
    /// clamped into `minContentWidth ... maxContentWidth`. This is the number
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
    private func contentWidthDidChange() {
        let width = contentWidth
        guard width != measuredContentWidth else { return }
        measuredContentWidth = width
        guard numberOfRows > 0 else { return }

        rebindVisibleRows(in: nil)

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
    /// `measuredBlock(forRow:content:)` everywhere except here would keep its
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
    /// the recycling entry point: it drops the selection and the hover band,
    /// because a pooled cell arriving with a highlight over the previous
    /// document's words is a bug. `remeasured` keeps both, on the grounds that
    /// the endpoints still name the same characters. That holds exactly when the
    /// new source **extends** the old one: the blocks before the divergence
    /// parse the same, so they occupy the same flat index space they did. A
    /// source that is not an extension gets `configure`, which covers a rewrite,
    /// a retry, and a row that swapped identity under a `reloadData`.
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
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, rows?.contains(row) ?? true,
                let cell = rowView.view(atColumn: 0) as? TranscriptCellView,
                let view = cell.hostedView as? BlockView,
                let content = dataSource?.transcriptView(self, contentForRow: row)
            else { return }
            // The cache holds the source a row was last built from, so reading it
            // either side of the measure is what gives both versions. Asked there
            // rather than by switching over `content` again, which would be the
            // second copy of the case mapping `measuredBlock(forRow:content:)`
            // exists to prevent.
            let previous = rowCache.source(forRow: row)
            guard let block = measuredBlock(forRow: row, content: content) else { return }
            // A row nothing had measured yet has no previous source to extend, so
            // it takes the same path a replacement does.
            let extended = previous.flatMap { self.rowCache.source(forRow: row)?.hasPrefix($0) } ?? false

            if extended {
                view.remeasured(to: block)
            } else {
                view.configure(with: block)
            }
            rebound.insert(row)
        }
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
    /// These also define where "at the top" and "centred" are: a row scrolled to
    /// `.top` lands below the top inset, not underneath the chrome, and scroll
    /// anchoring measures from the same edge.
    ///
    /// Writing this re-tiles, so compare before assigning if the call site can
    /// run on every layout pass.
    /// `scrollerInsets` is deliberately left alone: it is *added* to this, so
    /// mirroring the value here inset the scroller's track by twice the chrome's
    /// height. Measured — a 140pt bottom inset left the track ending 280pt short.
    /// Style-independent, so pinning the scrollers to overlay does not retire it.
    public var contentInsets: NSEdgeInsets {
        get { scrollView.contentInsets }
        set { scrollView.contentInsets = newValue }
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
        rowCache.reloadAll()
        tableView.reloadData()
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
            // Before the table's call, not after: that call lays out, and laying
            // out asks for heights, which read the cache.
            rowCache.insert(at: indexes)
            tableView.insertRows(at: indexes, withAnimation: [])
        }
    }

    /// Announces rows newly inserted at `indexes`, taking measurements
    /// `prepareRows(_:)` already produced off the main actor.
    ///
    /// Identical to `insertRows(at:)` in every observable way — same row count
    /// afterwards, same scroll anchoring, same `rect(ofRow:)` correct on
    /// return. What differs is only what the call has to compute: `insertRows(at:)`
    /// parses and typesets each new row inside this call, because `NSTableView`
    /// sums every row's height before it can lay out and there is no estimate
    /// to give it. This one finds those answers already in hand.
    ///
    /// **The `k`-th entry in `prepared` belongs to the `k`-th smallest index in
    /// `indexes`.** That pairing is the whole of the correspondence.
    ///
    /// ## The one rule
    ///
    /// > Between mutating your model and calling this, there must be **no
    /// > `await`**.
    ///
    /// Which reads as: prepare *first*, from the values you are about to insert,
    /// then mutate and insert together.
    ///
    /// ```swift
    /// let prepared = await transcript.prepareRows(batch.map { .markdown($0.text) })
    /// // ↓ no suspension point between these two lines ↓
    /// messages.insert(contentsOf: batch, at: 0)
    /// transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
    /// ```
    ///
    /// The reason is `transcriptView(_:contentForRow:)`, which is asked on demand
    /// and answered from the host's array by index, with nothing cached in
    /// between. Mutate before the `await` and, for as long as it suspends, the
    /// table believes in the old row count while the data source answers from the
    /// new one — so any layout landing in that window (a scroll, a resize, another
    /// row's `reloadRows`) reads row *n* out of a model where *n* means something
    /// else. Prepending is where it shows; appending happens to survive it,
    /// because appending leaves every existing index meaning what it meant.
    ///
    /// Two consequences of the same rule, worth stating because they are easy to
    /// get wrong in the other direction:
    ///
    /// - **`prepareRows(_:)` takes contents, not indices**, so that the indices
    ///   can be computed after the `await` — from the model as it is at that
    ///   moment, which is the only version of it that is true.
    /// - **Nothing else about the transcript is off limits during the `await`.**
    ///   Another row may stream, a message may append and announce itself, the
    ///   window may resize. None of that invalidates anything here beyond the
    ///   batch's own width check.
    ///
    /// ## Getting it wrong
    ///
    /// A host that mutates before the `await` anyway does not corrupt anything.
    /// A frame drawn inside that window can show a row's neighbour's content, and
    /// some cached measurements are wasted; on the next read every entry is
    /// re-validated against the content it is being asked for, so the transcript
    /// converges on the correct render without being told to. The failure mode is
    /// a visible glitch and some lost work, not a wrong steady state — which is
    /// why this is documented rather than asserted.
    ///
    /// That last sentence is only true because `seed(_:at:)` compares **whole
    /// content values** rather than their text. It did not, once: a measurement
    /// prepared as `.markdown` will file cleanly onto a `.userMessage` row
    /// carrying the same string, and the entry it writes is consistent enough
    /// that nothing downstream ever re-measures it. That is a row permanently the
    /// wrong height, and it is the one way this mechanism can be got wrong
    /// quietly. See `PreparedRowsTests.testAnEntryWhoseCaseChangedIsNotSeeded`.
    public func insertRows(at indexes: IndexSet, prepared: PreparedRows) {
        mutate(shiftedBy: .inserted(indexes)) {
            // Order as in `insertRows(at:)`, with the seed between the two: the
            // cache has to have the slots before anything can be written into
            // them, and both have to happen before the table's call, which lays
            // out and therefore reads what was written.
            rowCache.insert(at: indexes)
            seed(prepared, at: indexes)
            tableView.insertRows(at: indexes, withAnimation: [])
        }
    }

    /// Writes `prepared` into the row cache, one row at a time, keeping only the
    /// entries that still describe the row they are about to be filed under.
    ///
    /// Two checks:
    ///
    /// - **The width, once for the batch.** Every entry was measured into the
    ///   same number, so one comparison settles all of them.
    /// - **The content, per row**, against the live data source — the whole
    ///   value, not its text, for the reason on `PreparedRows.Row`. The happy
    ///   path compares a case and then two `String`s sharing storage, so a batch
    ///   that is entirely valid pays a pointer comparison per row and nothing
    ///   else. That is also why `prepareRows(_:)` asks for the *same* string
    ///   values the data source will later hand back rather than copies of them.
    ///
    /// A row that fails either is left unseeded, which is not a special state:
    /// the `tableView.insertRows` below measures it, exactly as it would have if
    /// nothing had been prepared at all.
    ///
    /// **What each check is worth is not the same, and the difference is worth
    /// knowing before touching either.** Removing the *width* comparison leaves
    /// the transcript correct and merely wasteful — the entry is filed with the
    /// width it was actually measured at, so the row cache's own read-time check
    /// rejects it. Verified, by deleting it and watching the whole suite stay
    /// green. Removing the *content* comparison is a different thing: two content
    /// cases carrying the same text measure to different heights, so a mismatch
    /// that gets through is filed as a consistent entry that nothing later
    /// disagrees with. The first is an optimisation; the second is the
    /// correctness of the mechanism.
    private func seed(_ prepared: PreparedRows, at indexes: IndexSet) {
        guard prepared.width == contentWidth else { return }
        for (offset, row) in indexes.enumerated() {
            guard let prepared = prepared[offset],
                let content = dataSource?.transcriptView(self, contentForRow: row),
                content == prepared.content
            else { continue }
            rowCache.seed(prepared.entry, forRow: row)
        }
    }

    /// Announces rows removed at `indexes` (positions in the pre-mutation
    /// data source). No animation parameter, for the reason on `insertRows`.
    public func removeRows(at indexes: IndexSet) {
        mutate(shiftedBy: .removed(indexes)) {
            rowCache.remove(at: indexes)
            tableView.removeRows(at: indexes, withAnimation: [])
        }
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
    /// **Contents, not indices.** The rows do not exist yet, and the indices they
    /// will occupy are not knowable until the model is mutated — which happens
    /// *after* this returns. See `insertRows(at:prepared:)` for why that order is
    /// the one rule here, and what a host pays for getting it wrong.
    ///
    /// **Hand over the same string values the data source will later return.**
    /// Not copies: the seed compares them, and two `String`s sharing storage
    /// compare in constant time where two equal ones compare in linear time. In
    /// practice this is automatic — build the contents from the batch you are
    /// about to store — and it is the difference between a seed costing a pointer
    /// comparison per row and one costing a memcmp of the whole transcript.
    ///
    /// **`.view` rows pass through.** They occupy their place in the result and
    /// carry no measurement: a host row's height is the delegate's, and asking
    /// for it here would mean calling main-actor code from a background task.
    /// They cost nothing to include, so a host with mixed content hands over the
    /// whole batch rather than filtering and re-interleaving it.
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
    ///     let prepared = await transcript.prepareRows(batch.map { .markdown($0.text) })
    ///     if Task.isCancelled { return }
    ///
    ///     messages.insert(contentsOf: batch, at: 0)
    ///     transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
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
    /// discarded at seed time — the same ordering `reloadData()` asks for, with a
    /// gentler penalty, since what gets wasted is background work rather than the
    /// main thread's.
    ///
    /// **Cancellation stops the work, not just its result.** Cancel the enclosing
    /// `Task` — a session switch, a window closing — and the rows still queued
    /// return nothing rather than being measured for a transcript nobody is
    /// looking at. What comes back is then a partly empty batch, which is not an
    /// error state: check `Task.isCancelled` after the `await` and drop it.
    public func prepareRows(_ contents: [TranscriptRowContent]) async -> PreparedRows {
        // Read on the main actor and captured, so every row in the batch is
        // measured into one number — which is what lets the seed validate the
        // whole batch with a single comparison.
        let width = contentWidth
        return await Self.measure(contents, width: width)
    }

    /// The batch, measured concurrently.
    ///
    /// `nonisolated` is the whole point: a `static` member of a `@MainActor` type
    /// is main-actor isolated by default, and this one must not be — awaiting it
    /// from `prepareRows` is what hops off.
    ///
    /// One child task per row rather than a hand-rolled chunking loop, because
    /// the cooperative pool already caps the number actually running at the core
    /// count; the extra tasks queue, and a task is cheaper than the document it
    /// is holding. Results are gathered by offset rather than in completion
    /// order, so the batch comes back in the order it was given whatever order it
    /// finished in.
    private nonisolated static func measure(
        _ contents: [TranscriptRowContent], width: CGFloat
    ) async -> PreparedRows {
        await withTaskGroup(of: (Int, PreparedRows.Row?).self) { group in
            for (offset, content) in contents.enumerated() {
                group.addTask {
                    guard !Task.isCancelled, let entry = content.entry(width: width)
                    else { return (offset, nil) }
                    return (offset, PreparedRows.Row(content: content, entry: entry))
                }
            }
            var rows = [PreparedRows.Row?](repeating: nil, count: contents.count)
            for await (offset, row) in group { rows[offset] = row }
            return PreparedRows(rows: rows, width: width)
        }
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
        body()
        switch shift {
        case .none: break
        case .inserted(let indexes): anchor = anchor?.shifted(byRowsInserted: indexes)
        case .removed(let indexes): anchor = anchor?.shifted(byRowsRemoved: indexes)
        }
        endAnchoring()
    }

    /// Turns layer animations off for the animation grouping the caller has opened.
    ///
    /// Load-bearing for anchoring, and the reason is worth stating because no
    /// assertion can catch a regression here. In a layer-backed window — which any
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

/// `NSTableView`'s data source and delegate, forwarded to a `TranscriptView`.
///
/// Not a conformance on `TranscriptView` itself: that type is public, so the
/// conformance would be too, putting AppKit's table callbacks on the package's
/// surface next to three near-identically named row-count methods. Holds the
/// transcript weakly — the transcript owns this, the table only refers to it.
@MainActor
private final class TableViewAdapter: NSObject, NSTableViewDataSource, NSTableViewDelegate {

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

/// The transcript's scroll view, and the one thing it exists to change: its
/// scrollers are **always** overlay ones, whatever the reader's "Show scroll
/// bars" setting says.
///
/// A legacy scroller is a permanent 15-point track carved out of the *inside* of
/// the viewport. Everywhere else on the system that is the correct trade — a
/// list gives up 15 points of a column it owns outright. Here it is not, because
/// the transcript's content is **centred within a maximum width** and the
/// scroller sits at the window's edge, several hundred points away from the
/// column it would be narrowing. The result reads as the document having been
/// shunted off-centre by a control that is nowhere near it, and the wider the
/// window the more obviously wrong it looks. `maxContentWidth` and a legacy
/// scroller are the two halves that do not fit together; an overlay scroller
/// floats over the margin the centring already left, and costs the column
/// nothing.
///
/// This does override an explicit preference, so it is worth being plain about:
/// a reader who set "Always" gets an overlay scroller here regardless. The app's
/// previous renderer (`Transcript2ScrollView`) made the same call for the same
/// reason, and this is parity with it rather than a new position.
///
/// **Overriding the property, not assigning it once.** AppKit re-writes
/// `scrollerStyle` from `NSPreferredScrollerStyleDidChangeNotification`, so a
/// one-shot assignment in the initialiser silently reverts the first time the
/// reader toggles the setting — or plugs in a mouse, which flips the
/// "Automatically based on mouse or trackpad" default to legacy. Intercepting
/// the setter is what makes the pin hold.
///
/// `autohidesScrollers` used to be set here and is deliberately gone: it governs
/// whether a **legacy** scroller is hidden when the content fits, and with the
/// style pinned there is no legacy case left for it to serve. Put it back if the
/// pin ever comes off.
private final class OverlayScrollView: NSScrollView {

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

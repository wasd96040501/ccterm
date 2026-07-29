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

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        0
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
        -1
    }

    // MARK: - Geometry

    /// The rectangle the given row occupies, in the transcript's coordinate
    /// space; `NSZeroRect` for an out-of-range row or one the first layout
    /// pass hasn't placed yet. Mirrors `NSTableView.rect(ofRow:)`.
    ///
    /// Spans the full row width, insets included; the content inside is
    /// narrower by those insets. There is no `frameOfCell(atColumn:row:)`
    /// counterpart, because that method's whole job is picking one column out
    /// of a row and a transcript has no columns.
    public func rect(ofRow row: Int) -> NSRect {
        .zero
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
        make()
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
    }

    /// Tells the view the row count changed at the tail without describing
    /// the exact edit. Mirrors `NSTableView.noteNumberOfRowsChanged()`;
    /// prefer the index-based mutations.
    public func noteNumberOfRowsChanged() {
    }

    /// Announces rows newly inserted at `indexes` (positions in the
    /// post-mutation data source).
    public func insertRows(at indexes: IndexSet, withAnimation animation: AnimationOptions = []) {
    }

    /// Announces rows removed at `indexes` (positions in the pre-mutation
    /// data source).
    public func removeRows(at indexes: IndexSet, withAnimation animation: AnimationOptions = []) {
    }

    /// Announces in-place content changes: the rows at `indexes` are
    /// re-queried from the data source and re-rendered, keeping row identity.
    /// Heights are re-resolved too — a self-sizing row is re-measured, a
    /// `.view` row is re-asked through the delegate's `heightOfRow`.
    public func reloadRows(at indexes: IndexSet) {
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
    }

    /// Ends a `beginUpdates()` group, applies the coalesced mutations, and
    /// restores the scroll anchor sampled at `beginUpdates()`.
    public func endUpdates() {
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

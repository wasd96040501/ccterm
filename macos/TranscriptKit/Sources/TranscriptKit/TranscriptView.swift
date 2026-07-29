import AppKit

/// A vertically scrolling chat transcript driven by a data source, in the
/// style of `NSTableView`.
///
/// This is the package's only view. The data source answers row count and
/// content (`TranscriptRowContent`); the host announces every data mutation
/// through `insertRows` / `removeRows` / `reloadRows` (or `reloadData`);
/// row heights are specialized per content case — self-sizing for
/// `markdown` / `userMessage` / `image`, host-measured for `view`, with
/// `noteHeightOfRows(withIndexesChanged:)` as the invalidation channel.
/// The internal scroll and row machinery is an implementation detail and is
/// never exposed.
///
/// Rows drawn by host views recycle: the transcript keeps roughly a
/// screenful of instances alive and cycles them across rows as the user
/// scrolls, so transcript length costs rows, not views. The host takes part
/// through `makeView(withIdentifier:make:)` inside its delegate's
/// `viewForRow`, and — if a view starts anything that must be stopped —
/// `TranscriptViewDelegate.transcriptView(_:didRemove:forRow:)`.
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

    // MARK: - Collaborators

    /// The single source of truth for row count and content. Held weakly and
    /// re-queried on demand; setting it does not refresh the view — call
    /// `reloadData()` after wiring.
    public weak var dataSource: TranscriptViewDataSource?

    /// Observer for display-side events.
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
    /// `.view` row is re-asked through `heightOfViewRow`.
    public func reloadRows(at indexes: IndexSet) {
    }

    /// Invalidates the cached heights of the rows at `indexes` without
    /// re-rendering them: self-sizing rows are re-measured, and `.view` rows
    /// are re-asked through the delegate's `heightOfRow`, on the next layout pass.
    /// Mirrors `NSTableView.noteHeightOfRows(withIndexesChanged:)`.
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
    public func beginUpdates() {
    }

    /// Ends a `beginUpdates()` group and applies the coalesced mutations.
    public func endUpdates() {
    }

    // MARK: - Scrolling

    /// Scrolls the minimum amount needed to bring the given row into view.
    /// Mirrors `NSTableView.scrollRowToVisible(_:)`.
    public func scrollRowToVisible(_ row: Int) {
    }

    /// Scrolls to the newest content.
    ///
    /// Tail following is built-in and not configurable: while the view sits
    /// at the bottom, appended rows and growing content automatically keep
    /// the newest content visible; the user scrolling away suspends it until
    /// they scroll back to the bottom or this method is called.
    public func scrollToTail(animated: Bool = false) {
    }
}

import AppKit

/// A vertically scrolling chat transcript driven by a data source, in the
/// style of `NSTableView`.
///
/// This is the package's only view. The data source answers row count and
/// content (`TranscriptRowContent`); the host announces every data mutation
/// through `insertRows` / `removeRows` / `reloadRows` (or `reloadData`);
/// row heights are specialized per content case — self-sizing for
/// `markdown` / `userMessage` / `image`, caller-fixed for `view`, with
/// `noteHeightOfRows(withIndexesChanged:)` as the invalidation channel.
/// The internal scroll and row machinery is an implementation detail and is
/// never exposed.
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
    public func reloadRows(at indexes: IndexSet) {
    }

    /// Invalidates the measured heights of the rows at `indexes`: their
    /// content is re-queried and re-measured on the next layout pass — for a
    /// `.view` row, the fresh caller-supplied height takes effect. Mirrors
    /// `NSTableView.noteHeightOfRows(withIndexesChanged:)`.
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

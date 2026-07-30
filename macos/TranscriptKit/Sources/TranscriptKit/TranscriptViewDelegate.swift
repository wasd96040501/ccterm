import AppKit

/// Answers how a `TranscriptView`'s rows look, and observes its display-side
/// events. Mirrors `NSTableViewDelegate`'s half of the split: the data source
/// says *what* the rows are, the delegate says *how they appear*.
///
/// The two observation requirements default to no-ops — implement only what
/// the host cares about. The two `.view` row requirements, `heightOfRow` and
/// `viewForRow`, have defaults that trap instead: a host whose data source
/// returns `.view` has to implement them, and a host that never returns
/// `.view` never reaches them. So a transcript containing `.view` rows needs
/// a delegate, the same way a view-based `NSTableView` does.
@MainActor
public protocol TranscriptViewDelegate: AnyObject {

    /// The height of a `.view` row, laid out against `width`.
    ///
    /// Asked of every `.view` row in the transcript, on screen or not — the
    /// scroller cannot be sized without summing all of them. Answer from the
    /// same model `viewForRow` will read, **without building the view**;
    /// building one here would defeat recycling outright.
    ///
    /// `width` is the transcript's content width: the span the row's view will
    /// actually be given, after the transcript's own insets and scroller
    /// allowance. It is *not* `transcriptView.bounds.width`, and reading
    /// bounds instead is wrong twice over — the arithmetic differs, and during
    /// an Auto Layout pass bounds is still converging, so one tick can hand
    /// back two or three different values. The width passed here is the one
    /// the transcript has committed to. (`NSTableView`'s
    /// `tableView(_:heightOfRow:)` needs no such parameter because column
    /// widths were the host's to set in the first place.)
    ///
    /// When the content width changes, the transcript re-asks on its own. When
    /// the *model* changes such that a height has gone stale, invalidate it
    /// with `TranscriptView.noteHeightOfRows(withIndexesChanged:)`.
    ///
    /// ## How to compute it
    ///
    /// Give the row's view type a `static func height(for:width:)` that adds up
    /// constants — paddings, gaps, fixed sub-component heights — and measures
    /// the variable text with a shared typesetter. Lay the view out from **the
    /// same constants**:
    ///
    /// ```swift
    /// final class ToolCardView: NSView {
    ///     private static let padding: CGFloat = 12
    ///     private static let titleHeight: CGFloat = 20
    ///
    ///     static func height(for model: ToolCall, width: CGFloat) -> CGFloat {
    ///         let bodyWidth = width - padding * 2
    ///         return padding + titleHeight + Typesetter.height(model.body, bodyWidth) + padding
    ///     }
    /// }
    /// ```
    ///
    /// One set of constants, two uses. Two sets computing the same number is
    /// the failure this shape avoids: they diverge, and the symptom is a
    /// silently clipped row rather than a complaint — a subview's vertical
    /// compression resistance is high by default, not required, so it gets
    /// squeezed instead of making the layout unsatisfiable.
    ///
    /// **Do not measure by building a template view and reading its
    /// `fittingSize`.** It is consistent by construction, and it costs a full
    /// constraint solve per row — against a method called for every row in the
    /// transcript, re-run on every content-width change, and re-run per frame
    /// while a window is being dragged. Arithmetic is tens of nanoseconds; a
    /// complex card's solve is hundreds of microseconds. If a card's structure
    /// genuinely defies a formula, a template view is the fallback — cache its
    /// answer per (row identity, width), and know that the cache is now load-
    /// bearing rather than an optimisation.
    ///
    /// **When the height is not knowable yet** — an image still decoding,
    /// content still arriving — answer a provisional height and correct it
    /// later: the view calls `TranscriptView.row(for:)` for the index it
    /// currently sits at, then `noteHeightOfRows(withIndexesChanged:)`.
    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat

    /// The view for a `.view` row that is about to appear. Mirrors
    /// `NSTableViewDelegate.tableView(_:viewFor:row:)`, minus the column.
    ///
    /// Called only for rows entering the viewport, so this is where work
    /// proportional to what is on screen belongs. Recycle through
    /// `TranscriptView.makeView(withIdentifier:make:)` rather than
    /// constructing unconditionally:
    ///
    /// ```swift
    /// func transcriptView(_ tv: TranscriptView, viewForRow row: Int) -> NSView {
    ///     let cell = tv.makeView(withIdentifier: .toolGroup) { ToolGroupCellView() }
    ///     cell.configure(with: groups[row])
    ///     return cell
    /// }
    /// ```
    ///
    /// A recycled instance may have been serving a different row moments ago,
    /// so the binding must be **idempotent**: write every field the view
    /// displays, and leave nothing behind from the previous occupant. The
    /// transcript sizes the returned view to the row's `width × height`
    /// itself — do not set its frame.
    ///
    /// The row's height does not depend on the instance returned here; it was
    /// fixed by `heightOfRow` before this call. A view that later needs a
    /// different height says so through `noteHeightOfRows(withIndexesChanged:)`,
    /// using `TranscriptView.row(for:)` to find the index it currently sits at.
    func transcriptView(
        _ transcriptView: TranscriptView, viewForRow row: Int
    ) -> NSView

    /// A `.view` row left the viewport; its view is going back into the
    /// recycling pool. Mirrors
    /// `NSTableViewDelegate.tableView(_:didRemove:forRow:)`.
    ///
    /// The instance will be handed to some other row by a later `viewForRow`
    /// call, so whatever it started on behalf of *this* row has to stop here:
    /// `CAAnimation`s, `Timer`s, Combine subscriptions, in-flight `Task`s.
    /// Clearing its content is not the point — the next `viewForRow`
    /// overwrites that anyway; the point is stopping work that would otherwise
    /// keep running against a row nobody is looking at.
    ///
    /// There is no `didAdd` counterpart the way `NSTableView` has one: it
    /// needs that hook because it builds row views itself, whereas here
    /// `viewForRow` already *is* that moment.
    func transcriptView(
        _ transcriptView: TranscriptView, didRemove view: NSView, forRow row: Int)

    /// A link inside a rendered row was activated.
    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int)
}

extension TranscriptViewDelegate {

    /// Unreachable unless the data source returns `.view`, in which case it is
    /// a wiring error rather than a recoverable state.
    public func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        preconditionFailure(
            "Row \(row) reported content `.view`, but the delegate does not implement "
                + "transcriptView(_:heightOfRow:width:)")
    }

    /// Unreachable unless the data source returns `.view`, in which case it is
    /// a wiring error rather than a recoverable state.
    public func transcriptView(
        _ transcriptView: TranscriptView, viewForRow row: Int
    ) -> NSView {
        preconditionFailure(
            "Row \(row) reported content `.view`, but the delegate does not implement "
                + "transcriptView(_:viewForRow:)")
    }

    public func transcriptView(
        _ transcriptView: TranscriptView, didRemove view: NSView, forRow row: Int
    ) {}

    public func transcriptView(
        _ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int
    ) {}
}

import AppKit
import ExactList

/// The reader's text selection, and every gesture that makes it.
///
/// Owns the selection's state and every gesture that changes it — the press
/// tracked to its release, the context menu's word, Copy — and hands each row
/// view on screen its part. The transcript tells it what its mutations did to
/// the rows (`shift(byRowsInserted:)`, `keepSelection(_:)`,
/// `dropSelection(endingIn:)`), and reads its part back when it binds a view.
///
/// A selection runs from a position in one row to a position in another, so it
/// is held here, where rows have identities and outlive their views, rather
/// than on the views — which is `NSTableView`'s split, the table holding the
/// selection and handing each row view its `isSelected`. A press on a
/// `BlockView` goes up the responder chain — through the list, which takes
/// focus for it — to the transcript, like any mouse event a view does not
/// take, and the view draws what it is handed (`selectedRange`); nothing about
/// it is on the public surface.
///
/// The responder is the list's document view, the way it is an `NSTextView`
/// and not its scroll view: it takes first responder on a press, Copy comes up
/// the chain from it, and the selection goes when the focus moves on — how a
/// selection in one transcript goes away when the reader starts one in
/// another.
///
/// What it costs where the transcript is hot: nothing, until something is
/// selected. A row bound (`viewForRow`, `rebindVisibleRows`) reads its part —
/// arithmetic on four integers — and an insert renumbers two. Only a press or a
/// drag walks anything, and only when the focus moved: it walks the row views
/// on screen, repainting those whose part changed.
@MainActor
final class SelectionTracker {

    /// The reader's selection, or a caret after a click, or `nil`.
    private(set) var selection: TextSelection?

    private weak var dataSource: RowDataSource?
    private let rowCache: RowCache
    private let list: ExactListView

    init(dataSource: RowDataSource, rowCache: RowCache, list: ExactListView) {
        self.dataSource = dataSource
        self.rowCache = rowCache
        self.list = list
    }

    /// Row `row`'s part of the selection, for a view being bound to it.
    func range(inRow row: Int, length: Int) -> Range<Int>? {
        selection?.range(inRow: row, length: length)
    }

    /// The rows the selection's two ends are in, by identity — what a removal or
    /// a reload has to find again.
    var endIDs: [TranscriptRow.ID] {
        selection.map { [$0.anchor.id, $0.focus.id] } ?? []
    }

    /// Renumbers the selection for rows inserted at `indexes` (post-insertion
    /// positions). Before the list commits the insert: a new row's view reads
    /// its part against these indices.
    func shift(byRowsInserted indexes: IndexSet) {
        selection = selection?.shifted(byRowsInserted: indexes)
    }

    /// Drops the selection, without showing it, when an end of it is in a row
    /// whose content was replaced rather than extended — its index names text
    /// that is not there any more. The caller rebinds the rows on screen and then
    /// pushes.
    func dropSelection(endingIn id: TranscriptRow.ID) {
        if selection?.ends(in: id) == true { selection = nil }
    }

    /// A press, and everything until the button comes back up. The one way into a
    /// selection made with the mouse, reached from a row or from between rows
    /// through the responder chain, once the list has taken focus for it.
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
    func trackSelection(from event: NSEvent) {
        beginSelection(with: event)
        guard let window = list.window, selection != nil else { return }

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
            // A mounted row reaches the list's clip view, which does the
            // scrolling for both — AppKit's own mechanism, from any row.
            case .periodic: guard mountedRow?.autoscroll(with: pointer) == true else { return }
            case .scrollWheel: mountedRow?.scrollWheel(with: event)
            default:
                stop.pointee = true
                return
            }
            extendSelection(to: pointer)
        }
    }

    /// Any row view on screen: from inside the clip view, it passes an autoscroll
    /// or a wheel event up to the scroll view. The cell rather than what it
    /// hosts, which may answer either itself.
    private var mountedRow: NSView? {
        var first: NSView?
        list.enumerateAvailableRowViews { view, _ in first = first ?? view }
        return first
    }

    /// How soon a pointer held past an edge starts scrolling, and how often it
    /// scrolls again: a frame, so the rows arriving move as a scroll does.
    private static let autoscrollDelay: TimeInterval = 0.1
    private static let autoscrollPeriod: TimeInterval = 1.0 / 60

    /// Moves the selection's focus to what is under `pointer` now.
    private func extendSelection(to pointer: NSEvent) {
        guard var selection, let hit = selectionHit(at: pointer) else { return }
        selection.focus = .init(
            row: hit.row, id: hit.id, index: hit.block?.characterIndexForInsertion(at: hit.point) ?? 0)
        guard selection != self.selection else { return }
        select(selection)
    }

    /// Starts a selection at a press: a caret, or — for a double- or triple-click
    /// — the word or paragraph under it. Which unit that is, is the block's to
    /// answer, and the **point** goes over for the two that take one: an index at
    /// a line boundary names two places, and only the point can tell them apart.
    private func beginSelection(with event: NSEvent) {
        guard let hit = selectionHit(at: event) else { return select(nil) }
        let range: Range<Int>
        switch (hit.block, event.clickCount) {
        case (let block?, 2): range = block.wordRange(at: hit.point)
        case (let block?, 3...): range = block.paragraphRange(at: hit.point)
        case (let block?, _):
            let index = block.characterIndexForInsertion(at: hit.point)
            range = index..<index
        case (nil, _): range = 0..<0
        }
        select(TextSelection(row: hit.row, id: hit.id, range: range))
    }

    /// What a right-click acts on, settled before its menu is shown.
    ///
    /// Two things, and both are why this is not a pure getter. **The focus** moves
    /// to the selection's responder — the list's document view, which `view`, a
    /// row on screen, reaches as its scroll view's — because a menu item with a `nil` target
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
    func selectForContextMenu(with event: NSEvent, in view: NSView) {
        if let responder = view.enclosingScrollView?.documentView { list.window?.makeFirstResponder(responder) }
        guard let hit = selectionHit(at: event), let block = hit.block else { return }
        if selection?.contains(row: hit.row, index: block.characterIndexForInsertion(at: hit.point)) == true { return }
        select(TextSelection(row: hit.row, id: hit.id, range: block.wordRange(at: hit.point)))
    }

    /// The row under `event` and the point in its block's own coordinates.
    ///
    /// Clamped rather than failing: above the rows is the start of the first and
    /// below them the end of the last — `NSTextView`'s answer past its first and
    /// last lines — so a drag that leaves the rows selects to the end, and the
    /// block clamps a point beside its text the same way.
    /// A point in the gap between two rows is the end of the row above it.
    ///
    /// Worked out from the list's geometry, not from a view, so a row with no
    /// view on screen answers as well as one with — and a drag keeps working when
    /// the view it started on has been recycled. `block` is `nil` for a `.view`
    /// row, whose content has no positions: the selection passes through it.
    private func selectionHit(
        at event: NSEvent
    ) -> (row: Int, id: TranscriptRow.ID, block: MeasuredBlock?, point: CGPoint)? {
        guard let dataSource, dataSource.numberOfRows > 0 else { return nil }
        let point = list.convert(event.locationInWindow, from: nil)
        let hit = list.row(at: NSPoint(x: list.bounds.midX, y: point.y))
        let top = list.rect(ofRow: 0).minY
        let above = hit < 0 && point.y < top
        // Below the last row, or in a gap between two: the nearest row above.
        let clamped =
            hit >= 0
            ? hit
            : above
                ? 0
                : min(
                    dataSource.numberOfRows - 1,
                    max(0, list.rows(in: NSRect(x: 0, y: top, width: 1, height: point.y - top)).upperBound - 1))

        guard let described = dataSource.row(at: clamped) else { return nil }
        let contentWidth = dataSource.contentWidth
        // The block is drawn from the row's top edge, centred at the content
        // width — `TranscriptCellView`'s arrangement.
        let cell = list.rect(ofRow: clamped)
        let local =
            hit >= 0
            ? CGPoint(x: point.x - (cell.midX - contentWidth / 2), y: point.y - cell.minY)
            : above ? .zero : CGPoint(x: contentWidth, y: cell.height)
        return (
            clamped, described.id,
            described.content == .view ? nil : dataSource.measuredBlock(for: described), local
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
    func pushSelection() {
        list.enumerateAvailableRowViews { cell, row in
            guard let view = (cell as? TranscriptCellView)?.hostedView as? BlockView,
                let block = view.block
            else { return }
            view.selectedRange = selection?.range(inRow: row, length: block.length)
        }
    }

    /// Finds the selection's rows again after a removal or a reload, or drops it
    /// when a row one of its ends was in has gone.
    ///
    /// Runs inside the mutation, before the list has been told — so it shows
    /// nothing unless the selection went. A selection that survived is still
    /// correct in every view on screen: what each shows is its part of the same
    /// text, whatever number its row now has.
    func keepSelection(_ rows: [TranscriptRow.ID: Int]) {
        guard let selection else { return }
        self.selection = selection.relocated(to: rows)
        if self.selection == nil { pushSelection() }
    }

    /// The list's document view stopped being first responder.
    func selectionDidResign() {
        guard selection != nil else { return }
        select(nil)
    }

    /// Whether Copy has anything to copy.
    var canCopySelection: Bool {
        selection.map { !$0.isEmpty } ?? false
    }

    /// Copies the selection as plain text, a blank line between rows.
    ///
    /// A row the selection covers that nothing has measured — it can run through
    /// rows the reader dragged past without the list ever showing — is
    /// built for this and dropped, not filed: the same rule as a find's walk, for
    /// the same reason: filing it would push the rows on screen out of `RowCache`'s
    /// resident budget to make room for rows nobody is looking at. That includes a
    /// row whose tree the budget already evicted, which reads as unmeasured here and
    /// is rebuilt the same way. The flat index space depends on
    /// the content and not the width, so a tree measured at any width answers.
    /// `.view` rows contribute nothing; their content is the host's.
    func copySelection() {
        guard let selection, !selection.isEmpty, let dataSource else { return }
        var parts: [String] = []
        for row in selection.rows where row < dataSource.numberOfRows {
            guard let described = dataSource.row(at: row),
                let block = rowCache.cachedMeasured(for: described, width: nil)
                    ?? RowCache.Entry(measuring: described.content, width: dataSource.contentWidth, reusing: nil)?
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
}

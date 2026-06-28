import AppKit
import XCTest

@testable import ccterm

/// Synthesizes **real** user interactions on a mounted `AppKitStage`:
/// constructs `NSEvent`s and routes them through the production
/// `hitTest` / `mouseDown` path, or drives the real selection-write-back
/// the sidebar uses. Nothing here calls an internal method to shortcut
/// the gesture — the point is to exercise the same code an actual click /
/// drag / row-select would.
///
/// ## The drag-select pre-post trick
///
/// `Transcript2TableView.mouseDown` (single-click) enters a private
/// `NSApp.nextEvent(inMode: .eventTracking)` loop that pulls
/// `.leftMouseDragged` / `.leftMouseUp` straight off the queue. Offscreen
/// there is no hardware stream to feed it, so `dragSelect` **pre-posts**
/// the dragged + up events before delivering the down — the tracking loop
/// drains them synchronously and the `.leftMouseUp` guarantees it
/// terminates. This is the same technique `DetailPaneTranscriptHitTestTests`
/// established; it approximates the loop but cannot reproduce live
/// key-window event delivery (hover, selection-highlight key tinting).
@MainActor
struct InteractionDriver {
    let stage: AppKitStage

    init(_ stage: AppKitStage) { self.stage = stage }

    // MARK: - Sidebar

    /// Select sidebar row `row` the way a click does: drive the real
    /// `NSOutlineView`'s selection, which fires
    /// `outlineViewSelectionDidChange` → `context.model.select(...)`.
    /// Returns false if no sidebar / row is out of range. Folder rows are
    /// non-selectable (the outline filters them), so this targets history
    /// / fixed rows.
    @discardableResult
    func selectSidebarRow(_ row: Int) -> Bool {
        guard let outline = stage.find(NSOutlineView.self) else { return false }
        guard row >= 0, row < outline.numberOfRows else { return false }
        // selectRowIndexes posts the same NSOutlineViewSelectionDidChange
        // notification a click would; the VC's delegate writes it back to
        // the model. byExtendingSelection:false mirrors single-select.
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return true
    }

    // MARK: - Transcript selection

    /// Result of a synthesized drag-select on the visible transcript.
    struct SelectionOutcome {
        /// The selection dictionary became non-empty.
        let selectionPopulated: Bool
        /// The visible cell at the dragged row actually received the
        /// selection (would repaint the highlight) — the dimension that
        /// matters for the "selected but no highlight" class of bug.
        let cellHighlighted: Bool
        let diagnostic: String
    }

    /// Drag-select across the middle of a visible transcript row and
    /// report whether text ended up selected. Routes a `.leftMouseDown`
    /// through `stage.rootView.hitTest`, having pre-posted the drag + up
    /// (see the type doc). Returns nil if no transcript is mounted / has
    /// no visible rows.
    func dragSelectVisibleRow(in tableView: NSTableView) -> SelectionOutcome? {
        guard let window = stage.window as NSWindow? else { return nil }
        let coordinator = (tableView as? Transcript2TableView)?.coordinator
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else {
            return SelectionOutcome(
                selectionPopulated: false, cellHighlighted: false,
                diagnostic: "no visible rows (visibleRect=\(tableView.visibleRect), "
                    + "numberOfRows=\(tableView.numberOfRows))")
        }
        let row = visible.location + visible.length / 2
        let rowRect = tableView.rect(ofRow: row)
        let yMid = rowRect.midY
        let startInTable = CGPoint(x: rowRect.minX + 120, y: yMid)
        let endInTable = CGPoint(x: max(rowRect.minX + 200, rowRect.maxX - 120), y: yMid)
        let startWin = tableView.convert(startInTable, to: nil)
        let endWin = tableView.convert(endInTable, to: nil)

        func mk(_ type: NSEvent.EventType, _ loc: NSPoint, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: loc, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks,
                pressure: type == .leftMouseUp ? 0.0 : 1.0)
        }
        guard let down = mk(.leftMouseDown, startWin, clicks: 1),
            let dragged = mk(.leftMouseDragged, endWin, clicks: 1),
            let up = mk(.leftMouseUp, endWin, clicks: 1)
        else {
            return SelectionOutcome(
                selectionPopulated: false, cellHighlighted: false,
                diagnostic: "could not synthesise mouse events")
        }

        // Pre-post the drag + up so the eventTracking loop drains them
        // and exits on the up.
        NSApp.postEvent(dragged, atStart: false)
        NSApp.postEvent(up, atStart: false)

        let hit = stage.rootView.hitTest(startWin)
        hit?.mouseDown(with: down)

        let populated = !(coordinator?.selection.isEmpty ?? true)
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockCellView
        let cellHighlighted = cell?.selection != nil

        let diag = """
            row=\(row) visible=\(visible.length) \
            hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") \
            selectionPopulated=\(populated) cellHighlighted=\(cellHighlighted)
            """
        return SelectionOutcome(
            selectionPopulated: populated, cellHighlighted: cellHighlighted, diagnostic: diag)
    }

    // MARK: - Generic hit-testing

    /// Resolve what `stage.rootView.hitTest` lands on at a point given in
    /// `view`'s coordinate space. The real routing a click takes before it
    /// reaches a responder — use it to assert a point lands on (or passes
    /// through to) the expected view.
    func hitTest(at pointInView: CGPoint, from view: NSView) -> NSView? {
        let windowPoint = view.convert(pointInView, to: nil)
        return stage.rootView.hitTest(windowPoint)
    }

    /// Walk up from `view` to the first enclosing ancestor of type `T`, or
    /// nil. Handy for "did this hit resolve inside the permission card host
    /// / a `BlockCellView`."
    func enclosing<T: NSView>(_ type: T.Type, of view: NSView?) -> T? {
        var node = view
        while let cur = node {
            if let match = cur as? T { return match }
            node = cur.superview
        }
        return nil
    }
}

extension AppKitStage {
    /// An `InteractionDriver` bound to this stage.
    var driver: InteractionDriver { InteractionDriver(self) }
}

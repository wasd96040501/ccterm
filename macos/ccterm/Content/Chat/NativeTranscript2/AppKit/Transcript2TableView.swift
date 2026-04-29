import AppKit

/// NSTableView subclass with three responsibilities:
///
/// 1. **Negative-width clamp.** AppKit briefly calls `setFrameSize` with
///    negative widths during scroller layout (e.g. `0 - 17` when the
///    vertical scroller appears before the clip width is finalized).
///    Clamping to ≥ 0 silences the "Invalid view geometry" warning.
/// 2. **Live-resize hook.** During live resize the coordinator only
///    invalidates visible rows' heights (lazy lookup recomputes them at
///    the new width on demand). Once resize ends, we kick off a background
///    prefetch to fill the layout cache for off-screen rows at the final
///    width, with scroll-anchor compensation when stale heights get
///    corrected.
/// 3. **Text-selection tracking.** `mouseDown` enters a private event
///    loop (`NSApp.nextEvent(matching:)`) that consumes
///    `leftMouseDragged`/`leftMouseUp` directly. Each drag tick updates
///    `Transcript2SelectionCoordinator` and asks the clip view to
///    autoscroll if the cursor has left the viewport. The cell forwards
///    its mouseDown here for non-link clicks, so cell hit-tests don't
///    suppress selection.
///
/// ### Edit menu
///
/// `copy(_:)` / `selectAll(_:)` route through the responder chain when
/// the table is first responder (we make ourselves first responder at
/// the start of every selection gesture). `validateMenuItem` enables
/// Copy when there's a selection, SelectAll when there's any
/// text-bearing block.
final class Transcript2TableView: NSTableView, NSMenuItemValidation {
    weak var coordinator: Transcript2Coordinator?
    private var liveResizeStartWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let safe = NSSize(
            width: max(0, newSize.width),
            height: max(0, newSize.height))
        super.setFrameSize(safe)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeStartWidth = frame.width
        coordinator?.pushScrollerHidden()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Order matters: kick off refillLayoutCache first (it pushes its
        // own scroller-hidden token) before popping ours. Otherwise count
        // would briefly hit zero between the two and the scroller would
        // flicker visible.
        if abs(liveResizeStartWidth - frame.width) > 0.5 {
            coordinator?.refillLayoutCache()
        }
        coordinator?.popScrollerHidden()
    }

    // MARK: - Selection: mouse tracking

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { super.mouseDown(with: event); return }

        let docPoint = convert(event.locationInWindow, from: nil)
        let row = self.row(at: docPoint)

        // Outside any row, or on a non-text row (image): drop existing
        // selection and don't enter tracking. `super.mouseDown` is
        // intentionally not called — the default NSTableView click logic
        // (row selection) is unwanted here (`selectionHighlightStyle`
        // is `.none`) and would consume drag events.
        guard row >= 0,
              coordinator.textLayout(atRow: row) != nil
        else {
            coordinator.selection.clearAll()
            return
        }

        // Take first responder before anything else so the impending
        // Cmd+C / Cmd+A from this gesture lands on us.
        window?.makeFirstResponder(self)

        // A new gesture starts from a clean slate.
        coordinator.selection.clearAll()

        // Click-count branching matches `NSTextView`:
        //   3+ → whole block, no drag tracking.
        //   2  → word at click point, then drag extends by word.
        //   1  → drag-select character-precise (no initial selection).
        switch event.clickCount {
        case let n where n >= 3:
            coordinator.selection.selectFullBlock(at: docPoint, in: self)
            // No tracking — triple-click is one-shot. Subsequent drag
            // would feel arbitrary on top of a "select all" gesture.
        case 2:
            coordinator.selection.selectWord(at: docPoint, in: self)
            trackSelection(startDocPoint: docPoint, byWord: true,
                           coordinator: coordinator)
        default:
            trackSelection(startDocPoint: docPoint, byWord: false,
                           coordinator: coordinator)
        }
    }

    /// Pull events directly from the queue. AppKit's normal delivery is
    /// bypassed — `mouseDragged` / `mouseUp` won't fire on any view
    /// while we're inside this loop. Same pattern NSTableView uses
    /// internally for its own drag tracking.
    ///
    /// `byWord` propagates into `updateSelection` so a double-click
    /// drag snaps to word boundaries on every tick. Single-click
    /// drag is character-precise.
    private func trackSelection(startDocPoint start: CGPoint,
                                byWord: Bool,
                                coordinator: Transcript2Coordinator) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while true {
            guard let event = NSApp.nextEvent(
                matching: mask,
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true)
            else { break }

            if event.type == .leftMouseUp { break }

            let drag = convert(event.locationInWindow, from: nil)
            coordinator.selection.updateSelection(
                from: start, to: drag, in: self, byWord: byWord)
            // Autoscroll when the cursor leaves the viewport — the next
            // tick's `convert(event.locationInWindow, from: nil)` will
            // see the new doc-coord position automatically.
            enclosingScrollView?.contentView.autoscroll(with: event)
        }
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        guard let coordinator else { return }
        let text = coordinator.selection.copyText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        coordinator?.selection.selectAllText()
        // Cmd+A implies the table wants edit-menu focus from now on so
        // a follow-up Cmd+C lands here even if the selection wasn't
        // started by a drag.
        window?.makeFirstResponder(self)
    }

    /// `NSMenuItemValidation` conformance — `NSResponder` doesn't surface
    /// this in Swift's public API, so it can't be `override`. The
    /// responder chain only routes a menu item here when this view
    /// responds to its action; for actions we don't explicitly
    /// constrain, fall back to `NSObject.responds(to:)` so unhandled
    /// actions don't get silently enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return coordinator?.selection.isEmpty == false
        case #selector(selectAll(_:)):
            return coordinator?.selection.hasSelectableText ?? false
        default:
            return responds(to: menuItem.action)
        }
    }
}

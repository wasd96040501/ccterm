import AppKit

/// Minimal `NSOutlineView` subclass with two responsibilities:
///
/// 1. **Native disclosure placement.** The triangle stays fully native
///    (AppKit's own button, drawing and rotation animation);
///    `frameOfOutlineCell(atRow:)` — Apple's documented override point —
///    moves it out of the window-left gutter into the centered content
///    column, aligned with the row's content x and vertically centered
///    on the fixed header title band.
/// 2. **Text-selection tracking.** Ported from the old renderer's
///    `Transcript2TableView`: `mouseDown` enters a private event loop
///    (`NSApp.nextEvent(matching:)`) that consumes `leftMouseDragged` /
///    `leftMouseUp` — plus `scrollWheel`, forwarded to the scroll view
///    so the wheel keeps working mid-drag. Each drag tick updates
///    `TranscriptSelectionCoordinator` and autoscrolls when the cursor
///    leaves the viewport. Cells forward their non-link clicks here, so
///    cell hit-tests don't suppress selection.
///
/// ### Edit menu
///
/// `copy(_:)` / `selectAll(_:)` route through the responder chain when
/// the outline is first responder (we take first responder at the start
/// of every selection gesture). `validateMenuItem` enables Copy when
/// there's a selection, Select All when any visible row is selectable.
final class TranscriptOutlineView: NSOutlineView, NSMenuItemValidation {
    /// Selection state + algorithm; owned by the transcript VC.
    weak var selection: TranscriptSelectionCoordinator?

    // MARK: - Native disclosure placement

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        // Non-expandable rows report .zero — nothing to place.
        guard frame != .zero else { return frame }
        let level = max(0, self.level(forRow: row))
        frame.origin.x = TranscriptOutlineMetrics.contentX(
            forRowWidth: bounds.width, level: level, hasChevronSlot: false)
        // Center the button on the header title band rather than the
        // whole row (rows carry asymmetric L1/L2 padding).
        let padTop =
            level == 0
            ? TranscriptOutlineMetrics.groupHeaderPadding.top
            : TranscriptOutlineMetrics.toolHeaderPadding.top
        frame.origin.y += padTop
        frame.size.height = BlockStyle.toolHeaderHeight
        return frame
    }

    // MARK: - Selection: mouse tracking

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let selection else {
            super.mouseDown(with: event)
            return
        }

        let docPoint = convert(event.locationInWindow, from: nil)
        let row = self.row(at: docPoint)

        // Outside any row, or on a non-selectable row (header / image):
        // drop the selection, then let AppKit's default click handling
        // run (native double-click expand on header rows stays alive;
        // `selectionHighlightStyle` is `.none`, so no visual selection).
        guard row >= 0, selection.adapter(atRow: row) != nil else {
            selection.clearAll()
            super.mouseDown(with: event)
            return
        }

        // Take first responder before anything else so the impending
        // Cmd+C / Cmd+A from this gesture lands on us.
        window?.makeFirstResponder(self)

        // A new gesture starts from a clean slate.
        selection.clearAll()

        // Click-count branching matches `NSTextView`:
        //   3+ → whole unit, no drag tracking.
        //   2  → word at click point, then drag extends by word.
        //   1  → drag-select character-precise (no initial selection).
        switch event.clickCount {
        case let n where n >= 3:
            selection.selectUnit(at: docPoint)
        // No tracking — triple-click is one-shot.
        case 2:
            selection.selectWord(at: docPoint)
            trackSelection(startDocPoint: docPoint, byWord: true, selection: selection)
        default:
            trackSelection(startDocPoint: docPoint, byWord: false, selection: selection)
        }
    }

    /// Pull events directly from the queue. AppKit's normal delivery is
    /// bypassed — `mouseDragged` / `mouseUp` won't fire on any view
    /// while we're inside this loop. Same pattern NSTableView uses
    /// internally for its own drag tracking.
    ///
    /// `.scrollWheel` is included in the mask on purpose: a private
    /// tracking loop starves every event type it doesn't dequeue, so
    /// without this the wheel / two-finger scroll is dead for the whole
    /// duration of a selection drag. Each scroll event forwards to the
    /// enclosing scroll view, then the selection re-extends against the
    /// cursor's new document position.
    private func trackSelection(
        startDocPoint start: CGPoint,
        byWord: Bool,
        selection: TranscriptSelectionCoordinator
    ) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .scrollWheel]
        while true {
            guard
                let event = NSApp.nextEvent(
                    matching: mask,
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true)
            else { break }

            if event.type == .leftMouseUp { break }

            if event.type == .scrollWheel {
                enclosingScrollView?.scrollWheel(with: event)
            }

            let drag = convert(event.locationInWindow, from: nil)
            selection.updateSelection(from: start, to: drag, byWord: byWord)

            // Edge autoscroll only applies to drag ticks — a scroll event
            // is the user already driving the viewport themselves.
            if event.type == .leftMouseDragged {
                autoscrollIfNeeded(cursorInDocCoord: drag)
            }
        }
    }

    /// Manual replacement for `NSView.autoscroll(with:)` — the default
    /// path misbehaves against a flipped document + `contentInsets`
    /// (edge check trips inside the visible area; direction inverts).
    /// Per-tick step is the raw overshoot capped at 40pt;
    /// `constrainBoundsRect` respects the scroll view's insets.
    private func autoscrollIfNeeded(cursorInDocCoord cursor: CGPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let visible = visibleRect
        let dy: CGFloat
        if cursor.y < visible.minY {
            dy = cursor.y - visible.minY
        } else if cursor.y > visible.maxY {
            dy = cursor.y - visible.maxY
        } else {
            return
        }
        let step = max(-40, min(40, dy))
        let clipView = scrollView.contentView
        let candidate = NSRect(
            origin: NSPoint(
                x: clipView.bounds.origin.x,
                y: clipView.bounds.origin.y + step),
            size: clipView.bounds.size)
        let constrained = clipView.constrainBoundsRect(candidate)
        guard constrained.origin.y != clipView.bounds.origin.y else { return }
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        let text = selection.copyText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        selection?.selectAllText()
        // Cmd+A implies the outline wants edit-menu focus from now on so
        // a follow-up Cmd+C lands here even if the selection wasn't
        // started by a drag.
        window?.makeFirstResponder(self)
    }

    /// `NSMenuItemValidation` conformance — `NSResponder` doesn't surface
    /// this in Swift's public API, so it can't be `override`. For actions
    /// we don't explicitly constrain, fall back to `responds(to:)`.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return selection?.isEmpty == false
        case #selector(selectAll(_:)):
            return selection?.hasSelectableText ?? false
        default:
            return responds(to: menuItem.action)
        }
    }
}

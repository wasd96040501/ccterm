import AppKit

/// The view a self-drawn row is served through: holds one measured block, plays
/// what it paints, and owns the selection in it.
///
/// It owns no layout — the block arrived already measured at the width the
/// transcript committed to — and no styling. What it does own is the three things
/// a block cannot: a place in the view hierarchy, the `dirtyRect` that lets the
/// block skip what cannot be seen, and **state**.
///
/// That last one is the reason selection lives here rather than on the block. A
/// measured block is a derived value: `heightOfRow` builds one, `viewForRow`
/// builds another, and a width change throws them all away. State hung on
/// something that gets rebuilt disappears with it. A view has identity and a
/// lifetime, and is what AppKit puts `selectedRanges` on for the same reason.
///
/// **Selection here is one row's.** A drag that leaves this cell stops at its
/// edge, and a selection in another row is another cell's business — each drops
/// its own when it stops being the first responder, which is all the coordination
/// there is.
///
/// `isFlipped` is true so that the y-down arithmetic every block is written in
/// matches the context it draws into, rather than being un-flipped at each of
/// the several dozen places a rectangle crosses the boundary.
final class BlockView: NSView {

    private(set) var block: MeasuredBlock?

    /// A link in this row was clicked. Reported with the view rather than the row
    /// index, because a row's index moves under it — the transcript resolves the
    /// current one at the moment of the call.
    ///
    /// A closure, where §4 of the package's notes asks for a delegate: those two
    /// protocols are the *host's* surface, and this crosses no such boundary —
    /// `TranscriptView` builds these views itself. Handing the view back rather
    /// than capturing it is what keeps the closure from retaining its own owner.
    var onLinkActivated: ((BlockView, URL) -> Void)?

    /// The link under the pointer changed. `nil` on leaving one.
    ///
    /// Reported rather than acted on: what a hover *shows* is the host's, and
    /// this package draws none of it. Fires only when the answer changes, so a
    /// listener may treat each call as an instruction rather than a sample.
    var onLinkHovered: ((BlockView, URL?, CGPoint) -> Void)?

    /// What the last report said, so a pointer sliding along one link is one
    /// call and not one per mouse-moved event.
    private var hovered: URL?

    override var isFlipped: Bool { true }

    /// Rows do not overlap and the transcript draws no background of its own, so
    /// AppKit can skip everything behind this view.
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)

        // Layer-backed, and redrawn only when marked. Scrolling then composites
        // a rasterised bitmap rather than re-issuing `draw(_:)` for every strip
        // the clip view exposes, and the only thing that costs a repaint is
        // something actually saying the content changed.
        //
        // The counterpart obligation: AppKit's default policy for a `draw(_:)`
        // view redraws on resize, and this one explicitly does not — so every
        // resize that changes what should be on screen has to mark the view
        // itself. Nothing here is exempt from that, including a width change.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Once, not per `updateTrackingAreas` pass: `.inVisibleRect` is the option
        // that tells AppKit to keep the area's rectangle synchronised with the
        // view's visible rect itself, which is the whole reason not to re-register
        // it by hand. The `rect` argument is ignored under that option.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlockView is code-only; init(coder:) is unavailable")
    }

    /// Binds a measured block. Idempotent — a recycled instance keeps nothing
    /// from the row it was serving a moment ago, because the block is the
    /// entirety of its state.
    func configure(with block: MeasuredBlock) {
        // A different document: the old endpoints indexed text that is no longer
        // here. This is the recycling rule — a pooled cell must arrive as empty
        // as a fresh one.
        anchor = nil
        focus = nil
        remeasured(to: block)
    }

    /// The **same** document, re-measured at a new width.
    ///
    /// Separate from `configure` for one reason: it keeps the selection. The flat
    /// index space is a function of the document's content and no part of it
    /// depends on the width — the invariant stated below — so the endpoints still
    /// name the characters they named before, and dropping them would lose a
    /// reader's selection every time the window edge moved.
    ///
    /// Marking the view is not optional here. `layerContentsRedrawPolicy` is
    /// `.onSetNeedsDisplay`, so a resize alone repaints nothing; the old lines
    /// would simply be stretched.
    func remeasured(to block: MeasuredBlock) {
        self.block = block

        needsDisplay = true
    }

    // MARK: - Selection
    //
    // The state is two indices and it lives **here**, not on the block. A
    // measured block is a derived value: `heightOfRow` builds one, `viewForRow`
    // builds another, and a width change throws them all away and rebuilds. State
    // hung on something that gets rebuilt disappears without anyone noticing. A
    // view, by contrast, has identity and a lifetime, receives the mouse events,
    // and is what AppKit puts `selectedRanges` on for the same reason.
    //
    // The indices survive a re-measure, which is why nothing has to be restored
    // after one: the flat index space is a function of the document's content, and
    // no part of it depends on the width the document was laid out at.

    /// Where the drag started, and where it is now. Kept apart rather than as one
    /// range because a drag runs in either direction and the anchor is the end
    /// that does not move.
    private var anchor: Int?
    private var focus: Int?

    /// The link the current press started on, if it started on one.
    private var pressedLink: InlineLink?

    private var selection: Range<Int>? {
        guard let anchor, let focus, anchor != focus else { return nil }
        return min(anchor, focus)..<max(anchor, focus)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Clears on losing focus, which is also how a selection in one row goes away
    /// when the reader starts one in another: each cell drops its own when it
    /// stops being the first responder. No coordinator, and nothing in this
    /// package knows that two rows exist at once — `NSTextField` gets rid of its
    /// selection the same way.
    override func resignFirstResponder() -> Bool {
        anchor = nil
        focus = nil
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        guard let block else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)

        // Remembered, not acted on. A press on a link is only a click if it does
        // not become a drag and does not select anything — the same rule
        // `NSTextView` uses, and the reason a link's text is still selectable.
        pressedLink = block.link(at: convert(event.locationInWindow, from: nil))

        let index = block.index(at: convert(event.locationInWindow, from: nil))
        // Which unit a click means is the block's to answer — it owns the text
        // the boundaries are in. All this does is pick the question.
        let range: Range<Int>
        switch event.clickCount {
        case 2: range = block.wordRange(at: index)
        case 3...: range = block.paragraphRange(at: index)
        default: range = index..<index
        }
        anchor = range.lowerBound
        focus = range.upperBound
        needsDisplay = true
    }

    /// An I-beam over the whole row, not only over glyphs.
    ///
    /// `NSTextView` does the same, and for a better reason than economy: the
    /// cursor is telling the reader *this region is selectable*, and the gaps
    /// between two paragraphs are as selectable as the paragraphs — a drag runs
    /// straight through them. A pointer that flickered to an arrow in the leading
    /// would be reporting a boundary that does not exist.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Links get the pointing hand, and everything else takes the I-beam back.
    ///
    /// Driven from `mouseMoved` rather than from more cursor rects, because a
    /// cursor rect is a rectangle and a link is not one — it wraps, so it is a
    /// *set* of rectangles that only exists after the text is typeset. Asking the
    /// block per move is the same point query activation uses, and keeps one
    /// answer to "is this a link" instead of two that can disagree.
    ///
    /// `resetCursorRects` above still sets the I-beam: it covers entering the
    /// view without moving inside it, which produces no `mouseMoved` at all.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let link = block?.link(at: point)
        (link == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
        report(link?.url, at: point)
    }

    /// The pointer left the row. Without this the last report would stand after
    /// the pointer left through an edge, which produces no further `mouseMoved`
    /// inside this view.
    override func mouseExited(with event: NSEvent) {
        report(nil, at: .zero)
    }

    /// Content slides out from under a stationary pointer, so the last report
    /// stops being true before any move event says so.
    override func scrollWheel(with event: NSEvent) {
        report(nil, at: .zero)
        super.scrollWheel(with: event)
    }

    /// Recycled into another row, or taken out of the hierarchy entirely.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { report(nil, at: .zero) }
    }

    private func report(_ url: URL?, at point: CGPoint) {
        guard url != hovered else { return }
        hovered = url
        onLinkHovered?(self, url, point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLink = nil }
        // `selection` non-nil covers both endings that are not a click: a drag
        // that moved, and a double-click that took a word. Neither should open
        // anything.
        guard let link = pressedLink, selection == nil else { return super.mouseUp(with: event) }

        onLinkActivated?(self, link.url)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let block, anchor != nil else { return super.mouseDragged(with: event) }
        focus = block.index(at: convert(event.locationInWindow, from: nil))
        // Lets a drag continue past the edge of the viewport, which matters most
        // on exactly the rows where selection is most wanted — a code block taller
        // than the window.
        autoscroll(with: event)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let block, let selection else { return }
        let text = block.text(from: selection.lowerBound, to: selection.upperBound)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Light ↔ dark flip, or the view joining a different appearance context.
    ///
    /// A repaint is the whole fix: blocks store `NSColor`s rather than resolved
    /// `CGColor`s, and both Core Text and `setFillColor` resolve them against the
    /// appearance current at draw time. Measured, not assumed — a tree built
    /// under light and drawn under dark is pixel-identical to one built under
    /// dark. So this costs one invalidation, and re-measuring would be wasted
    /// work.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let block, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Collect, then play. The two steps are what let this view add strokes of
        // its own — a selection band, later a search hit — at a depth the blocks
        // decide, without reaching into any block's drawing. It appends an item
        // with a phase; the player puts it where that phase says.
        items.removeAll(keepingCapacity: true)
        block.paint(at: .zero, dirty: dirtyRect, into: &items)

        if let selection {
            // Indices in, geometry out — and the block that owns the index space
            // is the one that decides what lies between two points, which is how a
            // table hands back a rectangle here rather than everything in reading
            // order between its corners. Derived every repaint rather than stored:
            // it changes on every mouse-moved event, so a cache would be stale as
            // often as it was warm, and this is a tree walk with no typesetting.
            //
            // `.decoration` earns exactly one of the two things it looks like it
            // is doing. Landing above the backgrounds is free — these items are
            // appended after the whole walk, so within any single tier they would
            // sort last anyway. Landing *below* the glyphs is the real constraint,
            // and the only reason this cannot simply be painted after the block.
            let color: NSColor =
                window?.isKeyWindow == true
                ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
            for rect in block.rects(from: selection.lowerBound, to: selection.upperBound) {
                items.append(.fill(rect, color, phase: .decoration))
            }
        }

        items.paint(in: ctx, dirty: dirtyRect)
    }

    /// Held across draws so the list's storage is allocated once rather than per
    /// repaint. Never read outside `draw(_:)`.
    private var items: [PaintItem] = []
}

extension BlockView: NSMenuItemValidation {

    /// Greys out Copy when there is nothing selected. ⌘C reaches this view
    /// because it is the first responder while its selection exists, so the
    /// standard menu item needs no wiring beyond the two methods.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return selection != nil
    }
}

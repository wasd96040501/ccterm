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
    /// What the hover *says* is still the host's — an address in a label, a
    /// preview, nothing at all. What it *looks like on the run* is not, and cannot
    /// be: only this side knows which rectangles a run occupies. So the band under
    /// the words is drawn here and the label is reported, which is the line
    /// between the two halves.
    ///
    /// Fires only when the answer changes, so a listener may treat each call as an
    /// instruction rather than a sample.
    var onLinkHovered: ((BlockView, URL?, CGPoint) -> Void)?

    /// The link the pointer is on. Holds the whole link rather than its address
    /// so that a pointer sliding along one run is one report and one band, and so
    /// that the band survives a re-measure — the range still names the same
    /// characters at any width.
    private var hovered: InlineLink?

    override var isFlipped: Bool { true }

    /// Rows do not overlap and the transcript draws no background of its own, so
    /// AppKit can skip everything behind this view.
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)

        // Layer-backed, and this view's own layer draws **nothing** — it is a
        // container, and the row is painted by the surfaces hung inside it. See
        // `SurfaceLayer` for why a row is a stack rather than one bitmap.
        //
        // Rasterised and composited, so scrolling re-issues no drawing at all and
        // the only thing that costs a repaint is something saying the content
        // changed. The counterpart obligation: nothing redraws on resize either,
        // so every resize that changes what should be on screen has to say so —
        // and `invalidate()` is where all of them go through.
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        restack()

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
        // Same rule, and the band is the part of it that would be *visible* if it
        // were forgotten: a pooled cell arriving with a highlight over words the
        // previous document had. Taken away outright rather than faded, because
        // there is nothing left for a fade to be about.
        removeHoverBand()
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
    /// Marking is not optional here. A surface redraws only when told to, so a
    /// resize alone repaints nothing and the old lines would simply be stretched
    /// to the new size.
    func remeasured(to block: MeasuredBlock) {
        self.block = block
        // A different tree may paint at different phases — a paragraph that became
        // a table has something under the band now, and the cached answer was
        // about the old one.
        paintsUnderBand = nil
        restack()

        invalidate()
        // The band is geometry over a range, and the range is the half that does
        // not depend on the width — so a re-measure does not lose the hover, it
        // just moves the band to where those same characters are now. This is the
        // reason a link reports where it is rather than only what it is.
        updateHoverBand()
    }

    /// The one place this view is marked for repaint.
    ///
    /// A funnel rather than a habit, and it is here before there is anything to
    /// funnel. A surface redraws only when marked, so nothing here repaints
    /// unless something says so — and the moment a row composites more
    /// than one surface, *every* surface has to be marked, in the **same source
    /// phase**, so that they flush into a single transaction at `beforeWaiting`.
    /// Marked in two different phases, they land in two transactions and the frame
    /// between them shows one surface updated against the other's stale contents:
    /// a selection band moved, the card fill under it not yet.
    ///
    /// Five call sites each remembering that is five chances to tear a frame. One
    /// is none, and the sites read better for saying what they mean rather than
    /// how it is achieved.
    private func invalidate() {
        surfaces.forEach { $0.setNeedsDisplay() }
    }

    // MARK: - The hover band

    /// The band under the hovered run. Kept as a layer rather than a `PaintItem`
    /// for one reason: it is the only thing here that changes on its own clock. A
    /// paint list is a snapshot played synchronously, with no notion of time, so
    /// fading one in would mean redrawing the row every frame for a fifth of a
    /// second. As a layer it is interpolated by the render server and this side
    /// draws nothing at all.
    ///
    /// It sits at the **bottom** of the sublayers, which is under the glyphs
    /// because the row's painting is itself a surface above it — that is the whole
    /// reason the painting moved onto a surface.
    ///
    /// Bottom is enough today, and there is no second drawn surface, because
    /// nothing a link sits on is opaque. Prose, headings, list items and quotes
    /// paint nothing at `.background` behind their text at all; a table paints row
    /// tints there, but they are 2.5–8% black (4–14% white in dark), so a band
    /// under a table cell is veiled by a few percent rather than hidden. Links do
    /// not occur inside a code card, which is the one opaque fill here.
    ///
    /// If something opaque ever does end up over a link, the fix is to cut the
    /// stack at `.decoration` and put the band between the two halves — which the
    /// surfaces already make an addition rather than a redesign. Until then that
    /// cut would be machinery with nothing to separate.
    private var hoverBand: CAShapeLayer?

    /// Telegram's hover fill on the one control it tints this way — the comments
    /// strip on a channel post — is its accent at 8%, and its pressed state 16%.
    /// This is the same idea against the colour the links themselves are drawn in,
    /// so the band and the words it sits under move together through light, dark,
    /// and whatever accent the reader has chosen.
    ///
    /// 8% is Telegram's own, on the one control it tints this way — the comments
    /// strip on a channel post. 12% and 10% were both put on screen on the way to
    /// keeping it, and both read heavier than the affordance wants to be: a hover
    /// confirms what the pointer is on, and past a certain weight it starts
    /// announcing itself the way a selection does.
    ///
    /// One number, where Telegram's *comparable* case — the tint behind prose
    /// links in Instant View, which is this geometry rather than a 42-point strip
    /// — is 7% light against 13% dark. If the band ever reads faint in dark, that
    /// near-doubling is the precedent, and this is the constant that would become
    /// two of them.
    private static let bandColor = NSColor.linkColor.withAlphaComponent(0.08)

    private static let bandRadius: CGFloat = 4

    /// Telegram's own duration for fading a tinted band over text.
    private static let bandFade: CFTimeInterval = 0.2

    /// Brings the band to where `hovered` says, or takes it away.
    ///
    /// Called on every change of the hovered link and after a re-measure. Both go
    /// through here so there is one description of what the band should look like
    /// given the state, rather than one per event that can disagree.
    private func updateHoverBand() {
        guard let hovered, let block else { return dismissHoverBand() }

        let rects = block.rects(from: hovered.range.lowerBound, to: hovered.range.upperBound)
        guard !rects.isEmpty else { return dismissHoverBand() }

        let band = hoverBand ?? makeHoverBand()

        // Geometry never animates. `CAShapeLayer` interpolates a path only between
        // paths of matching structure, so a link that wraps onto two lines turning
        // into one that does not would be a morph between shapes with different
        // subpath counts — undefined, and in practice a lurch. Sliding straight
        // from one link to the next therefore *cuts* to the new shape while the
        // opacity stays where it is, which is also what reads correctly: the band
        // is not travelling, it is somewhere else now.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.path = Self.band(over: rects, radius: Self.bandRadius)
        band.fillColor = resolvedBandColor()
        CATransaction.commit()

        fade(band, to: 1)
    }

    /// Fades the band out, and takes the layer away once it is gone — unless a new
    /// hover arrived while it was fading, which the completion re-checks rather
    /// than trying to cancel.
    private func dismissHoverBand() {
        guard let band = hoverBand else { return }
        fade(band, to: 0) { [weak self] in
            guard let self, self.hovered == nil else { return }
            band.removeFromSuperlayer()
            self.hoverBand = nil
            // Back to one surface: the split existed to hold the band apart from
            // what was under it, and there is no longer a band.
            self.restack()
        }
    }

    /// Immediately, with no fade and no completion to race — for the paths where
    /// the row stops being this row at all.
    /// No `restack()` here, and that is not an omission: the only caller is
    /// `configure(with:)`, which re-measures on the next line, and re-measuring
    /// is what owns putting the stack back in step with the block it now holds.
    /// A second call would be one nothing can break and therefore nothing covers.
    private func removeHoverBand() {
        hovered = nil
        hoverBand?.removeFromSuperlayer()
        hoverBand = nil
    }

    private func makeHoverBand() -> CAShapeLayer {
        let band = CAShapeLayer()
        band.opacity = 0
        band.contentsScale = window?.backingScaleFactor ?? 2
        hoverBand = band
        // Its depth is the stack's to decide, not this method's: it goes wherever
        // `bandPhase` puts it, which is under the glyphs and — where there is
        // anything down there — over the backgrounds.
        restack()
        return band
    }

    /// The explicit animation is the whole of the movement: implicit actions are
    /// disabled alongside it so that one write cannot produce two animations that
    /// disagree about where they started.
    ///
    /// `from` is the *presentation* value, so a band interrupted half-way out
    /// resumes from where it visibly is rather than snapping to full first.
    private func fade(_ band: CAShapeLayer, to opacity: Float, then: (() -> Void)? = nil) {
        let from = band.presentation()?.opacity ?? band.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(then)

        band.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = Self.bandFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        band.add(fade, forKey: "opacity")

        CATransaction.commit()
    }

    /// A `CGColor` is resolved once and stays that way, where the `NSColor`s in a
    /// paint list are resolved against the appearance current at draw time. So
    /// this is the one colour here that has to be re-resolved by hand when the
    /// appearance changes.
    private func resolvedBandColor() -> CGColor {
        var resolved = Self.bandColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = Self.bandColor.cgColor
        }
        return resolved
    }

    /// One shape over a run's line rectangles.
    ///
    /// Rounded outside, and **continuous** where two lines meet. Rounding each
    /// line separately would leave a pinch at every join, so a wrapped link would
    /// read as two stacked pills rather than one band; a bridge across the
    /// horizontal overlap fills exactly the notch the two roundings leave. Filled
    /// non-zero, so the overlapping subpaths merge instead of cancelling.
    ///
    /// Telegram solves the same problem in `generateRectsImage` by also softening
    /// the side steps with concave fillets. This is the half that makes the shape
    /// one shape; the fillets are cosmetic on top of it, and worth adding only if
    /// the steps actually read badly.
    ///
    /// Two lines that do not overlap horizontally get no bridge, because they do
    /// not touch — a run ending at the right margin and resuming at the left is
    /// two bands, and drawing it as one would be joining across a gap that is
    /// really there.
    private static func band(over rects: [CGRect], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            let left = max(upper.minX, lower.minX)
            let right = min(upper.maxX, lower.maxX)
            guard right > left else { continue }
            path.addRect(
                CGRect(
                    x: left, y: upper.maxY - radius, width: right - left, height: radius * 2))
        }
        return path
    }

    // MARK: - Surfaces

    /// The row's painting, bottom to top. One of these covering every phase is the
    /// resting state; a decoration that has to sit under the glyphs splits it.
    private var surfaces: [SurfaceLayer] = []

    /// Where the band sits in the paint order — above the backgrounds and below
    /// the glyphs, which is the tier a selection band is emitted at and for the
    /// same reason. The cut goes on a phase **boundary**, never inside one:
    /// ordering within a phase is load-bearing (a table emits its row fills and
    /// then its dividers, both `.background`), and a cut through the middle of one
    /// would decide that order by which surface an item happened to land on.
    ///
    /// Putting the cut *at* `.decoration` rather than after it also settles the
    /// band against the selection correctly: the selection is emitted at
    /// `.decoration`, so it lands on the upper surface and therefore over the
    /// band. Selecting a link tints it and keeps the hover visible underneath.
    private static let bandPhase = PaintItem.Phase.decoration

    /// Whether this block paints anything at all below the band's phase — the
    /// question that decides whether a second surface is worth its bitmap. Cached
    /// per binding, because it is a tree walk and the answer cannot change while
    /// the block does not.
    ///
    /// Deliberately coarse: it asks whether anything is down there, not whether
    /// anything down there is *behind this particular run*. A blockquote's bar is
    /// at `.background` and never overlaps the text beside it, so a quote splits
    /// when it strictly need not. Testing the overlap instead would mean deriving
    /// a rectangle from every primitive and getting that right for four of them,
    /// to save one bitmap on a row that is being hovered right now.
    private var paintsUnderBand: Bool?

    private func blockPaintsUnderBand() -> Bool {
        if let paintsUnderBand { return paintsUnderBand }
        guard let block else { return false }

        var items: [PaintItem] = []
        block.paint(at: .zero, dirty: CGRect(origin: .zero, size: block.size), into: &items)
        let answer = items.contains { $0.phase < Self.bandPhase }
        paintsUnderBand = answer
        return answer
    }

    /// Arranges the sublayers into paint order: the surfaces under the band, the
    /// band, the surfaces over it.
    ///
    /// **The stack is split only when there is something to separate** — a band
    /// present *and* something painted beneath its phase. With nothing under the
    /// band, "beneath the glyphs" and "beneath everything" are the same place, and
    /// a second surface would be an empty bitmap the size of the row. That is the
    /// common case and it stays at one surface: prose, headings and list items
    /// paint nothing at `.background` behind their text.
    ///
    /// Idempotent, and cheap when nothing changed — which matters because the only
    /// rows that ever re-split are the ones being hovered.
    private func restack() {
        // The cut is asked for only when there is something to separate; the
        // partition it produces is the phase order's own business.
        let split = hoverBand != nil && blockPaintsUnderBand()
        let wanted = PaintItem.Phase.slices(cutAt: split ? [Self.bandPhase] : [])

        if surfaces.map(\.phases) != wanted {
            surfaces.forEach { $0.removeFromSuperlayer() }
            surfaces = wanted.map { SurfaceLayer(playing: $0, for: self) }
            let scale = window?.backingScaleFactor ?? 2
            for surface in surfaces {
                surface.frame = bounds
                surface.contentsScale = scale
                surface.setNeedsDisplay()
            }
        }

        // The band goes after every surface that lies entirely below its phase —
        // which is none of them when the order was not cut, putting it at the
        // bottom, and derived rather than hardcoded for any number of cuts.
        let beneath = surfaces.prefix { $0.phases.upperBound < Self.bandPhase }
        var ordered: [CALayer] = beneath.map { $0 }
        if let hoverBand { ordered.append(hoverBand) }
        ordered.append(contentsOf: surfaces.dropFirst(beneath.count).map { $0 as CALayer })

        guard (layer?.sublayers ?? []) != ordered else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers = ordered
        CATransaction.commit()
    }

    /// Sizing is this view's, not autoresizing's: the surfaces are congruent with
    /// the view by definition, and a mask would express that as an accident of
    /// what the layer's frame happened to be when it was added.
    override func layout() {
        super.layout()
        // No implicit animation, and none of these should redraw for a size
        // change alone — a resize that changes what is on screen came through
        // `remeasured`, which marked them already.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaces.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    /// AppKit keeps its own layer's `contentsScale` in step with the display; a
    /// layer put there by hand is the owner's to maintain, and a stale one is a
    /// row that goes soft on the display it did not start on.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        surfaces.forEach { $0.contentsScale = scale }
        hoverBand?.contentsScale = scale
        invalidate()
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
        invalidate()
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
        invalidate()
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
        report(link, at: point)
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

    private func report(_ link: InlineLink?, at point: CGPoint) {
        guard link != hovered else { return }
        hovered = link
        updateHoverBand()
        onLinkHovered?(self, link?.url, point)
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
        invalidate()
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
        invalidate()

        // The one colour a repaint does not fix: it is a resolved `CGColor` on a
        // layer, not an `NSColor` in a paint list, so nothing re-resolves it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBand?.fillColor = resolvedBandColor()
        CATransaction.commit()
    }

    /// Plays `phases` of this row into one surface.
    ///
    /// The whole list is collected whatever the slice is. Collecting is a tree
    /// walk that allocates nothing per item, and the alternative — asking the tree
    /// for one phase at a time — would mean walking it once per surface and giving
    /// every block a reason to know which phase it is being asked about. Playing
    /// is where the slice applies, because that is where the order lives.
    fileprivate func paint(
        _ phases: ClosedRange<PaintItem.Phase>, in ctx: CGContext, dirty dirtyRect: CGRect
    ) {
        guard let block else { return }

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

        items.paint(in: ctx, dirty: dirtyRect, phases: phases)
    }

    /// Held across draws so the list's storage is allocated once rather than per
    /// repaint. Never read outside `draw(_:)`.
    private var items: [PaintItem] = []
}

/// One composited surface: the slice of the paint order it plays, and nothing
/// else.
///
/// **Why a row is a stack rather than one bitmap.** CoreAnimation composites a
/// layer as `backgroundColor → contents → sublayers`, so anything hung inside a
/// layer lands *above* everything drawn into it. A row that drew all four phases
/// into one surface would therefore have exactly one place to put an animated
/// decoration — on top of the glyphs — while `PaintItem.Phase` describes four.
/// Two orders, and the animated thing stuck at the top of the wrong one.
///
/// Splitting the drawing across surfaces is what puts the two orders back into
/// one: a decoration inserted between two surfaces sits exactly where its phase
/// says, because the phases below it were drawn into the surface underneath and
/// the phases above it into the surface over the top.
///
/// The resting state is a single surface playing every phase, which is what this
/// costs when nothing is animating: one `CALayer` object, and the same one bitmap
/// a row has always had. A second surface is allocated only when something is
/// actually inserted between — and for the case that wants this first, a link
/// highlight under prose, the slice below the cut is empty, so there is no second
/// bitmap even then.
///
/// A `CALayer` subclass rather than a delegate: `NSView` is already its own
/// layer's delegate, and a second delegate relationship on the same object turns
/// every callback into "which layer is this".
private final class SurfaceLayer: CALayer {

    /// The slice of the paint order this surface plays. A **range**, so that a
    /// surface can say which phases are its own and cannot say what order to draw
    /// them in — that stays the declaration order, for everyone. Between them the
    /// surfaces of one row cover the order exactly once, which the cut they are
    /// derived from guarantees rather than their construction sites remembering.
    fileprivate private(set) var phases: ClosedRange<PaintItem.Phase> = PaintItem.Phase.all

    /// Weak, and the direction that matters: the view owns its layers, so a
    /// strong edge back would be a cycle that outlives every row it recycles.
    private weak var owner: BlockView?

    init(playing phases: ClosedRange<PaintItem.Phase>, for owner: BlockView) {
        self.phases = phases
        self.owner = owner
        super.init()
    }

    /// CoreAnimation copies a layer to build its presentation, and does it through
    /// this initialiser. Nothing here animates, so the copy never gets read — but
    /// it is still constructed, and a `super.init(layer:)` that skipped the fields
    /// would hand back a surface that draws nothing if anything ever did.
    override init(layer: Any) {
        if let layer = layer as? SurfaceLayer {
            phases = layer.phases
            owner = layer.owner
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SurfaceLayer is code-only; init(coder:) is unavailable")
    }

    /// No implicit animations, ever. A surface is congruent with its view, so
    /// every geometry write it receives is a resize being applied — and a resize
    /// that eased into place over a quarter second is the row's content sliding
    /// while the transcript has already committed to the new height.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// The clip is the dirty region CoreAnimation is asking for, which is the
    /// same permission-to-skip `draw(_:)` used to receive as its `dirtyRect`.
    override func draw(in ctx: CGContext) {
        owner?.paint(phases, in: ctx, dirty: ctx.boundingBoxOfClipPath)
    }
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

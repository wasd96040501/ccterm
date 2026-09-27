import AppKit

/// The view a self-drawn row is served through: holds one measured block, plays
/// what it paints, and draws the part of the selection that falls in it.
///
/// It owns no layout — the block arrived already measured at the width the
/// transcript committed to — and no styling. What it does own is the things a
/// block cannot: a place in the view hierarchy, the `dirtyRect` that lets the
/// block skip what cannot be seen, and the pointer's state — the hover, the press.
///
/// **The selection is not one of them.** It runs across rows, so it is the
/// transcript's (`TextSelection`): this view reports the presses and drags that
/// make one (`onSelect`) and is handed back its own part to draw
/// (`selectedRange`), the way `NSTableView` sets `isSelected` on a row view. A
/// view is recycled the moment its row scrolls away, and a selection spanning
/// rows is always partly off screen — state kept here would go with it.
///
/// `isFlipped` is true so that the y-down arithmetic every block is written in
/// matches the context it draws into, rather than being un-flipped at each of
/// the several dozen places a rectangle crosses the boundary.
final class BlockView: NSView, TranscriptFindHighlighting {

    private(set) var block: MeasuredBlock?

    /// A link in this row was clicked. Reported with the view rather than the row
    /// index, because a row's index moves under it — the transcript resolves the
    /// current one at the moment of the call.
    ///
    /// The whole run goes over, not its address: what this view knows is *that an
    /// activatable run was clicked*, and which kind it was is a question only the
    /// side holding the host's delegate can act on. See `InlineLink.Destination`.
    ///
    /// A closure, where §4 of the package's notes asks for a delegate: those two
    /// protocols are the *host's* surface, and this crosses no such boundary —
    /// `TranscriptView` builds these views itself. Handing the view back rather
    /// than capturing it is what keeps the closure from retaining its own owner.
    var onLinkActivated: ((BlockView, InlineLink) -> Void)?

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

    /// This row was right-clicked, and the menu passed over is the one **this
    /// package** would show: the commands it implements itself, and nothing
    /// else. What comes back is what gets displayed — the same menu with items
    /// added, a different menu, or `nil` for none at all.
    ///
    /// Handing over a proposed menu rather than asking whether to show one is
    /// what lets the two sets of commands compose. Copy depends on a selection
    /// nobody outside this view can see, so it cannot be the host's to build;
    /// Quote, Retry and the rest depend on a model this package will never know
    /// about, so they cannot be this view's. A proposal that comes back edited
    /// is the only shape where each side writes the half it can.
    ///
    /// The menu is built fresh per click for that reason too — an accumulating
    /// shared instance would grow another copy of the host's items every time
    /// the reader right-clicked. That is the one place this deviates from
    /// `NSView.defaultMenu`, whose class-property shape hands the same object to
    /// everyone.
    ///
    /// Same closure-not-delegate reasoning as the two above.
    ///
    /// The event goes over too, because what the menu acts on is decided on the
    /// way: a right-click outside the selection takes the word under the pointer,
    /// and the selection is the transcript's to change.
    var onContextMenu: ((BlockView, NSMenu, NSEvent) -> NSMenu?)?

    /// A press or a drag in this row, for the transcript to turn into a selection.
    ///
    /// The event rather than a range, because a drag leaves this row and what is
    /// under the pointer then is only the transcript's to answer. And a closure
    /// rather than `super` up the responder chain, which would otherwise be the
    /// AppKit way to hand a mouse event on: a drag that autoscrolls can take this
    /// view's row off screen and the view out of the table, still receiving the
    /// drag, and the chain from a view the table has let go of leads nowhere.
    var onSelect: ((NSEvent) -> Void)?

    /// The part of the selection in this row, set by the transcript whenever it
    /// changes and whenever this view is bound to a row. Positions in the block's
    /// flat index space; `nil` when none of the row is selected.
    var selectedRange: Range<Int>? {
        didSet {
            guard selectedRange != oldValue else { return }
            invalidate()
        }
    }

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
        // A different document: the old range indexed text that is no longer
        // here, and a press on the old one's link must not open it on release.
        // This is the recycling rule — a pooled cell must arrive as empty as a
        // fresh one. What *this* row's part of the selection is, the transcript
        // says next.
        selectedRange = nil
        pressedLink = nil
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
    /// depends on the width, so the range still names the characters it named
    /// before, and dropping it would lose a reader's selection every time the
    /// window edge moved.
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

    // MARK: - Find

    /// Where a hit is, for the transcript to light it — the tree's own answer,
    /// in this view's coordinates because the block is drawn from its origin.
    ///
    /// The same rectangles a selection band is built from, which is what makes
    /// them the right shape here: a line's height, so a lit hit reads as a band
    /// of the line rather than a box around the ink.
    func rects(forCharacterRange range: Range<Int>) -> [NSRect] {
        block?.rects(from: range.lowerBound, to: range.upperBound) ?? []
    }

    /// Plays this row's glyphs — only its glyphs — clipped to where `range` is,
    /// for the find indicator to draw on its yellow.
    ///
    /// The paint list rather than a second way of drawing text: it is the only
    /// description of where each line sits, so the characters land on the
    /// indicator exactly where they are in the row. Fills and strokes are left
    /// out — a code card's background or a quote's bar would otherwise come out of
    /// the indicator's recolouring as a solid block — and the clip is the hit's
    /// rectangles, so the rest of each line stays behind.
    func drawCharacters(in range: Range<Int>) {
        guard let block, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rects = rects(forCharacterRange: range)
        guard
            let dirty = rects.reduce(
                nil,
                { (union: CGRect?, rect) in
                    union?.union(rect) ?? rect
                })
        else { return }

        var items: [PaintItem] = []
        block.paint(at: .zero, dirty: dirty, into: &items)
        let glyphs = items.filter {
            if case .text = $0.primitive { return true }
            return false
        }

        ctx.saveGState()
        ctx.clip(to: rects)
        glyphs.paint(in: ctx, dirty: dirty, phases: PaintItem.Phase.all)
        ctx.restoreGState()
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

    /// The same band while the button is down — twice the hover's weight.
    ///
    /// **Not Telegram's own 30%**, and the difference is the interaction model
    /// rather than taste. `linkHighlightColor` in its day theme is
    /// `accentColor.withAlphaComponent(0.3)`, and on iOS that one tint carries the
    /// *whole* gesture: there is no pointer, so nothing precedes the touch and the
    /// highlight has to announce itself from nothing. Here it steps up from a
    /// hover that is already showing, and 30% against 8% reads as the row
    /// flinching rather than as the same band pressed.
    ///
    /// So the number is taken from the one Telegram control that has both states —
    /// the comments strip on a channel post, 8% resting and 16% pressed — which is
    /// the same *step* rather than the same *value*. One constant if it ever wants
    /// to be the louder one.
    private static let pressedBandColor = NSColor.linkColor.withAlphaComponent(0.16)

    private static let bandRadius: CGFloat = 4

    /// How far the band reaches past the glyphs it is under, on every side.
    ///
    /// Telegram's `LinkHighlightingNode` insets each of its rectangles by `-2`
    /// before rounding them at 4, and the reason shows up at the ends of a run: a
    /// band drawn to the ink starts and stops exactly at the first and last stem,
    /// so the tint reads as clipped by the letters rather than as something behind
    /// them. Two points is also what keeps a 4-point radius from biting into the
    /// glyphs at the corners.
    ///
    /// Only the band takes it. A selection's rectangles are the line boxes and
    /// must stay flush — inflating those would make consecutive lines' highlights
    /// overlap, which is exactly what a selection must not look like.
    private static let bandInset: CGFloat = 2

    /// Telegram's own duration for taking a tinted band off text —
    /// `animateAlpha(from: 1.0, to: 0.0, duration: 0.18)` where it drops the
    /// highlight on a link.
    ///
    /// Used in both directions here, where Telegram animates only the way out. It
    /// has no hover to arrive from: its band appears under a finger that is
    /// already down, and appearing instantly is right for that. Ours arrives under
    /// a pointer that merely passed by, and a band that snapped in on every word
    /// crossed would be the row twitching.
    private static let bandFade: CFTimeInterval = 0.18

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
        band.path = Self.band(over: rects, radius: Self.bandRadius, inset: Self.bandInset)
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
        let color = isPressed ? Self.pressedBandColor : Self.bandColor
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    /// Whether the band is showing its pressed tint: the button is down, on the
    /// run the pointer is on, and the press has not become a drag.
    ///
    /// Derived rather than set, from three pieces of state that already exist —
    /// which is what keeps "pressed" meaning the same thing here as it does in
    /// `mouseUp`, where the same three decide whether a press was a click.
    private var isPressed = false

    /// Re-derives the pressed tint and, if it changed, writes it.
    ///
    /// **Instantly, unlike every other change to this band.** Telegram animates
    /// its highlight out and not in, and a press is the same case for a stronger
    /// reason: feedback that eases in over a fifth of a second is feedback that
    /// arrives after the finger has left. The fade stays where it belongs, on the
    /// band's arrival and departure.
    private func updatePressedState() {
        let pressed = pressedLink != nil && pressedLink == hovered && selectedRange == nil
        guard pressed != isPressed else { return }
        isPressed = pressed

        guard let hoverBand else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBand.fillColor = resolvedBandColor()
        CATransaction.commit()
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
    ///
    /// `inset` is applied first, so the bridging below reasons about the same
    /// rectangles that get drawn: two wrapped lines inflated towards each other
    /// already overlap, and the bridge fills what the roundings still leave.
    private static func band(over rects: [CGRect], radius: CGFloat, inset: CGFloat) -> CGPath {
        let rects = rects.map { $0.insetBy(dx: -inset, dy: -inset) }
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

    // MARK: - Pressing and dragging
    //
    // What a press *selects* is the transcript's to decide (`onSelect`); what it
    // means for a link under it is this view's, because the link, the band and the
    // pointer are.
    //
    // No `acceptsFirstResponder` here, deliberately: the responder that owns the
    // selection, and copies it, is the transcript's table. Were this view to
    // accept, the window would make it first responder on every click — pulling
    // focus off the table, and with it the selection, before this press could
    // start the next one.

    /// The link the current press started on, if it started on one.
    private var pressedLink: InlineLink?

    override func mouseDown(with event: NSEvent) {
        guard let block else { return super.mouseDown(with: event) }

        // Remembered, not acted on. A press on a link is only a click if it does
        // not become a drag and does not select anything — the same rule
        // `NSTextView` uses, and the reason a link's text is still selectable.
        pressedLink = block.link(at: convert(event.locationInWindow, from: nil))

        // The transcript picks the unit the click count means and hands this row
        // its part back synchronously, so it is in `selectedRange` by the next
        // line.
        onSelect?(event)
        // After the selection is set, not before: whether this counts as a press
        // depends on it — a double-click takes a word, which is a selection, and
        // is therefore not a press on the link under it.
        updatePressedState()
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
        // Before the band is brought up, so it arrives wearing the right tint: the
        // pointer can reach a run with the button already down — sliding off one
        // link onto another — and the band would otherwise fade in at the hover
        // weight under a finger that is pressing.
        updatePressedState()
        updateHoverBand()
        // The band is drawn for any activatable run; the *address* is reported
        // only when there is one, so a run with no destination to show reads to
        // the host exactly like leaving a link.
        onLinkHovered?(self, link?.url, point)
    }

    override func mouseUp(with event: NSEvent) {
        // The tint goes back to the hover's on the way out of every path through
        // here, activation included — the pointer is still on the run, so the band
        // stays; it is only the press that ended.
        defer {
            pressedLink = nil
            updatePressedState()
        }
        // A selected range covers both endings that are not a click: a drag that
        // moved, and a double-click that took a word. Neither should open
        // anything. A drag that moved on into the next row still leaves this one
        // selected to its end, so it counts too.
        guard let link = pressedLink, selectedRange == nil else {
            return super.mouseUp(with: event)
        }

        onLinkActivated?(self, link)
    }

    override func mouseDragged(with event: NSEvent) {
        guard onSelect != nil else { return super.mouseDragged(with: event) }
        onSelect?(event)
        // The moment the press selects anything it stops being a click — the rule
        // `mouseUp` applies — so the tint goes back to the hover's while the
        // pointer is still down. `pressedLink` itself is left alone: a click that
        // wobbled a point between down and up selects nothing and must still open
        // its link.
        updatePressedState()
    }

    // MARK: - The context menu

    /// The menu for a right-click (or a control-click, which arrives here by the
    /// same route).
    ///
    /// **Why the whole of it is here rather than split with `rightMouseDown`.**
    /// AppKit's own `rightMouseDown(with:)` does not display a context menu — its
    /// documented implementation "simply passes this message to the next
    /// responder", and the note beneath it says AppKit walks the chain only *if*
    /// it "doesn't find an associated context menu to display for the view."
    /// Finding it is this method, called from AppKit's event dispatch before any
    /// responder sees the click. So a `rightMouseDown` override would run after
    /// the menu had already been built, and everything below would be a click
    /// late.
    ///
    /// What the menu acts on is settled on the way, by the transcript
    /// (`onContextMenu` carries the event for it): the word under the pointer is
    /// selected unless the click landed inside the selection, and the selection's
    /// responder takes the focus so Copy validates against it. The selection is
    /// the transcript's, so both halves are too — see
    /// `TranscriptView.selectForContextMenu(with:)`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // `nil` target on purpose: that is what sends it up the responder chain
        // from the first responder to the `copy(_:)` of the selection's owner,
        // and what routes validation back through it. A key equivalent is left
        // off because a context menu conventionally carries none — the Edit menu
        // is where ⌘C is advertised.
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Copy", bundle: .module),
                action: #selector(NSText.copy(_:)), keyEquivalent: ""))

        guard let onContextMenu else { return menu }
        return onContextMenu(self, menu, event)
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
        // its own — a selection band — at a depth the blocks
        // decide, without reaching into any block's drawing. It appends an item
        // with a phase; the player puts it where that phase says.
        items.removeAll(keepingCapacity: true)
        block.paint(at: .zero, dirty: dirtyRect, into: &items)

        if let selection = selectedRange {
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
    ///
    /// **Under the row's appearance, made current by hand.** A paint list holds
    /// dynamic `NSColor`s and resolves them against `NSAppearance.current` as it
    /// plays. `draw(_:)` would have had AppKit set that to the view's effective
    /// appearance; a sublayer's `draw(in:)` is CoreAnimation's call, and gets
    /// whatever the process's is — so a window or a view given an appearance of its
    /// own drew its rows in the system's. The first window-server capture of a dark
    /// window showed it: black prose and a light code card on a dark background.
    override func draw(in ctx: CGContext) {
        guard let owner else { return }
        owner.effectiveAppearance.performAsCurrentDrawingAppearance {
            owner.paint(phases, in: ctx, dirty: ctx.boundingBoxOfClipPath)
        }
    }
}

import AppKit

/// How a find looks: the content dimmed, every match lit through the dimming, and
/// the one the reader is on raised in yellow — what `NSTextFinder` draws over an
/// `NSTextView` when its find bar searches incrementally, and what Safari and Notes
/// draw over theirs.
///
/// **AppKit's own presentation, measured rather than guessed.** An `NSTextView`
/// with an incremental find bar, captured through the window server in both
/// appearances: light dims to 18% black and cuts each match out square; dark does
/// not dim at all, and outlines each match with a one-pixel white rule instead; in
/// both, the current match is a yellow bubble with its characters drawn again in
/// black, a little larger than the line and lifted by a shadow. The rule is drawn
/// in light too, where it disappears against a white page and is what keeps a
/// match on a dark card — a code block, a bubble — from reading as a hole into the
/// window.
///
/// **In the document's coordinate space, so scrolling cannot move it off its
/// matches.** The view is a floating subview of the transcript's scroll view,
/// floating on the horizontal axis only: AppKit keeps it above the document and
/// below the scroller, and moves it with every vertical scroll exactly as it moves
/// the rows — including a scroll AppKit performs without the main thread's help.
/// What this view has to keep up with is only what is *under* it: which rows are
/// on screen, and where their matches are. It covers the visible rect with half a
/// screen to spare either way, so a row arriving from past the edge is already lit
/// before it is seen.
///
/// **Drawn over every row the same way, whoever drew the row.** Where a match is
/// and what its characters look like are the row view's to say, through
/// `BlockView` — where a match is (`rects(forCharacterRange:)`) and its glyphs alone (`drawCharacters(in:)`) — and
/// everything else is here. A row therefore never draws a find of its own. A host's `.view` row is
/// not searched, so it is never lit.
@MainActor
final class FindOverlayView: NSView {

    /// One row on screen, and its part in the find.
    struct Row {
        let id: TranscriptRow.ID
        let view: BlockView
        let matches: [Range<Int>]
        let current: Range<Int>?
    }

    /// Asked at every layout for the rows on screen that have matches. A
    /// question rather than a stored list, the way a table asks its data source:
    /// the rows move under a find more often than the find changes, and an answer
    /// read at layout is never one layout old.
    var rows: () -> [Row] = { [] }

    /// Where the matches are lit, in this view's coordinates — the holes in the
    /// dimming. The state the shade and the rules are drawn from, and what says
    /// from outside what is lit without a pixel being read.
    private(set) var litRects: [NSRect] = []

    /// The current match's bubbles, one per line it occupies.
    private(set) var indicators: [FindIndicatorView] = []

    private let shade = ShapeView()
    private let rules = ShapeView()

    /// The backing scale the rules were last drawn one pixel wide for.
    private var drawnScale: CGFloat = 0

    /// Which match the indicator last popped for. A pop says "you are here now",
    /// so it plays when the reader moves, and not when a scroll or a streamed row
    /// makes the same match lay out again.
    private var popped: (id: TranscriptRow.ID, range: Range<Int>)?

    /// Measured off AppKit's own dimming: white comes out at 209. Dark does not
    /// dim — see the type's note.
    private static let shadeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .clear
            : NSColor.black.withAlphaComponent(0.18)
    }

    private static let litCornerRadius: CGFloat = 3

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shade.shape.fillRule = .evenOdd
        rules.shape.fillColor = nil
        addSubview(shade)
        addSubview(rules)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FindOverlayView is code-only; init(coder:) is unavailable")
    }

    /// Flipped to match the document it lies over, so a rectangle converted from a
    /// row reads the way it did there.
    override var isFlipped: Bool { true }

    /// Never the target of a click or a scroll: everything under it stays exactly
    /// as reachable as it was before the find.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// The colours, resolved against the appearance here because a `CGColor` on a
    /// layer does not follow it — AppKit asks again on a light↔dark flip.
    override func updateLayer() {
        shade.shape.fillColor = Self.shadeColor.cgColor
        rules.shape.strokeColor = NSColor.white.cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Frames rather than constraints: every rectangle here is one a row reported,
    /// converted, and there is nothing for a constraint to pin to.
    override func layout() {
        super.layout()

        var lit: [NSRect] = []
        var current: [(rect: NSRect, row: Row, range: Range<Int>)] = []
        for row in rows() {
            for range in row.matches {
                for rect in row.view.rects(forCharacterRange: range) {
                    let here = convert(rect, from: row.view)
                    lit.append(here)
                    if range == row.current { current.append((here, row, range)) }
                }
            }
        }
        let scale = window?.backingScaleFactor ?? 2
        defer { layOutIndicators(current) }
        // Unchanged is the common answer — a row streamed in below, a re-tile that
        // moved nothing on screen — and a new path, even an equal one, has the
        // shade drawn again across a screen and a half.
        guard lit != litRects || bounds != shade.frame || scale != drawnScale else { return }
        litRects = lit
        drawnScale = scale

        shade.frame = bounds
        rules.frame = bounds
        let holes = CGMutablePath()
        for rect in lit {
            holes.addRoundedRect(
                in: rect, cornerWidth: Self.litCornerRadius, cornerHeight: Self.litCornerRadius)
        }
        let shadePath = CGMutablePath()
        shadePath.addRect(bounds)
        shadePath.addPath(holes)
        shade.shape.path = shadePath
        rules.shape.path = holes
        rules.shape.lineWidth = 1 / scale
    }

    private func layOutIndicators(_ current: [(rect: NSRect, row: Row, range: Range<Int>)]) {
        while indicators.count > current.count { indicators.removeLast().removeFromSuperview() }
        while indicators.count < current.count {
            let indicator = FindIndicatorView()
            addSubview(indicator)
            indicators.append(indicator)
        }
        for (indicator, part) in zip(indicators, current) {
            indicator.show(part.range, of: part.row.view, over: part.rect)
        }

        let now = current.first.map { (id: $0.row.id, range: $0.range) }
        defer { popped = now }
        guard let now, popped.map({ $0.id != now.id || $0.range != now.range }) ?? true,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        indicators.forEach { $0.pop() }
    }
}

/// A view whose layer is a `CAShapeLayer` — the shade and the rules. Views rather
/// than bare sublayers so AppKit orders them with the indicators by subview order,
/// and so their layers take no implicit animation from a path change: the backing
/// layer's delegate is the view, which answers none.
@MainActor
private final class ShapeView: NSView {

    var shape: CAShapeLayer { layer as! CAShapeLayer }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShapeView is code-only; init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One line of the current match, raised: a yellow bubble with the match's
/// characters drawn on it again, in black.
///
/// The characters come from the row, through `drawCharacters(in:)` — so they are
/// the row's own glyphs at the row's own positions — and are recoloured here, by
/// drawing them into a transparency layer and filling over it with `.sourceIn`.
/// That keeps every edge's antialiasing and needs nothing of the row but its glyphs,
/// which is why the protocol asks for nothing else: the yellow wants dark
/// characters in dark mode as much as in light, where the row's own are near-white.
@MainActor
final class FindIndicatorView: NSView {

    private weak var source: (BlockView)?
    private var range: Range<Int> = 0..<0

    /// Slightly larger than the line on every side, as AppKit's is.
    private static let padding = NSSize(width: 2, height: 1)
    private static let cornerRadius: CGFloat = 3

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.35)
        lift.shadowOffset = NSSize(width: 0, height: -1)
        lift.shadowBlurRadius = 2
        shadow = lift
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FindIndicatorView is code-only; init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The characters of `range` in `view`, on a bubble over `rect` — a rect in
    /// the superview's coordinates.
    func show(_ range: Range<Int>, of view: BlockView, over rect: NSRect) {
        let frame = rect.insetBy(dx: -Self.padding.width, dy: -Self.padding.height)
        let moved = view !== source || range != self.range || frame != self.frame
        source = view
        self.range = range
        self.frame = frame
        if moved { needsDisplay = true }
    }

    /// How long the bounce takes.
    static let popDuration: CFTimeInterval = 0.25

    /// Grows and settles once, about its centre — the find indicator's bounce,
    /// which is how the eye finds where it has been taken.
    func pop() {
        guard let layer else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(centre.x, centre.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -centre.x, -centre.y, 0)
        }
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [scaled(1), scaled(1.3), scaled(1)].map { NSValue(caTransform3D: $0) }
        bounce.keyTimes = [0, 0.4, 1]
        bounce.duration = Self.popDuration
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "pop")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.findHighlightColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            .fill()

        guard let source, let context = NSGraphicsContext.current else { return }
        let ctx = context.cgContext
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // Into the row's coordinate system, so the row draws as it would in its
        // own `draw(_:)` — including whether that system is flipped, which is the
        // context's to say for anything drawn through AppKit's text system.
        ctx.saveGState()
        ctx.concatenate(transform(from: source))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: source.isFlipped)
        source.drawCharacters(in: range)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The affine map from `view`'s coordinates to this view's, read off where
    /// three of its points land.
    private func transform(from view: NSView) -> CGAffineTransform {
        let o = convert(NSPoint.zero, from: view)
        let x = convert(NSPoint(x: 1, y: 0), from: view)
        let y = convert(NSPoint(x: 0, y: 1), from: view)
        return CGAffineTransform(
            a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }
}

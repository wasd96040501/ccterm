import AppKit

/// AppKit-native fade scrim used between the chat transcript and the
/// window chrome (top toolbar / bottom input bar).
///
/// Replaces the prior `NSHostingView<FadeScrim>` overlays for two
/// reasons:
///
/// 1. **Mouse + cursor passthrough.** SwiftUI's `.allowsHitTesting(false)`
///    only removes a view from SwiftUI's own hit-test chain. AppKit's
///    `NSView.hitTest(_:)` still resolves the hosting view first, so a
///    SwiftUI overlay over the transcript's `NSTableView` swallowed
///    scroll / click events. The earlier fix wrapped the hosting view
///    in an `NSView` with `hitTest(_:) → nil` (PR #181) — events
///    forwarded fine, but the inner `NSHostingView` still registered
///    cursor rects (default arrow), shadowing the I-beam / pointing-hand
///    rects that `BlockCellView.resetCursorRects` installs on the table
///    below. That regression got reverted in #190 and we lost mouse
///    passthrough again.
///
///    Going pure `NSView` (no `NSHostingView` anywhere inside) closes
///    both holes. We override `hitTest(_:)` to return `nil` for the
///    mouse path, and we never call `addCursorRect(_:cursor:)`, so the
///    cursor system walks past this view entirely and finds the table's
///    rects underneath.
///
/// 2. **Cutout coordinate space.** The old SwiftUI bottom scrim lived
///    in its own 160pt-tall `NSHostingView` SwiftUI subtree, but the
///    cutout rects (`attachRect`, `pillRect`) are reported in the
///    detail-pane coordinate space (full pane height). SwiftUI's
///    `.position(x:y:)` is local to its hosting tree, so the cutouts
///    landed off the canvas after #195 split the overlays into separate
///    hosting views. This view is constrained full-bleed to the detail
///    pane, so the cutout coordinates align directly.
///
/// Both scrims share an `isFlipped` top-left coordinate system so the
/// cutout rects (originating in SwiftUI) drop in without flipping.
@MainActor
class TranscriptScrimView: NSView {
    /// Where the gradient sits relative to the view's bounds and which
    /// direction it fades.
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    /// Height of the visible gradient band, measured from `edge`. The
    /// view itself is full-bleed; only this band paints.
    var bandHeight: CGFloat {
        didSet {
            guard bandHeight != oldValue else { return }
            needsDisplay = true
        }
    }

    init(edge: Edge, bandHeight: CGFloat) {
        self.edge = edge
        self.bandHeight = bandHeight
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Decorative overlay only — never intercept mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let band = bandRect()
        guard band.intersects(dirtyRect) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        applyCutoutClip(ctx: ctx)

        let opaque = NSColor.windowBackgroundColor
        let clear = NSColor.windowBackgroundColor.withAlphaComponent(0)
        guard let gradient = NSGradient(starting: opaque, ending: clear) else { return }
        // `NSGradient.draw(angle:)` interprets angle counterclockwise
        // from +X in the *current graphics context's user space*. With
        // `isFlipped = true` the y-axis points down, so angle 90 (which
        // mathematically points to +y) draws TOP→BOTTOM, not bottom→top.
        // Bottom scrim wants opaque-at-bottom → angle = -90 (gradient
        // goes upward in screen pixels). Top scrim wants opaque-at-top
        // → angle = 90 (gradient goes downward).
        let angle: CGFloat = edge == .bottom ? -90 : 90
        gradient.draw(in: band, angle: angle)
    }

    private func bandRect() -> NSRect {
        let b = bounds
        let h = min(bandHeight, b.height)
        switch edge {
        case .top:
            return NSRect(x: 0, y: 0, width: b.width, height: h)
        case .bottom:
            return NSRect(x: 0, y: b.height - h, width: b.width, height: h)
        }
    }

    /// Hook for subclasses. Default is a no-op — the gradient paints
    /// over the entire band. `BottomScrimView` overrides this to punch
    /// attach + pill holes via an even-odd clip.
    func applyCutoutClip(ctx: CGContext) {}
}

/// Bottom fade scrim with attach-button + pill cutouts. The two cutout
/// rects are reported by `InputBarView2` in the detail-pane coordinate
/// space (top-left origin, matches this view's `isFlipped = true`
/// bounds since the view is constrained full-bleed to the detail VC's
/// `view`).
@MainActor
final class TranscriptBottomScrimView: TranscriptScrimView {
    /// Attach button rect (a circle inscribed in this rect is punched).
    var attachRect: CGRect = .zero {
        didSet {
            guard attachRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Pill rect (a rounded rectangle with `pillCornerRadius` is punched).
    var pillRect: CGRect = .zero {
        didSet {
            guard pillRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Matches `InputBarView2.cornerRadius`. Hardcoded so the scrim
    /// stays a pure leaf with no upward dependency on the input bar.
    var pillCornerRadius: CGFloat = 16

    init(bandHeight: CGFloat) {
        super.init(edge: .bottom, bandHeight: bandHeight)
    }

    override func applyCutoutClip(ctx: CGContext) {
        guard attachRect != .zero || pillRect != .zero else { return }
        let path = CGMutablePath()
        path.addRect(bounds)
        if attachRect != .zero {
            path.addEllipse(in: attachRect)
        }
        if pillRect != .zero {
            path.addRoundedRect(
                in: pillRect,
                cornerWidth: pillCornerRadius,
                cornerHeight: pillCornerRadius)
        }
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
    }
}

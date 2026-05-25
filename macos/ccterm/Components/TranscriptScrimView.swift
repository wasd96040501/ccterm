import AppKit

/// AppKit-native fade scrim used between the chat transcript and the
/// window chrome (top toolbar / bottom input bar).
///
/// Replaces the prior `NSHostingView<FadeScrim>` overlays because the
/// bottom scrim's attach + pill cutouts needed to live in the same
/// coordinate system as the input bar's reported rects. With the old
/// per-region `NSHostingView`s, each scrim's SwiftUI tree was its own
/// canvas — `.position(x:y:)` on a 160pt-tall canvas couldn't draw a
/// cutout at a y reported in the full detail-pane coord space, so the
/// holes landed off-canvas after #195 split the overlays.
///
/// Drawing in pure `NSView` lets us share the cutout coord space with
/// the AppKit `view` via `convert(_:from:)` from the input bar's host,
/// and lets us style the gradient with `NSGradient` directly (no
/// `LinearGradient` mask + `compositingGroup` round-trip). The view is
/// `isFlipped = true` so SwiftUI's top-left-origin rects map in
/// without manual y inversion, and `hitTest(_:)` returns `nil` so the
/// scrim doesn't absorb clicks within its band — a decorative overlay
/// should never claim mouse events.
@MainActor
class TranscriptScrimView: NSView {
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

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
    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process (macOS 26 libswift_Concurrency
    /// `TaskLocal` teardown bug). See `SessionRuntime.swift`.
    nonisolated deinit {}

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

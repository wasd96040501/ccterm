import AppKit

/// NSScrollView subclass tuned for transcript scrolling.
///
/// - Opts into responsive scrolling so AppKit uses the layer-composite fast
///   path during scroll instead of the synchronous `drawRect` fallback.
/// - Overrides `tile()` to keep `documentView` (the table) sized to the clip
///   width — NSTableView does not auto-size its frame to clip width on its
///   own.
final class Transcript2ScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    /// Force overlay style regardless of the user's "Show scroll bars: Always"
    /// preference. Overriding the property (vs. a one-shot assignment) defends
    /// against the system's `NSPreferredScrollerStyleDidChangeNotification`
    /// resetting it back to legacy when the user toggles the preference.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// Push/pop refcount for hiding the vertical scroller while content
    /// geometry is in flux (initial cold-load, live resize, post-resize
    /// prefetch). Animates `verticalScroller.alphaValue` on 0↔1 transitions.
    /// While count > 0, `flashScrollers()` no-ops so AppKit's auto-flash on
    /// `contentSize` change can't undo our hidden state. Push and pop must
    /// be balanced; pop without a matching push is a logic error.
    private var scrollerHiddenCount: Int = 0

    func pushScrollerHidden() {
        scrollerHiddenCount += 1
        if scrollerHiddenCount == 1 {
            // Instant. Any animation here gives a 150ms window during which
            // the scroller is still partly opaque — and `insertRows` inside
            // `loadInitial` lands in that window, so the scroller pops up
            // visibly before alpha finishes draining.
            verticalScroller?.alphaValue = 0
        }
    }

    func popScrollerHidden() {
        precondition(scrollerHiddenCount > 0,
                     "popScrollerHidden without matching push")
        scrollerHiddenCount -= 1
        if scrollerHiddenCount == 0 {
            // Animate only the fade-in — feels intentional, and there's no
            // race with content layout on the show path.
            guard let scroller = verticalScroller else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                scroller.animator().alphaValue = 1
            }
        }
    }

    override func flashScrollers() {
        guard scrollerHiddenCount == 0 else { return }
        super.flashScrollers()
    }

    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView else { return }
        let target = contentView.bounds.width
        // contentView.bounds.width can briefly be ≤ 0 during scroller layout.
        guard target > 0.5 else { return }
        if abs(table.frame.width - target) > 0.5 {
            table.setFrameSize(NSSize(width: target, height: table.frame.height))
        }
    }
}

/// Layer-backed `.never` clip view. Avoids a `drawRect` pass on every scroll
/// tick — the layer's cached bitmap is composited by the GPU.
final class Transcript2ClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

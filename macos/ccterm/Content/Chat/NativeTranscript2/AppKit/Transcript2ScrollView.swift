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
    /// preference. Overlaid scrollers stay hidden during live resize, which
    /// hides the temporary content-height drift caused by `rebuildVisible`'s
    /// stale off-screen rows. Overriding the property (vs. a one-shot
    /// assignment) defends against the system's
    /// `NSPreferredScrollerStyleDidChangeNotification` resetting the value
    /// back to legacy when the user toggles the preference.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
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

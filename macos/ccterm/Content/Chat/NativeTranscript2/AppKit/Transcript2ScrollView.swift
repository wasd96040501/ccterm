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
            // `setHistory` lands in that window, so the scroller pops up
            // visibly before alpha finishes draining.
            verticalScroller?.alphaValue = 0
        }
    }

    func popScrollerHidden() {
        precondition(
            scrollerHiddenCount > 0,
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
///
/// Also overrides `constrainBoundsRect` so the documentView pins to the
/// **bottom** of the visible content area when the table's actual row
/// extent is shorter than that area. Two reasons to need this:
///
/// 1. Chat-style transcripts: when only one or two messages have arrived,
///    the latest message belongs at the bottom of the viewport with
///    empty space *above* it, not at the top with empty *below*.
/// 2. Anchor stability across Phase B's prepend: without the bottom-pin,
///    Phase A's short content sits at the top (default NSClipView), but
///    once Phase B's prefix lands and the document becomes taller than
///    the viewport, the scrolled-to-bottom view shifts the latest row
///    down — exactly the visible flicker Phase B's `.saveVisible`
///    cannot mask. With the bottom-pin, the latest row sits at the
///    visible content area's bottom in *both* phases; `.saveVisible`
///    preserves zero clip-view-y drift across the prepend.
///
/// Detecting "short content" cannot rely on `documentView.frame.height` —
/// when `NSScrollView.contentInsets` are set, NSScrollView extends the
/// documentView's frame to fill the inset-adjusted region, masking the
/// short-content state. Reach into the NSTableView and ask the last row
/// for its `rect(ofRow:).maxY` instead — the true row extent.
///
/// Paired with `Transcript2Coordinator.scrollRowToBottom`, which no
/// longer clamps its scroll target at `-contentInsets.top`. The pre-fix
/// clamp short-circuited `NSClipView.scroll(to:)` before our override
/// could ever land a negative bounds.origin.y — leaving the table
/// stuck at the top. Both pieces are required together.
final class Transcript2ClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Constrain `bounds.origin.y` so that:
    /// - `min = -contentInsets.top` (first row aligned with the visible
    ///   content area's top edge — same as NSClipView's default).
    /// - `max = actualRowExtent + contentInsets.bottom - clipHeight`
    ///   (last row aligned with the visible content area's bottom edge).
    /// - When `max < min` (actual row extent is shorter than the visible
    ///   content area's height), pin at `max` so the table sticks to
    ///   the visible content area's bottom rather than the clip view's
    ///   top.
    ///
    /// `actualRowExtent` is `tableView.rect(ofRow: numberOfRows-1).maxY`
    /// when the documentView is an NSTableView with rows; otherwise
    /// `documentView.frame.height` (see the class doc for why
    /// `frame.height` doesn't work when contentInsets are non-zero).
    ///
    /// The `x` axis falls through to `super`'s constraint — the table is
    /// width-pinned by `Transcript2ScrollView.tile()`, so horizontal
    /// scrolling never happens.
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var b = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return b }
        let clipH = self.bounds.height
        let topInset: CGFloat
        let bottomInset: CGFloat
        if let scroll = enclosingScrollView {
            topInset = scroll.contentInsets.top
            bottomInset = scroll.contentInsets.bottom
        } else {
            topInset = 0
            bottomInset = 0
        }
        // The documentView's `frame.height` is NOT reliable for detecting
        // "short content" when contentInsets are set: NSScrollView extends
        // the documentView's frame so it fills the inset-adjusted area,
        // so an NSTableView with only a handful of rows still reports
        // `frame.height ≥ clipH - topInset - bottomInset`. Reach into the
        // table to get the *actual* row extent instead — the last row's
        // `maxY` is the sum of all row heights. Falls back to
        // `frame.height` for non-table documentViews and for empty tables.
        let docH: CGFloat
        if let table = doc as? NSTableView, table.numberOfRows > 0 {
            docH = table.rect(ofRow: table.numberOfRows - 1).maxY
        } else {
            docH = doc.frame.height
        }
        let minY: CGFloat = -topInset
        let maxY: CGFloat = docH + bottomInset - clipH
        if maxY < minY {
            // Short-content: actual row extent is less than the visible
            // content area's height. Only one valid position — pin the
            // last row to the visible bottom. Independent of what was
            // proposed: any `scroll(to:)` call lands here.
            b.origin.y = maxY
        } else {
            b.origin.y = max(minY, min(maxY, proposedBounds.origin.y))
        }
        return b
    }
}

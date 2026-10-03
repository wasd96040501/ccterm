import AppKit

/// A scroll view whose scrollers are overlay ones whatever *Show scroll bars*
/// says (a mouse attached means legacy ones), as the design draws every
/// scroller: one never takes width, so what it scrolls never rewraps or
/// narrows when one appears, and nothing beside it loses its edge.
/// Overridden both ways, the AppKit recipe for pinning it: AppKit writes the
/// system's style here whenever the setting changes, and reads it back to
/// decide whether the scroller takes room from the clip view.
class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

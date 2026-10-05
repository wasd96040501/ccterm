import AppKit

/// A scroll view whose scrollers are overlay ones whatever *Show scroll bars*
/// says, for the editor area alone (`design/transcript/README.md`,
/// *Scrollers*): the transcript, the composer and every document, whose lines
/// never rewrap when a scroller appears. Everything else follows the system.
/// Overridden both ways, the AppKit recipe for pinning it: AppKit writes the
/// system's style here whenever the setting changes, and reads it back to
/// decide whether the scroller takes room from the clip view.
package class OverlayScrollView: NSScrollView {
    package override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

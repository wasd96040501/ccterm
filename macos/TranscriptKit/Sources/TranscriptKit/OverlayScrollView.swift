import AppKit

/// The transcript's scroll view, and the one thing it exists to change: its
/// scrollers are **always** overlay ones, whatever the reader's "Show scroll
/// bars" setting says.
///
/// A legacy scroller is a permanent 15-point track carved out of the *inside* of
/// the viewport. Everywhere else on the system that is the correct trade — a
/// list gives up 15 points of a column it owns outright. Here it is not, because
/// the transcript's content is **centred within a maximum width** and the
/// scroller sits at the window's edge, several hundred points away from the
/// column it would be narrowing. The result reads as the document having been
/// shunted off-centre by a control that is nowhere near it, and the wider the
/// window the more obviously wrong it looks. `maxContentWidth` and a legacy
/// scroller are the two halves that do not fit together; an overlay scroller
/// floats over the margin the centring already left, and costs the column
/// nothing.
///
/// This does override an explicit preference, so it is worth being plain about:
/// a reader who set "Always" gets an overlay scroller here regardless. The app's
/// previous renderer (`Transcript2ScrollView`) made the same call for the same
/// reason, and this is parity with it rather than a new position.
///
/// **Overriding the property, not assigning it once.** AppKit re-writes
/// `scrollerStyle` from `NSPreferredScrollerStyleDidChangeNotification`, so a
/// one-shot assignment in the initialiser silently reverts the first time the
/// reader toggles the setting — or plugs in a mouse, which flips the
/// "Automatically based on mouse or trackpad" default to legacy. Intercepting
/// the setter is what makes the pin hold.
///
/// `autohidesScrollers` used to be set here and is deliberately gone: it governs
/// whether a **legacy** scroller is hidden when the content fits, and with the
/// style pinned there is no legacy case left for it to serve. Put it back if the
/// pin ever comes off.
final class OverlayScrollView: NSScrollView {

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

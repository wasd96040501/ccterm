import AppKit

/// The list's clip view. It reports every change of the bounds origin
/// synchronously, so mounting happens in the same turn as the scroll and no
/// row reaches the screen late (SPEC P1).
///
/// Two overrides, because AppKit takes two routes, and neither calls the
/// other (measured): `scroll(to:)` serves the wheel, `scrollToVisible` and
/// `NSView.scroll(_:)`; `setBoundsOrigin(_:)` serves `animator()`. An
/// override rather than `boundsDidChangeNotification`: the notification also
/// fires for size changes, and it takes an observer to tear down.
final class ListClipView: NSClipView {

    /// Weak: the list owns this clip view.
    weak var owner: ListClipViewOwner?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        owner?.clipViewDidScroll(self)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        owner?.clipViewDidScroll(self)
    }
}

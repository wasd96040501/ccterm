import AppKit

/// The clock a motion runs on (SPEC M3, S3): one animatable property that
/// `animator()` drives from 0 to 1.
///
/// AppKit animates a view property it doesn't know through the property's
/// setter, called on the main thread on every display frame with the value
/// already shaped by the group's timing function (measured). So the motion is
/// AppKit's own, with the caller's duration, curve and completion, and what
/// the clock reports each frame is set on the real frames.
///
/// It is a view only because views are what `animator()` animates. It is
/// hidden and has no size; it ticks all the same (measured).
final class MotionClock: NSView {

    /// Every value AppKit sets, the first one included.
    var onTick: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// `p`, from 0 to 1.
    @objc dynamic var progress: CGFloat = 0 {
        didSet { onTick?(progress) }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "progress" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
}

import AppKit
import QuartzCore

/// NSTextField that crossfades its `stringValue` change when the
/// `animated` argument is set. Implemented as an opacity autoreverse:
/// fade out to ~0, swap text, fade back in. Matches the SwiftUI
/// `.contentTransition(.opacity) + .animation(.easeIn, value: title)`
/// the prior sidebar used.
final class CrossfadingTextField: NSTextField {

    private static let halfDuration: TimeInterval = 0.12

    /// Set the field's text, optionally crossfading the transition.
    /// The incoming value is normalized via
    /// `String.collapsedSingleLineForDisplay()` so an upstream title
    /// with embedded newlines / tabs / formatting controls can't blow
    /// the cell past its row height. See the extension's doc comment
    /// for the full sanitization rules.
    func setStringValue(_ value: String, animated: Bool) {
        let sanitized = value.collapsedSingleLineForDisplay()
        guard sanitized != stringValue else { return }
        guard animated, window != nil, !stringValue.isEmpty else {
            stringValue = sanitized
            return
        }
        wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = Self.halfDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.autoreverses = true
        layer?.add(fade, forKey: "crossfade")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.halfDuration) { [weak self] in
            self?.stringValue = sanitized
        }
    }
}

/// Skeleton-loading shimmer painted directly on a host `NSTextField`
/// by installing a `CAGradientLayer` as the field's `layer.mask`. The
/// gradient's alpha stops form an opaque → translucent → opaque band;
/// animating `locations` slides that translucent band horizontally,
/// modulating the text's own alpha. Visually: the title "shimmers"
/// rather than being covered by a reflective stripe.
///
/// This is the canonical CAGradientLayer-mask recipe used by virtually
/// every shimmer library on Apple platforms (and by SwiftUI's
/// `.shimmer` modifiers underneath). Start/stop is idempotent; on
/// `stop` the mask is removed and the field renders normally.
final class ShimmerOverlay {

    static let period: CFTimeInterval = 1.6

    /// Alpha of the dim stripe at the middle of the sweep. Lower =
    /// stronger flash. `0.1` gives a clearly visible pulse without
    /// fully erasing the glyphs as the stripe passes over them.
    private static let dimAlpha: CGFloat = 0.1

    /// `locations` value when the dim stripe is parked off-screen to
    /// the left of the host — i.e. the resting / animation-start state.
    /// Keeping the static `locations` aligned with `animationFrom` is
    /// load-bearing: if they differ, the frame the mask is installed
    /// renders the dim stripe wherever the static `locations` happen
    /// to put it, which is what made the title "half-disappear" before
    /// the animation kicked in.
    private static let animationFrom: [NSNumber] = [0.0, 0.15, 0.3]
    private static let animationTo: [NSNumber] = [0.7, 0.85, 1.0]

    private weak var host: NSTextField?
    private let gradient = CAGradientLayer()
    private var isAnimating = false

    init(host: NSTextField) {
        self.host = host
        host.wantsLayer = true
        configureGradient()
    }

    deinit {
        stop()
    }

    private func configureGradient() {
        // Mask only cares about alpha — RGB is arbitrary, black is
        // cheap. Stops form opaque → translucent → opaque so the dim
        // band can sweep through.
        let opaque = NSColor.black.cgColor
        let dim = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
        gradient.colors = [opaque, dim, opaque]
        gradient.locations = Self.animationFrom
        gradient.startPoint = CGPoint(x: 0.0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
    }

    func start() {
        guard !isAnimating, let host else { return }
        isAnimating = true

        // Force layout so `host.bounds` reflects autolayout's final
        // size before we sample the width for the gradient frame.
        // Without this the gradient often picks up an old / zero size
        // and the sweep covers the wrong region (or nothing at all).
        host.superview?.layoutSubtreeIfNeeded()

        // 3× host width so the `locations` animation can sweep the
        // dim stripe across the visible region with a smooth in-and-
        // out cycle. Frame origin starts one host-width to the left
        // so the first sweep enters from off-screen instead of
        // popping in.
        let w = host.bounds.width
        let h = host.bounds.height
        gradient.frame = CGRect(x: -w, y: 0, width: 3 * w, height: h)
        host.layer?.mask = gradient

        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = Self.animationFrom
        anim.toValue = Self.animationTo
        anim.duration = Self.period
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        gradient.add(anim, forKey: "shimmer")
    }

    func stop() {
        guard isAnimating else { return }
        isAnimating = false
        gradient.removeAllAnimations()
        host?.layer?.mask = nil
    }
}

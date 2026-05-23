import AppKit
import QuartzCore

/// NSTextField that crossfades its `stringValue` change when the
/// `animated` argument is set. Implemented as an opacity autoreverse:
/// fade out to ~0, swap text, fade back in. Matches the SwiftUI
/// `.contentTransition(.opacity) + .animation(.easeIn, value: title)`
/// the prior sidebar used.
final class CrossfadingTextField: NSTextField {

    private static let halfDuration: TimeInterval = 0.12

    func setStringValue(_ value: String, animated: Bool) {
        // `usesSingleLineMode = true` on NSTextField / NSTextFieldCell
        // changes input layout — it does NOT strip embedded newlines
        // from a string assigned via `stringValue`. A session title
        // derived from a multi-paragraph first user message will carry
        // real `\n` characters; without collapsing them here, every
        // newline blows the cell past its `heightOfRowByItem` height
        // and the row overlaps its neighbors.
        let sanitized = Self.collapseLineBreaks(value)
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

    /// Replace any sequence of `\n` / `\r` (and stray U+2028 / U+2029
    /// line / paragraph separators that occasionally slip through
    /// Chinese punctuation handling) with single spaces.
    private static func collapseLineBreaks(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }
}

/// Sweeping-highlight shimmer painted on top of a host text field.
/// Implemented as a sibling overlay view (above the text field within
/// the same superview) carrying a `CAGradientLayer` that animates its
/// horizontal `transform.translation.x` back and forth. Start/stop is
/// idempotent.
///
/// Constants (`period`, alpha stops) match the prior SwiftUI
/// `ShimmerModifier` so the visual rhythm is unchanged.
final class ShimmerOverlay {

    static let period: CFTimeInterval = 1.6

    private weak var host: NSTextField?
    private let overlay = NSView()
    private let gradient = CAGradientLayer()
    private var isAnimating = false

    init(host: NSTextField) {
        self.host = host
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        overlay.layer?.addSublayer(gradient)
        overlay.isHidden = true
        if let superview = host.superview {
            superview.addSubview(overlay, positioned: .above, relativeTo: host)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: host.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        configureGradient()
    }

    deinit {
        overlay.removeFromSuperview()
    }

    private func configureGradient() {
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.5).cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.locations = [0.0, 0.5, 1.0]
        gradient.startPoint = CGPoint(x: 0.0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
    }

    func start() {
        guard !isAnimating else { return }
        isAnimating = true
        overlay.isHidden = false
        overlay.layoutSubtreeIfNeeded()
        gradient.frame = overlay.bounds
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -overlay.bounds.width
        anim.toValue = overlay.bounds.width
        anim.duration = Self.period
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        gradient.add(anim, forKey: "shimmer")
    }

    func stop() {
        guard isAnimating else { return }
        isAnimating = false
        gradient.removeAllAnimations()
        overlay.isHidden = true
    }
}

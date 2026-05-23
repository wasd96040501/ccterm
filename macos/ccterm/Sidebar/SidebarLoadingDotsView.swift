import AppKit
import QuartzCore

/// Three dots that pulse one-after-the-other left-to-right, then
/// rest for a beat before repeating — the "typing indicator" rhythm.
///
/// Each dot gets its own `CAKeyframeAnimation` on `opacity` whose
/// whole cycle is the same `cycleDuration`. The differences live in
/// `keyTimes`: each dot's "dim then restore" window sits in a
/// different third of the cycle's first half, and the cycle's second
/// half is held at full opacity for every dot — that flat tail is
/// what gives the animation its breath-and-rest feel rather than a
/// continuous wave.
///
/// Using a keyframe animation (instead of `autoreverses` +
/// `beginTime` staggering) keeps every dot on the same shared cycle,
/// so the pause is genuinely a pause for all three at once.
final class SidebarLoadingDotsView: NSView {

    static let dotSize: CGFloat = 3
    static let dotGap: CGFloat = 1.5
    /// Full cycle including the post-sweep pause (seconds).
    static let cycleDuration: Double = 1.8
    /// How long each individual dot's dim → restore takes.
    static let dotActiveDuration: Double = 0.35
    /// Floor opacity at each dot's trough — keeps the trough visible
    /// in dark mode without dropping below ~1.6:1 contrast.
    static let dimAlpha: Float = 0.35

    private var dotLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        buildDots()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachBreath()
        } else {
            detachBreath()
        }
    }

    override func layout() {
        super.layout()
        let totalWidth = Self.dotSize * 3 + Self.dotGap * 2
        let startX = (bounds.width - totalWidth) / 2
        let y = (bounds.height - Self.dotSize) / 2
        for (idx, dot) in dotLayers.enumerated() {
            let x = startX + CGFloat(idx) * (Self.dotSize + Self.dotGap)
            dot.frame = CGRect(x: x, y: y, width: Self.dotSize, height: Self.dotSize)
        }
        applyDotColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
    }

    private func buildDots() {
        for _ in 0..<3 {
            let dot = CALayer()
            dot.cornerRadius = Self.dotSize / 2
            dotLayers.append(dot)
            layer?.addSublayer(dot)
        }
        applyDotColor()
    }

    private func applyDotColor() {
        var resolved: CGColor = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.cgColor
        }
        for dot in dotLayers { dot.backgroundColor = resolved }
    }

    private func attachBreath() {
        let now = CACurrentMediaTime()
        for (idx, dot) in dotLayers.enumerated() {
            // Each dot's dim window slots into a different third at
            // the front of the cycle; the tail of the cycle is held
            // flat at 1.0 across all dots, producing the "pause" beat.
            let baseStart = Double(idx) * Self.dotActiveDuration
            // `keyTimes` must be strictly monotonically increasing —
            // bump `idx == 0`'s start off zero by a frame's-worth so
            // it doesn't collide with the leading `0.0` keyTime.
            let activeStart = max(1.0 / 60.0, baseStart) / Self.cycleDuration
            let activeMid = (baseStart + Self.dotActiveDuration / 2) / Self.cycleDuration
            let activeEnd = (baseStart + Self.dotActiveDuration) / Self.cycleDuration

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [1.0, 1.0, Self.dimAlpha, 1.0, 1.0]
            anim.keyTimes =
                [
                    0.0,
                    activeStart,
                    activeMid,
                    activeEnd,
                    1.0,
                ] as [NSNumber]
            anim.duration = Self.cycleDuration
            anim.repeatCount = .infinity
            anim.calculationMode = .cubic
            // Sync all three dots to the same wall-clock phase so the
            // cycle stays in lockstep across cell reuse / remount.
            anim.beginTime = now - now.truncatingRemainder(dividingBy: Self.cycleDuration)
            dot.add(anim, forKey: "breath")
        }
    }

    private func detachBreath() {
        for dot in dotLayers { dot.removeAnimation(forKey: "breath") }
    }
}

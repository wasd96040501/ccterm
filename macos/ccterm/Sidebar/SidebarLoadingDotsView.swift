import AppKit
import QuartzCore

/// AppKit port of the prior SwiftUI `SidebarLoadingDots`: three small
/// dots whose opacities cycle in a left-to-right wave. The frame timer
/// is `NSView.displayLink(target:selector:)` so the cadence matches the
/// host display; opacities are sampled from the absolute wall-clock
/// (`Date.timeIntervalSinceReferenceDate`), so multiple instances —
/// including the transcript's pill — breathe in lockstep.
///
/// Timing constants (`period`, `phaseStagger`, geometry) are copied
/// verbatim from the prior SwiftUI implementation so the visual rhythm
/// is unchanged.
final class SidebarLoadingDotsView: NSView {

    static let dotSize: CGFloat = 3
    static let dotGap: CGFloat = 1.5
    /// Full breath cycle (seconds).
    static let period: Double = 1.2
    /// Per-dot phase offset.
    static let phaseStagger: Double = 0.18
    /// Floor opacity — keeps the breath visible in dark mode without
    /// dropping below ~1.6:1 contrast at the trough.
    static let minOpacity: Double = 0.45

    private var dotLayers: [CALayer] = []
    private var displayLink: CADisplayLink?

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
            startAnimating()
        } else {
            stopAnimating()
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

    private func startAnimating() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Paint one frame immediately so the dots aren't all at the
        // floor opacity until the first vsync arrives.
        tick()
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick(_ sender: CADisplayLink) {
        tick()
    }

    private func tick() {
        let t = Date().timeIntervalSinceReferenceDate
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (idx, dot) in dotLayers.enumerated() {
            dot.opacity = Float(Self.opacity(at: t, staggerIndex: idx))
        }
        CATransaction.commit()
    }

    /// Smooth sine breath in `[minOpacity, 1]`. Per-dot `staggerIndex`
    /// shifts the phase so the wave crest sweeps left-to-right.
    static func opacity(at time: Double, staggerIndex: Int) -> Double {
        let shifted = time - Double(staggerIndex) * phaseStagger
        let normalized = shifted.truncatingRemainder(dividingBy: period) / period
        let nonNegative = normalized < 0 ? normalized + 1 : normalized
        let s = (1 - cos(2 * .pi * nonNegative)) / 2
        return minOpacity + (1 - minOpacity) * s
    }
}

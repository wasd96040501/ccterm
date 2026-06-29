import AppKit

/// AppKit replacement for the (now-deleted) SwiftUI `ProgressRingView`
/// (migration plan §4.2, §4.8). A
/// layer-backed `NSView` that draws the input bar's context-usage ring: a
/// full-circle gray **track** behind a trimmed **progress** arc whose end
/// maps from `percent` (0..100), color-stepping accent → orange → red as the
/// session nears the cap.
///
/// This is a 1:1 geometry/color relocation of the original SwiftUI ring, not a
/// redesign — every constant is reused verbatim
/// (`lineWidth = 2`, `size = 12`, thresholds `[(70, accent), (90, orange),
/// (100, red)]`, track `separatorColor`, round progress cap, -90° start, 0.4s
/// easeInOut animation). The SwiftUI `ProgressRingView` was deleted in Phase 5,
/// so this AppKit `NSView` now carries the bare name. The only observable
/// surface is the rendered geometry + color, driven by the `percent` setter.
///
/// Structure (mirrors SwiftUI's `ZStack` of two `Circle`s):
///
/// ```
/// ProgressRingView (NSView, wantsLayer)
/// ├─ trackLayer    (CAShapeLayer — full circle, separatorColor, butt cap)
/// └─ progressLayer (CAShapeLayer — same circle path trimmed to strokeEnd,
///                   ringColor, round cap, ON TOP)
/// ```
///
/// **Why a path that starts at -90°** rather than `layer.transform`:
/// SwiftUI `.rotationEffect(.degrees(-90))` makes the arc begin at 12
/// o'clock. We build the circle CGPath from -90° sweeping clockwise, which
/// matches that visual without any `anchorPoint` / `position` transform
/// bookkeeping. A naive CGPath arc would start at 3 o'clock and a 30% ring
/// would grow from the right (a visible parity regression).
///
/// **Stroke centering**: the path radius is `(min(w,h) - lineWidth) / 2`,
/// centered in `bounds`, so the stroke band straddles the inscribed circle of
/// the frame exactly like SwiftUI `Circle().stroke` — it never clips at the
/// bounds edges. The path centers in `bounds` (not in `size`) so the ring
/// survives the `.frame(22, 22)` wrap of a size-12 ring at the call site
/// (`ContextRingButton.swift:19`); `intrinsicContentSize` still publishes
/// `size × size` so it sizes itself in an `NSStackView`.
final class ProgressRingView: NSView {

    // MARK: - Constants (verbatim from ProgressRingView.swift)

    /// Default stroke width (`ProgressRingView.swift:10`).
    static let defaultLineWidth: CGFloat = 2.0

    /// Default square side (`ProgressRingView.swift:11`).
    static let defaultSize: CGFloat = 12.0

    /// `easeInOut` / 0.4s, keyed on `percent` (`ProgressRingView.swift:25`).
    static let animationDuration: CFTimeInterval = 0.4

    /// Default threshold ladder (`ProgressRingView.swift:12`). AppKit color
    /// mapping: `accentColor → controlAccentColor`, `orange → systemOrange`,
    /// `red → systemRed`.
    static func defaultColorThresholds() -> [(Double, NSColor)] {
        [(70, .controlAccentColor), (90, .systemOrange), (100, .systemRed)]
    }

    // MARK: - Public

    /// Raw 0..100 context-usage value. The caller keeps fractional precision
    /// (`ContextRingButton.swift:36-41`) so the arc moves smoothly between
    /// integer ticks; rounding happens only in the label / a11y, out of this
    /// component's scope. Setting this animates `strokeEnd` over 0.4s
    /// easeInOut — **only** on a real change (matching SwiftUI
    /// `.animation(value: percent)`); geometry / appearance updates never
    /// animate the arc.
    var percent: Double {
        didSet {
            guard percent != oldValue else { return }
            updateStrokeEnd(animated: true)
        }
    }

    /// Stroke width applied to **both** layers (`ProgressRingView.swift:10`).
    var lineWidth: CGFloat {
        didSet {
            guard lineWidth != oldValue else { return }
            trackLayer.lineWidth = lineWidth
            progressLayer.lineWidth = lineWidth
            needsLayout = true
        }
    }

    /// The square side the view publishes as its `intrinsicContentSize`
    /// (`ProgressRingView.swift:11`, or `22` at the popover summary call site
    /// `ContextRingButton.swift:99`). The *path* still centers in `bounds`, so
    /// this only governs self-sizing, not the ring geometry.
    var size: CGFloat {
        didSet {
            guard size != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    /// Threshold ladder for the progress color. `(threshold, color)` pairs in
    /// ascending order; the first pair whose threshold strictly exceeds
    /// `percent` wins, else the last (`ProgressRingView.swift:28-33`).
    var colorThresholds: [(Double, NSColor)] {
        didSet { applyRingColor() }
    }

    // MARK: - Layers

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    /// The last `NSColor` selected from the threshold ladder (pre-appearance
    /// resolve). Used to gate the band crossfade so an intra-band percent move
    /// (e.g. 30→35, both accent) does NOT kick a spurious 0.4s color animation
    /// — SwiftUI re-derives `ringColor` per body too but assigns the same
    /// `Color`, so no crossfade runs within a band. `nil` until the first
    /// `applyRingColor()`.
    private var lastBandColor: NSColor?

    // MARK: - Init

    init(
        percent: Double = 0,
        lineWidth: CGFloat = ProgressRingView.defaultLineWidth,
        size: CGFloat = ProgressRingView.defaultSize,
        colorThresholds: [(Double, NSColor)] = ProgressRingView.defaultColorThresholds()
    ) {
        self.percent = percent
        self.lineWidth = lineWidth
        self.size = size
        self.colorThresholds = colorThresholds
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Track first (behind), progress on top — mirrors the SwiftUI ZStack
        // order (ProgressRingView.swift:15-23).
        trackLayer.fillColor = nil
        trackLayer.lineWidth = lineWidth
        // SwiftUI `Circle().stroke` with no explicit lineCap defaults to butt.
        trackLayer.lineCap = .butt

        progressLayer.fillColor = nil
        progressLayer.lineWidth = lineWidth
        progressLayer.lineCap = .round  // ProgressRingView.swift:21
        progressLayer.strokeStart = 0  // trim from: 0 (ProgressRingView.swift:20)

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(progressLayer)

        applyContentsScale()
        applyTrackColor()
        // Seed strokeEnd + band color without animation — the initial percent
        // is geometry, not a user-driven change. `updateStrokeEnd(animated:
        // false)` calls `applyRingColor()` (which seeds `lastBandColor`) inside
        // a disabled transaction, so no separate `applyRingColor()` is needed.
        updateStrokeEnd(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit` so the
    /// `@MainActor` deinit executor hop doesn't abort under
    /// `libswift_Concurrency`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; no production consumers)
    //
    // These getters expose resolved layer state so the CI-gate tests can
    // assert the fraction→strokeEnd mapping, the lineWidth wiring, the path
    // centering, and the cgColor re-resolve against the real production
    // object. They are read-only and have no production callers; nothing
    // wires the ring through them.

    /// The trimmed progress arc's `strokeEnd` (== clamped `percent` / 100).
    var resolvedStrokeEnd: CGFloat { progressLayer.strokeEnd }

    /// The progress arc's resolved stroke color. Re-resolved on appearance
    /// flip; readable so tests can confirm the cgColor tracks the appearance.
    var resolvedProgressStrokeColor: CGColor? { progressLayer.strokeColor }

    /// The track's resolved stroke color (`separatorColor`).
    var resolvedTrackStrokeColor: CGColor? { trackLayer.strokeColor }

    /// The current line width on the track layer.
    var resolvedTrackLineWidth: CGFloat { trackLayer.lineWidth }

    /// The current line width on the progress layer.
    var resolvedProgressLineWidth: CGFloat { progressLayer.lineWidth }

    /// The shared circle path's bounding box (after `layout()`), in the
    /// view's coordinate space. Centers in `bounds`, inset by `lineWidth/2`.
    var resolvedRingPathBoundingBox: CGRect? { progressLayer.path?.boundingBox }

    /// The **track** layer's path bounding box. The track and progress layers
    /// are assigned the same `CGPath`, so this must equal
    /// `resolvedRingPathBoundingBox` — exposed so a test can prove the
    /// shared-path contract directly rather than inferring it.
    var resolvedTrackPathBoundingBox: CGRect? { trackLayer.path?.boundingBox }

    /// The progress arc's resolved round line cap.
    var resolvedProgressLineCap: CAShapeLayerLineCap { progressLayer.lineCap }

    /// The currently-installed `strokeColor` animation on the progress layer,
    /// if any. Exposed read-only so a test can prove the band crossfade rides
    /// the same 0.4s easeInOut as `strokeEnd` on a band-crossing percent change
    /// (and is absent on an intra-band move / init / appearance flip), matching
    /// SwiftUI's `.animation(.easeInOut(0.4), value: percent)`.
    var resolvedStrokeColorAnimation: CABasicAnimation? {
        progressLayer.animation(forKey: "strokeColor") as? CABasicAnimation
    }

    /// The currently-installed `strokeEnd` animation on the progress layer, if
    /// any (the arc-grow tween).
    var resolvedStrokeEndAnimation: CABasicAnimation? {
        progressLayer.animation(forKey: "strokeEnd") as? CABasicAnimation
    }

    // MARK: - Pure color selection (lifted from ProgressRingView.swift:28-33)

    /// Select the progress color for `percent` from an ascending
    /// `(threshold, color)` ladder: the first pair whose threshold **strictly
    /// exceeds** `percent`, else the last pair's color (else
    /// `controlAccentColor` for an empty ladder). Ported verbatim from
    /// `ProgressRingView.ringColor` so `[0,70) → accent`, `[70,90) → orange`,
    /// `[90,100] → red` (100 is NOT `< 100`, so it falls through to the last
    /// pair = red).
    static func ringColor(percent: Double, thresholds: [(Double, NSColor)]) -> NSColor {
        for (threshold, color) in thresholds where percent < threshold {
            return color
        }
        return thresholds.last?.1 ?? .controlAccentColor
    }

    /// The fraction→`strokeEnd` mapping: clamp `percent` to `[0, 100]` then
    /// divide by 100 (`ProgressRingView.swift:20` — clamp BEFORE divide).
    static func strokeEnd(for percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Geometry write — recompute the shared circle path for the settled
        // bounds. Wrapped in a disabled transaction so a resize never
        // crossfades the path / re-animates the arc (the only animation is the
        // percent-driven strokeEnd in `updateStrokeEnd`).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = ringPath(in: bounds)
        trackLayer.frame = bounds
        progressLayer.frame = bounds
        trackLayer.path = path
        progressLayer.path = path
        CATransaction.commit()
    }

    /// The shared circle CGPath: centered in `bounds`, radius inset by
    /// `lineWidth/2` so the stroke band stays inside the frame, built from
    /// -90° (12 o'clock) sweeping clockwise so the arc grows from the top.
    private func ringPath(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(0, (min(rect.width, rect.height) - lineWidth) / 2)
        let path = CGMutablePath()
        // Start at 12 o'clock (-90° = .pi * 1.5 in standard math angle on a
        // non-flipped layer where +y is up), sweep clockwise back to the top.
        // `clockwise: true` in CG layer space (y-up) traces top → right →
        // bottom → left, matching SwiftUI's trim direction after the -90°
        // rotation.
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi,
            clockwise: true)
        return path
    }

    // MARK: - Sizing

    /// Publish `size × size` so the ring self-sizes in an `NSStackView`
    /// (matching SwiftUI `.frame(width: size, height: size)`). The path still
    /// centers in `bounds`, so a larger frame (the `.frame(22, 22)` wrap)
    /// keeps the ring centered.
    override var intrinsicContentSize: NSSize {
        NSSize(width: size, height: size)
    }

    // MARK: - Appearance / backing re-resolve

    /// `CALayer.cgColor` does **not** auto-update on a dark/light (or accent)
    /// flip; SwiftUI did this free (plan §4.2-3, R14). Re-resolve the track +
    /// progress colors against the new appearance, wrapped so the color swap
    /// doesn't crossfade. The progress color may be `controlAccentColor`, so
    /// it must re-resolve too.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyTrackColor()
        applyRingColor()
        CATransaction.commit()
    }

    /// Keep the stroke crisp across Retina↔non-Retina by tracking the window
    /// backing scale on each shape layer (plan §4.2-3 Retina).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    // MARK: - Apply helpers

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        trackLayer.contentsScale = scale
        progressLayer.contentsScale = scale
    }

    /// Resolve the track color (`separatorColor`, full circle —
    /// `ProgressRingView.swift:17`) against the current appearance.
    private func applyTrackColor() {
        var resolved: CGColor = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.cgColor
        }
        trackLayer.strokeColor = resolved
    }

    /// Resolve the progress color from the threshold ladder against the
    /// current appearance.
    ///
    /// When `animateBandChange` is true (the percent-driven path) AND the
    /// selected band color actually changed, the `strokeColor` swap rides a
    /// `CABasicAnimation` matching `strokeEnd`'s 0.4s easeInOut — this is the
    /// AppKit equivalent of SwiftUI's `.animation(.easeInOut(0.4), value:
    /// percent)` animating both the trim and the `ringColor` crossfade in one
    /// pass. An intra-band move (same color) takes the synchronous, disabled
    /// write so it never spuriously crossfades (matching SwiftUI re-deriving
    /// the same `Color`). Geometry / appearance-flip re-resolves always pass
    /// `animateBandChange: false` (wrapped by their own disabled transaction).
    private func applyRingColor(animateBandChange: Bool = false) {
        let nsColor = Self.ringColor(percent: percent, thresholds: colorThresholds)
        var resolved: CGColor = nsColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.cgColor
        }
        let bandChanged = nsColor != lastBandColor
        lastBandColor = nsColor

        if animateBandChange && bandChanged {
            let anim = CABasicAnimation(keyPath: "strokeColor")
            anim.fromValue = progressLayer.presentation()?.strokeColor ?? progressLayer.strokeColor
            anim.toValue = resolved
            anim.duration = Self.animationDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.add(anim, forKey: "strokeColor")
        }
        progressLayer.strokeColor = resolved
    }

    /// Map `percent` → `strokeEnd`, re-resolve the color (the band may have
    /// changed), and animate **both** `strokeEnd` and the band crossfade over
    /// 0.4s easeInOut **only** when `animated` (the percent didSet) — matching
    /// SwiftUI's `.animation(.easeInOut(0.4), value: percent)`, which animates
    /// the trim and the `ringColor` crossfade in the same pass. Geometry /
    /// appearance writes pass `animated: false` so neither the arc nor the
    /// color re-animates on resize/flip.
    private func updateStrokeEnd(animated: Bool) {
        let target = Self.strokeEnd(for: percent)
        if animated {
            // Color crossfade rides the same 0.4s easeInOut (gated on a real
            // band change inside applyRingColor).
            applyRingColor(animateBandChange: true)
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
            anim.toValue = target
            anim.duration = Self.animationDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.add(anim, forKey: "strokeEnd")
            progressLayer.strokeEnd = target
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyRingColor()
            progressLayer.strokeEnd = target
            CATransaction.commit()
        }
    }
}

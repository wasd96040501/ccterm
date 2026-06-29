import AppKit

/// AppKit replacement for the SwiftUI `TodoStatusGlyph`
/// (`Content/Chat/InputBarControls/TodoStatusGlyph.swift`; migration plan
/// §4.2, §8 R17/R18). A layer-backed `NSView` with **one** `CAShapeLayer`
/// reconfigured per state via `setState(_:muted:)`. Three states, all drawn
/// at the **same outer footprint** so a status flip never shifts the row's
/// leading edge:
///
///   - `.pending` — plain hollow ring (`strokeBorder`, stroke inset to stay
///     inside the frame).
///   - `.inProgress` (non-muted) — dotted hollow ring + a `transform.rotation.z`
///     spin (one revolution / 6s) so it reads as "still working".
///   - `.inProgress` (muted) — identical to `.pending`: plain ring, no dash,
///     no rotation. The chrome leading icon passes `muted: true` so it stays
///     quiet; the live verb lives only in the popover (`muted == false`).
///   - `.completed` — hollow ring + concentric filled inner dot, drawn as a
///     **single even-odd filled path** (outer disc − inner hole + inner dot)
///     so the ring band and the dot share one rasterizer pass.
///
/// This is a 1:1 geometry/color relocation of the original SwiftUI glyph, not a
/// redesign — every constant (`strokeWidth = 1.4`, `dotScale = 0.62`, the
/// 6s linear rotation, the `[0, strokeWidth * 2.2]` dash, the three-ellipse
/// even-odd winding, the muted semantics) is reused verbatim. Named
/// `TodoStatusGlyphView` to follow the plan's `ProgressRingView` /
/// `ContextBarView` naming for the layer-backed AppKit leaves. The SwiftUI
/// `TodoStatusGlyph` was deleted in Phase 5, so this AppKit `NSView` now
/// carries the bare name. No production wiring lands in this phase (Phase 0,
/// standalone component); the owning todo row / chrome button drives it via
/// `setState(_:muted:)` later (Phase 1).
///
/// ## strokeBorder vs stroke (footprint trap)
///
/// SwiftUI's `Circle().strokeBorder(_, lineWidth:)` strokes **inside** the
/// frame, so all three states share one outer footprint. A naive
/// `CGPath(ellipseIn: bounds)` + `lineWidth` strokes **centered** on the
/// edge and bleeds `lineWidth/2` outside the frame. We reproduce
/// `strokeBorder` by insetting the ring path by `strokeWidth/2` on every
/// edge — `bounds.insetBy(dx: 0.7, dy: 0.7)` for `strokeWidth = 1.4`.
final class TodoStatusGlyphView: NSView {

    // MARK: - Constants (verbatim from TodoStatusGlyph.swift)

    /// Solid stroke width (`TodoStatusGlyph.swift:32`). The smallest weight
    /// that survives sub-pixel rasterization at 10–14pt without softening.
    static let strokeWidth: CGFloat = 1.4

    /// Inner-dot diameter as a fraction of the bounding box
    /// (`TodoStatusGlyph.swift:91`, `CompletedRingAndDotShape.dotScale`).
    static let dotScale: CGFloat = 0.62

    /// Rotation duration — one revolution every 6 seconds, `.linear`,
    /// repeats forever (`TodoStatusGlyph.swift:130`).
    static let rotationDuration: CFTimeInterval = 6.0

    /// Dash gap multiplier (`TodoStatusGlyph.swift:125`,
    /// `dash: [0, strokeWidth * 2.2]`). A zero-length dash with a round cap
    /// renders as a dot.
    static let dashGapMultiplier: CGFloat = 2.2

    /// Key under which the rotation `CABasicAnimation` is installed; used to
    /// add / remove it on every `setState` so a recycled-in-place row never
    /// keeps a stale spinner.
    static let rotationAnimationKey = "todoStatusGlyphRotation"

    // MARK: - State

    /// The current logical state. Mutated only through `setState(_:muted:)`.
    private(set) var status: TodoEntry.Status
    /// Quiet variant: `inProgress` renders as a plain grey ring (identical to
    /// `pending`) with no rotation. Default `false` (`TodoStatusGlyph.swift:27`).
    private(set) var muted: Bool

    /// The single shape layer, reconfigured per state — never recreated
    /// (recycle-in-place; matches the chrome-row reuse the plan calls out).
    private let shapeLayer = CAShapeLayer()

    /// `true` iff the live, rotating dotted ring should be shown — the strict
    /// predicate the rotation + dash lifecycle is keyed on (plan §4.2-6, R17).
    private var showsLiveSpinner: Bool { status == .inProgress && !muted }

    // MARK: - Init

    init(status: TodoEntry.Status = .pending, muted: Bool = false) {
        self.status = status
        self.muted = muted
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Decorative: the owning row / button supplies the a11y label
        // (`TodoStatusGlyph.swift:54` set `.accessibilityHidden(true)`).
        setAccessibilityElement(false)

        shapeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(shapeLayer)

        applyContentsScale()
        // Build the initial state's path/fill/stroke (no animation yet — the
        // window isn't attached, but the predicate-keyed lifecycle is honored:
        // a non-muted inProgress seed installs the rotation immediately).
        reconfigure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit` so the
    /// `@MainActor` deinit executor hop doesn't abort under
    /// `libswift_Concurrency`. The rotation animation has
    /// `isRemovedOnCompletion = false` but is torn down with the layer when
    /// the view deallocates — no timer / `NSEvent` monitor to invalidate here.
    nonisolated deinit {}

    // MARK: - Public API

    /// Imperative state entry point (plan §4.2-6: "a `setState(_:muted:)`
    /// method removes/re-adds it"). Rebuilds the shape layer's path / fill /
    /// stroke for the new `(status, muted)` and adds-or-removes the rotation
    /// animation keyed strictly on `status == .inProgress && !muted`.
    /// Idempotent for the same `(status, muted)`.
    func setState(_ status: TodoEntry.Status, muted: Bool) {
        guard status != self.status || muted != self.muted else { return }
        self.status = status
        self.muted = muted
        reconfigure()
    }

    // MARK: - Test-observation points (read-only; no production consumers)
    //
    // These getters expose resolved layer state so the CI-gate tests can
    // assert the even-odd fill rule, the rotation / dash lifecycle, the
    // per-state stroke geometry, and the cgColor re-resolve against the real
    // production object. Read-only; nothing wires the glyph through them.

    /// The fill rule on the shape layer — must be `.evenOdd` for the
    /// completed glyph (R18: the default `.nonZero` regresses to a solid disc).
    var resolvedFillRule: CAShapeLayerFillRule { shapeLayer.fillRule }

    /// The shape layer's resolved fill color (set for the completed glyph,
    /// `nil`/clear for the ring states).
    var resolvedFillColor: CGColor? { shapeLayer.fillColor }

    /// The shape layer's resolved stroke color (set for the ring states,
    /// `nil`/clear for the completed glyph).
    var resolvedStrokeColor: CGColor? { shapeLayer.strokeColor }

    /// The shape layer's line width (1.4 for ring states, 0 for completed).
    var resolvedLineWidth: CGFloat { shapeLayer.lineWidth }

    /// The shape layer's line cap (`.round` for the dotted ring).
    var resolvedLineCap: CAShapeLayerLineCap { shapeLayer.lineCap }

    /// The dash pattern (`[0, 3.08]` for the live dotted ring; `nil` / empty
    /// otherwise). Present iff `inProgress && !muted`.
    var resolvedLineDashPattern: [NSNumber]? { shapeLayer.lineDashPattern }

    /// The shape layer's current path (for bbox / sub-path counting).
    var resolvedPath: CGPath? { shapeLayer.path }

    /// The shape layer (identity check — one instance reused across states).
    var resolvedShapeLayer: CAShapeLayer { shapeLayer }

    /// The installed rotation animation, if any (present iff the live-spinner
    /// predicate holds).
    var resolvedRotationAnimation: CABasicAnimation? {
        shapeLayer.animation(forKey: Self.rotationAnimationKey) as? CABasicAnimation
    }

    /// The resolved color the active state would paint with, against the
    /// current `effectiveAppearance`. Exposed so a test can assert the
    /// accent / secondary mapping without re-implementing it.
    var resolvedActiveColor: CGColor { resolvedColor(for: stateColor) }

    /// Count of distinct sub-paths in the current path (number of `moveTo`
    /// elements). The completed glyph has exactly 3 (three ellipses).
    var resolvedSubpathCount: Int {
        guard let path = shapeLayer.path else { return 0 }
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { count += 1 }
        }
        return count
    }

    // MARK: - Pure geometry (lifted from CompletedRingAndDotShape / strokeBorder)

    /// The inset ring path reproducing SwiftUI `strokeBorder`: an ellipse
    /// inscribed in `rect` then inset by `strokeWidth/2` on each edge so the
    /// stroke stays **inside** the frame. Shared by `.pending`, muted
    /// `.inProgress`, and the live dotted `.inProgress` ring.
    static func ringPath(in rect: CGRect) -> CGPath {
        let inset = strokeWidth / 2
        return CGPath(ellipseIn: rect.insetBy(dx: inset, dy: inset), transform: nil)
    }

    /// The completed donut + concentric dot as one path — three ellipses in
    /// the exact order from `CompletedRingAndDotShape.path(in:)`
    /// (`TodoStatusGlyph.swift:93-105`): (1) outer disc, (2) ring inner edge
    /// inset by `strokeWidth`, (3) inner dot of diameter `min(w,h) * dotScale`.
    /// Combined with `fillRule = .evenOdd`: outside outer = 0 (skip), ring
    /// band = 1 (fill), inner hole = 2 (skip), inner dot = 3 (fill).
    static func completedPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: rect)
        path.addEllipse(in: rect.insetBy(dx: strokeWidth, dy: strokeWidth))
        let dotSize = min(rect.width, rect.height) * dotScale
        let dotRect = CGRect(
            x: rect.midX - dotSize / 2,
            y: rect.midY - dotSize / 2,
            width: dotSize,
            height: dotSize)
        path.addEllipse(in: dotRect)
        return path
    }

    /// The dash pattern for the live dotted ring (`[0, strokeWidth * 2.2]`).
    static func dashPattern() -> [NSNumber] {
        [0, NSNumber(value: Double(strokeWidth * dashGapMultiplier))]
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Geometry write — re-fit the shape layer + path to the settled
        // bounds, and re-center the anchor so the rotation spins about the
        // center (not orbits). Wrapped in a disabled transaction so a resize
        // never crossfades the path.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        shapeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        applyPath()
        CATransaction.commit()
    }

    // MARK: - Sizing

    /// The caller pins width/height via constraints (matching the SwiftUI
    /// `.frame(width:height:)` at `TodoList.swift:47` / `TodoButton.swift:53`);
    /// the leaf re-paths in `layout()`, so it publishes no intrinsic metric.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Appearance / backing re-resolve

    /// `CALayer.cgColor` does **not** auto-update on a dark/light or accent
    /// flip; SwiftUI did this free (plan §4.2-3, R14). Re-resolve the active
    /// state's color against the new appearance, wrapped so the color swap
    /// doesn't crossfade. The non-muted `inProgress` color is
    /// `controlAccentColor`, so it must re-resolve too.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColor()
        CATransaction.commit()
    }

    /// Keep the vector stroke / fill crisp across Retina↔non-Retina by
    /// tracking the window backing scale (plan §4.2-3 Retina; mirrors
    /// `BlockCellView.viewDidChangeBackingProperties`). `CAShapeLayer` is
    /// vector, so updating `contentsScale` re-strokes at the new density.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    /// Re-assert the rotation on every window attach — the AppKit equivalent
    /// of SwiftUI `RotatingDottedRing.onAppear` (`TodoStatusGlyph.swift:129`).
    ///
    /// Core Animation strips a layer's animations when the layer leaves the
    /// window/layer tree; `isRemovedOnCompletion = false` only persists the
    /// spin across implicit-transaction completion on a layer that **stays**
    /// in the tree — it does NOT survive a detach + reattach. The live
    /// spinner's production host (Phase 1) is the `NSPopover` todo list, which
    /// tears down + rebuilds its content view hierarchy on every show/close,
    /// so a still-`.inProgress` glyph would otherwise render frozen on reopen.
    /// `setState(_:muted:)` can't fix it either — its idempotence guard
    /// short-circuits on an unchanged `(status, muted)`. Re-asserting here on
    /// attach (and clearing on detach so a closed popover doesn't keep an
    /// invisible animation alive) is the correct lifecycle seam, matching the
    /// SwiftUI `onAppear` re-arm. Wrapped in a disabled transaction so the
    /// re-add isn't itself crossfaded.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentsScale()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Attached → re-arm the spin if live; detached → tear it down so a
        // closed/recycled host doesn't carry a stale animation.
        applyRotation(active: window != nil && showsLiveSpinner)
        CATransaction.commit()
    }

    // MARK: - Reconfigure (the per-state rebuild)

    /// Rebuild path / fill / stroke / dash for the current `(status, muted)`
    /// and add-or-remove the rotation animation. Wrapped in a disabled
    /// transaction so a state flip's color / dash / path swap never
    /// crossfades; the only intentional animation is the rotation.
    private func reconfigure() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let live = showsLiveSpinner

        switch status {
        case .pending, .inProgress:
            // Ring (plain for pending / muted-inProgress; dotted for live).
            shapeLayer.fillColor = nil
            shapeLayer.lineWidth = Self.strokeWidth
            if live {
                shapeLayer.lineCap = .round
                shapeLayer.lineDashPattern = Self.dashPattern()
            } else {
                shapeLayer.lineCap = .butt
                shapeLayer.lineDashPattern = nil
            }
            shapeLayer.fillRule = .nonZero  // irrelevant (no fill); kept tidy
        case .completed:
            // Single even-odd filled path: ring band + inner dot.
            shapeLayer.strokeColor = nil
            shapeLayer.lineWidth = 0
            shapeLayer.lineCap = .butt
            shapeLayer.lineDashPattern = nil
            // R18: MUST be explicit — the default `.nonZero` fills the inner
            // hole and renders a solid disc.
            shapeLayer.fillRule = .evenOdd
        }

        applyPath()
        applyColor()
        applyRotation(active: live)

        CATransaction.commit()
    }

    /// Set the path for the current state against the current bounds, and
    /// (re)assert `fillRule = .evenOdd` for the completed glyph (it must be
    /// reapplied on every completed-path build — plan §8 R18).
    private func applyPath() {
        switch status {
        case .pending, .inProgress:
            shapeLayer.path = Self.ringPath(in: bounds)
        case .completed:
            shapeLayer.fillRule = .evenOdd
            shapeLayer.path = Self.completedPath(in: bounds)
        }
    }

    /// Resolve + assign the active state's color to the correct channel:
    /// `fillColor` for the completed fill-only glyph, `strokeColor` for the
    /// ring states.
    private func applyColor() {
        let resolved = resolvedColor(for: stateColor)
        switch status {
        case .pending, .inProgress:
            shapeLayer.strokeColor = resolved
            shapeLayer.fillColor = nil
        case .completed:
            shapeLayer.fillColor = resolved
            shapeLayer.strokeColor = nil
        }
    }

    /// Add or remove the rotation animation keyed strictly on the live-spinner
    /// predicate (plan §4.2-6, R17). `isRemovedOnCompletion = false` means the
    /// spin persists across implicit transactions, so it must be removed
    /// explicitly when leaving the predicate.
    private func applyRotation(active: Bool) {
        if active {
            // Idempotent: don't restack a fresh spin over an existing one.
            guard shapeLayer.animation(forKey: Self.rotationAnimationKey) == nil else { return }
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = 2 * Double.pi
            anim.duration = Self.rotationDuration
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            shapeLayer.add(anim, forKey: Self.rotationAnimationKey)
        } else {
            shapeLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        }
    }

    // MARK: - Color selection (lifted from TodoStatusGlyph.strokeColor:74-81)

    /// The `NSColor` for the active state (`TodoStatusGlyph.swift:74-81`):
    /// muted ⇒ `secondaryLabelColor`; `.pending` ⇒ `secondaryLabelColor`;
    /// `.inProgress` ⇒ `controlAccentColor`; `.completed` ⇒
    /// `secondaryLabelColor`.
    private var stateColor: NSColor {
        if muted { return .secondaryLabelColor }
        switch status {
        case .pending: return .secondaryLabelColor
        case .inProgress: return .controlAccentColor
        case .completed: return .secondaryLabelColor
        }
    }

    /// Resolve an `NSColor` to a `CGColor` against the current
    /// `effectiveAppearance` (R14).
    private func resolvedColor(for color: NSColor) -> CGColor {
        var resolved: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    // MARK: - Apply helpers

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        shapeLayer.contentsScale = scale
    }
}

import AppKit

/// AppKit replacement for the SwiftUI `PermissionCardSurface` ViewModifier
/// (migration plan §4.4-1). The OPAQUE panel surface behind the floating
/// permission card.
///
/// **OPAQUE, not glass (§4.4-1 BLOCKER).** The permission card deliberately
/// fills a solid `controlBackgroundColor` rather than reusing the bar's glass
/// `BarSurfaceView`: the card sits directly above the input bar and the bar's
/// translucent material was bleeding through, which made the diff / command
/// preview hard to read. So this view does NOT share `BarSurfaceView` — it is
/// its own fully-opaque panel with its own shadow params:
///
/// - fill = solid (alpha 1) `controlBackgroundColor`
/// - corner radius = 16 (`.continuous`), from `PermissionCardView.cornerRadius`
/// - border = 0.5pt `separatorColor` stroke, inset by half the line width so it
///   sits fully inside bounds. SwiftUI's `.overlay { RoundedRectangle.stroke }`
///   (`PermissionCardView.swift:244-247`) is UNCLIPPED — it centers the 0.5pt
///   stroke ON the rounded-rect edge (≈0.25pt outside, 0.25pt inside). For an
///   opaque, layer-masked panel an inside-the-clip stroke reads cleaner, so this
///   is a deliberate ≈0.25pt sub-pixel adjustment, not a 1:1 stroke placement
///   (pixel deviation is allowed; behavior/layout parity is preserved).
/// - shadow = black, opacity 0.35 dark / 0.12 light, radius 10, SwiftUI `y: +4`
///   → CALayer `shadowOffset.height = -4` (these params DIFFER from
///   `BarSurfaceView`'s radius-12/8 — do not share)
///
/// This is a 1:1 visual relocation of `PermissionCardSurface`
/// (`PermissionCardView.swift:233-252`), not a redesign.
///
/// Structure mirrors `BarSurfaceView`'s shadow-outside-clip discipline:
///
/// ```
/// PermissionCardSurfaceView (outer wrapper — UNMASKED; holds the shadow)
/// ├─ fillLayer    (solid controlBackgroundColor, rounded + clipped)
/// └─ strokeLayer  (0.5pt separatorColor continuous-rounded path on top)
/// ```
///
/// Sizing: regime-B background pinned to the card content's edges — the card
/// content drives the size, so the surface publishes `noIntrinsicMetric` on
/// both axes (window-collapse guard, plan R1). The mask / stroke / shadow paths
/// are recomputed in `layout()` after `super.layout()` (settled bounds).
final class PermissionCardSurfaceView: NSView {

    // MARK: - Constants (verbatim from PermissionCardSurface, PermissionCardView.swift:49,233-252)

    /// Card corner radius, from `PermissionCardView.cornerRadius`
    /// (`PermissionCardView.swift:49`).
    static let cornerRadius: CGFloat = 16

    /// 0.5pt `separatorColor` border (`PermissionCardView.swift:246`).
    static let strokeLineWidth: CGFloat = 0.5

    /// Shadow params — DIFFERENT from `BarSurfaceView`'s
    /// (`PermissionCardView.swift:248-250`).
    static let shadowRadius: CGFloat = 10
    /// SwiftUI `y: +4`; CALayer `shadowOffset` y is positive-up, so a
    /// SwiftUI `y: +n` reads back as `height: -n`.
    static let shadowOffsetY: CGFloat = 4
    static let shadowOpacityDark: Float = 0.35
    static let shadowOpacityLight: Float = 0.12

    // MARK: - Layers

    /// The solid, opaque fill (rounded + clipped). Separate from the outer
    /// wrapper's layer so the shadow lives outside the rounded clip.
    private let fillLayer = CALayer()

    /// The 0.5pt separator border on top, a continuous-rounded path.
    private let strokeLayer = CAShapeLayer()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Outer wrapper layer holds the shadow (outside the clip).
        layer?.masksToBounds = false

        // Solid opaque fill, rounded to the card corners.
        fillLayer.cornerCurve = .continuous
        fillLayer.cornerRadius = Self.cornerRadius
        fillLayer.masksToBounds = true
        layer?.addSublayer(fillLayer)

        // Separator stroke on top.
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = Self.strokeLineWidth
        layer?.addSublayer(strokeLayer)

        applyContentsScale()
        applyFillColor()
        applyStrokeColor()
        applyShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit` so the
    /// `@MainActor` deinit executor hop doesn't abort under
    /// `libswift_Concurrency`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)
    //
    // Mirror `BarSurfaceView`'s precedent (BarSurfaceView.swift:207-258): these
    // expose resolved layer state so CI-gate tests can assert the §4.4-1
    // opaque-fill invariant + appearance re-resolve mechanism against the real
    // production object. Read-only, no mutation seam, no production consumers.

    /// The resolved opaque fill color currently on the fill layer. The
    /// §4.4-1 anti-bleed invariant: `alphaComponent == 1`.
    var resolvedFillColor: CGColor? { fillLayer.backgroundColor }

    /// The resolved separator-stroke color currently on the border layer.
    var resolvedStrokeColor: CGColor? { strokeLayer.strokeColor }

    /// The fill layer's corner radius (== `cornerRadius`).
    var resolvedCornerRadius: CGFloat { fillLayer.cornerRadius }

    /// Whether the fill uses a continuous (squircle) corner curve.
    var fillCornerCurveIsContinuous: Bool { fillLayer.cornerCurve == .continuous }

    /// The current shadow opacity on the outer wrapper (0.35 dark / 0.12 light).
    var resolvedShadowOpacity: Float { layer?.shadowOpacity ?? 0 }

    /// The current shadow radius on the outer wrapper (== `shadowRadius`).
    var resolvedShadowRadius: CGFloat { layer?.shadowRadius ?? 0 }

    /// The current shadow offset on the outer wrapper (CALayer convention:
    /// positive-up, so the SwiftUI `y: +4` reads back as `height: -4`).
    var resolvedShadowOffset: CGSize { layer?.shadowOffset ?? .zero }

    /// The current shadow silhouette on the outer wrapper. Tracks the
    /// continuous-rounded path so the shadow follows the rounded shape.
    var resolvedShadowPath: CGPath? { layer?.shadowPath }

    // MARK: - Sizing (regime-B — content drives size; publish nothing)

    /// Publish `noIntrinsicMetric` on **both** axes. The surface is a
    /// background pinned to the card content's four edges — the content drives
    /// the size. A non-trivial intrinsic size could leak up into the window's
    /// constraint solver and collapse the window (root `CLAUDE.md` host-sizing
    /// + plan R1).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Fill / stroke / shadow paths depend on the settled bounds; recompute
        // after super sizes the subtree.
        applyGeometry()
    }

    // MARK: - Appearance / backing re-resolve

    /// `CALayer` cgColors do not auto-update on dark/light flip; SwiftUI did
    /// this free. Re-resolve fill + stroke + the colorScheme-dependent shadow
    /// opacity against the new appearance, wrapped so the change doesn't
    /// crossfade (R14, §4.4-3).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFillColor()
        applyStrokeColor()
        applyShadow()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    // MARK: - Apply helpers

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    private func applyContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        fillLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
    }

    /// Resolve the OPAQUE fill against the current appearance. The fill MUST
    /// stay fully opaque (`alphaComponent == 1`) — the whole point of §4.4-1
    /// is the bar's glass was bleeding through and making diffs unreadable.
    private func applyFillColor() {
        var resolved: CGColor = NSColor.controlBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlBackgroundColor.cgColor
        }
        fillLayer.backgroundColor = resolved
    }

    /// Resolve the separator stroke color against the current appearance.
    private func applyStrokeColor() {
        var resolved: CGColor = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.cgColor
        }
        strokeLayer.strokeColor = resolved
    }

    /// Shadow on the outer wrapper's layer (outside the rounded clip), with the
    /// card's own params (radius 10 / opacity 0.35-dark, 0.12-light / y4). The
    /// colorScheme-dependent opacity is picked via the shared
    /// `NSAppearance.isBarSurfaceDark` helper (BarSurfaceView.swift:524-531).
    private func applyShadow() {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity =
            effectiveAppearance.isBarSurfaceDark ? Self.shadowOpacityDark : Self.shadowOpacityLight
        layer.shadowRadius = Self.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: -Self.shadowOffsetY)
    }

    /// Recompute the fill frame / corner, the stroke path, and the shadow path
    /// against the settled bounds. Reuses `BarSurfaceGeometry.continuousRoundedPath`
    /// for the stroke + shadowPath silhouette.
    private func applyGeometry() {
        let size = bounds.size
        let radius = min(Self.cornerRadius, min(size.width, size.height) / 2)

        fillLayer.frame = bounds
        fillLayer.cornerRadius = max(0, radius)
        fillLayer.cornerCurve = .continuous

        // Stroke inset by half the line width so the 0.5pt border sits fully
        // inside the bounds. SwiftUI's overlay `.stroke` is unclipped (centered
        // on the edge) — this is a deliberate ≈0.25pt sub-pixel adjustment for
        // the opaque layer-masked panel, not a 1:1 placement.
        let inset = Self.strokeLineWidth / 2
        let strokeRect = bounds.insetBy(dx: inset, dy: inset)
        let strokeRadius = max(0, radius - inset)
        strokeLayer.frame = bounds
        if size.width > 0, size.height > 0 {
            strokeLayer.path = BarSurfaceGeometry.continuousRoundedPath(
                in: strokeRect, cornerRadius: strokeRadius)
            layer?.shadowPath = BarSurfaceGeometry.continuousRoundedPath(
                in: bounds, cornerRadius: max(0, radius))
        } else {
            strokeLayer.path = nil
            layer?.shadowPath = nil
        }
    }
}

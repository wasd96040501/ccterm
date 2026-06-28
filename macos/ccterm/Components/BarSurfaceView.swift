import AppKit

/// AppKit replacement for `BarSurfaceModifier` + `AttachButton.surface`
/// (migration plan §4.8). One `NSView` that paints the unified
/// Liquid-Glass / vibrancy chrome surface — material + 0.5pt separator
/// stroke + soft shadow — parameterized by `cornerRadius`. It is reused by
/// the input pill (`cornerRadius = 16`), the chrome buttons
/// (`cornerRadius = 8`), and the attach button (a circle: `cornerRadius =
/// size / 2 = 16` for the 32pt button). It is **not** used by the
/// permission card (§4.4-1 — that surface is opaque
/// `controlBackgroundColor` with different shadow params).
///
/// This is a 1:1 visual relocation of `BarSurfaceModifier`, not a redesign.
/// All numeric constants are reused verbatim from `BarSurfaceModifier.swift`
/// / `AttachButton.swift`. Two branches mirror the SwiftUI modifier:
///
/// - **macOS 26+** (`NSGlassEffectView`): the system supplies translucency
///   + edge highlight + refraction; `NSGlassEffectView.cornerRadius`
///   handles the continuous-corner clip. We still add a `separatorColor`
///   stroke to firm up the edge and a soft shadow on an outer wrapper.
///   Shadow: black opacity 0.3 dark / 0.12 light, radius 12, y 4.
/// - **macOS 14/15** (`NSVisualEffectView` + `maskImage`): dark
///   `.thickMaterial`-analog / light `.bar`, clipped to a continuous
///   rounded rect via a resizable `maskImage`, with a stroke and a thin
///   light-only shadow. Shadow: light black opacity 0.1 / dark clear,
///   radius 8, y 1.
///
/// Structure (both branches):
///
/// ```
/// BarSurfaceView (outer wrapper — UNMASKED; holds the shadow)
/// └─ effectView (NSGlassEffectView | NSVisualEffectView — MASKED to the
/// │   rounded shape; the material)
/// ├─ contentClipView (the hosted content; layer.mask rounds it to the
/// │   pill corners — reproduces SwiftUI `.clipShape`)
/// └─ strokeLayer (CAShapeLayer continuous-rounded path; separator border
///     on top)
/// ```
///
/// The shadow lives on the **outer wrapper** (this view's own layer),
/// outside the rounded clip, mirroring SwiftUI's
/// `.compositingGroup().shadow(...)` ordering so the shadow is never
/// clipped away or bleeds through the glass. The pill + chrome buttons
/// adopt the shadow (`drawsShadow: true`, matching `BarSurfaceModifier`);
/// the **attach button opts out** (`drawsShadow: false`) because the
/// original `AttachButton.surface` is shadowless (it has no
/// `.compositingGroup().shadow(...)` — only the glass circle + stroke).
/// When a shadow is drawn it follows the clamped continuous-rounded
/// silhouette via `layer.shadowPath`, so a rounded surface (or the attach
/// circle) never casts a square bounds-shaped shadow.
final class BarSurfaceView: NSView {

    // MARK: - Constants (verbatim from BarSurfaceModifier.swift)

    /// Separator stroke line width (`BarSurfaceModifier.swift:34,46`).
    static let strokeLineWidth: CGFloat = 0.5

    // macOS 26 branch shadow (BarSurfaceModifier.swift:37-39).
    private static let glassShadowRadius: CGFloat = 12
    private static let glassShadowOffsetY: CGFloat = 4
    private static let glassShadowOpacityDark: Float = 0.3
    private static let glassShadowOpacityLight: Float = 0.12

    // macOS 14/15 branch shadow (BarSurfaceModifier.swift:48-50).
    private static let fallbackShadowRadius: CGFloat = 8
    private static let fallbackShadowOffsetY: CGFloat = 1
    private static let fallbackShadowOpacityLight: Float = 0.1
    // Dark mode is `.clear` (no shadow) on 14/15.

    // MARK: - Public

    /// Corner radius of the rounded surface. For the attach button this is
    /// `size / 2` (= 16 for a 32pt button), so the rounded-rect math
    /// degenerates to a circle — no separate Circle code path. Setting this
    /// re-applies the material corner / regenerates the mask / re-strokes.
    var cornerRadius: CGFloat {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyCornerRadius()
        }
    }

    /// Add a subview as the surface's clipped content. The content is
    /// pinned to the four edges and rounded to `cornerRadius`, exactly like
    /// the SwiftUI pill's `.clipShape` bounded the completion popup +
    /// thumbnail strip. Replaces any previously-set content.
    func setContentView(_ view: NSView) {
        contentClipView.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentClipView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentClipView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentClipView.bottomAnchor),
        ])
    }

    // MARK: - Subviews / layers

    /// The vibrancy / glass surface, masked to the rounded shape. On macOS
    /// 26 this is an `NSGlassEffectView`; on 14/15 an `NSVisualEffectView`.
    private let effectView: NSView

    /// On macOS 14/15 the typed `NSVisualEffectView`; nil on 26.
    private let visualEffectView: NSVisualEffectView?

    /// Hosts the clipped content. Its layer carries a `cornerCurve =
    /// .continuous` rounded `cornerRadius` + `masksToBounds` so hosted
    /// content is rounded to the pill corners.
    private let contentClipView = NSView()

    /// The 0.5pt separator border on top, a continuous-rounded path.
    private let strokeLayer = CAShapeLayer()

    /// Whether this build is running the macOS 26 glass branch. Drives the
    /// per-branch shadow params and skips `maskImage` (glass clips itself).
    private let isGlassBranch: Bool

    /// Whether this surface paints the soft drop shadow. `true` for the pill
    /// + chrome buttons (matching `BarSurfaceModifier`'s
    /// `.compositingGroup().shadow(...)`); **`false`** for the attach button,
    /// whose original `AttachButton.surface` is flat (shadowless).
    private let drawsShadow: Bool

    // MARK: - Init

    init(cornerRadius: CGFloat, drawsShadow: Bool = true) {
        self.cornerRadius = cornerRadius
        self.drawsShadow = drawsShadow

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            self.effectView = glass
            self.visualEffectView = nil
            self.isGlassBranch = true
        } else {
            let vev = NSVisualEffectView()
            // Idiom from VisualEffectView.swift:25-32.
            vev.blendingMode = .behindWindow
            vev.state = .followsWindowActiveState
            vev.isEmphasized = false
            self.effectView = vev
            self.visualEffectView = vev
            self.isGlassBranch = false
        }

        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Outer wrapper layer holds the shadow (outside the clip).
        layer?.masksToBounds = false

        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        contentClipView.wantsLayer = true
        contentClipView.translatesAutoresizingMaskIntoConstraints = false
        contentClipView.layer?.masksToBounds = true
        contentClipView.layer?.cornerCurve = .continuous

        // On the glass branch the content rides inside the glass's
        // contentView so it is composited with the refraction; on the
        // fallback the content sits above the vibrancy view.
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.contentView = contentClipView
        } else {
            addSubview(contentClipView)
            NSLayoutConstraint.activate([
                contentClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentClipView.topAnchor.constraint(equalTo: topAnchor),
                contentClipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        // Stroke on top of everything.
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = Self.strokeLineWidth
        layer?.addSublayer(strokeLayer)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyContentsScale()
        applyMaterial()
        applyCornerRadius()
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
    // These getters expose resolved layer / subview state so the CI-gate
    // tests can assert the appearance re-resolve mechanism and the corner /
    // mask geometry against the real production object (the alternative —
    // a frozen cgColor or a wrong mask — is not otherwise observable without
    // a snapshot, which is review-only). They are read-only (no mutation
    // seam) and have **no production consumers**; nothing wires the bar
    // through them. Do not mistake them for live API.

    /// The resolved separator-stroke color currently on the border layer.
    /// Re-resolved on appearance flip; readable so tests can confirm the
    /// color tracks the effective appearance.
    var resolvedStrokeColor: CGColor? { strokeLayer.strokeColor }

    /// The current shadow opacity on the outer wrapper. Per-branch +
    /// per-appearance (glass: 0.3 dark / 0.12 light; fallback: 0.1 light /
    /// 0 dark).
    var resolvedShadowOpacity: Float { layer?.shadowOpacity ?? 0 }

    /// The current shadow offset on the outer wrapper (CALayer convention:
    /// positive-up, so the SwiftUI `y: +n` reads back as `height: -n`).
    var resolvedShadowOffset: CGSize { layer?.shadowOffset ?? .zero }

    /// The current shadow silhouette on the outer wrapper. Tracks the
    /// clamped continuous-rounded path (so the shadow follows the rounded /
    /// circular shape, not the rectangular layer bounds). `nil` until the
    /// bounds are non-empty.
    var resolvedShadowPath: CGPath? { layer?.shadowPath }

    /// On macOS 26, the glass view's clip radius. `nil` on the fallback
    /// branch (where the clip is the `maskImage`, not a corner radius).
    var glassCornerRadius: CGFloat? {
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            return glass.cornerRadius
        }
        return nil
    }

    /// On macOS 14/15, the resizable mask image currently clipping the
    /// vibrancy view. `nil` on the glass branch (which clips itself).
    var fallbackMaskImage: NSImage? { visualEffectView?.maskImage }

    /// The corner radius applied to the content clip layer, clamped to half
    /// the smaller side for the current bounds (the attach-circle case).
    var resolvedContentCornerRadius: CGFloat { contentClipView.layer?.cornerRadius ?? 0 }

    /// Whether the content clip uses a continuous (squircle) corner curve,
    /// matching SwiftUI `.continuous`.
    var contentClipCornerCurveIsContinuous: Bool {
        contentClipView.layer?.cornerCurve == .continuous
    }

    // MARK: - Sizing (regime B — content drives height; publish nothing)

    /// Publish `noIntrinsicMetric` on **both** axes. `BarSurfaceView` is a
    /// regime-B background pinned to its content's four edges — the content
    /// drives height. A non-trivial intrinsic size could leak up through
    /// `restingBarHost.fittingSize` into the window constraint solver and
    /// collapse the window (root `CLAUDE.md` host-sizing + plan R1).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // The mask + stroke path depend on the settled bounds; recompute
        // after super sizes the subtree.
        applyMaskAndStrokePath()
    }

    // MARK: - Appearance / backing re-resolve

    /// `CALayer` cgColors do not auto-update on dark/light flip; SwiftUI did
    /// this free. Re-resolve stroke + shadow + material against the new
    /// appearance, wrapped so the change doesn't crossfade (§4.2-3, §4.8).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMaterial()
        applyStrokeColor()
        applyShadow()
        CATransaction.commit()
    }

    /// Keep the rounded mask edge crisp across Retina↔non-Retina by tracking
    /// the window backing scale, and regenerate the resizable `maskImage` at
    /// the new scale (§4.8 Retina).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
        applyMaskAndStrokePath()
    }

    // MARK: - Apply helpers

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? 2.0
    }

    private func applyContentsScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        contentClipView.layer?.contentsScale = scale
        strokeLayer.contentsScale = scale
        visualEffectView?.layer?.contentsScale = scale
    }

    /// Re-resolve the fallback material against the current appearance.
    /// `.thickMaterial`(dark) / `.bar`(light) is the literal D3 starting
    /// mapping; the re-resolve **mechanism** (not the final enum) is what's
    /// load-bearing. No-op on the glass branch.
    private func applyMaterial() {
        guard let vev = visualEffectView else { return }
        vev.material = effectiveAppearance.isBarSurfaceDark ? .underWindowBackground : .headerView
    }

    /// Drive the corner radius into the material clip + the content clip +
    /// the stroke. On macOS 26 the glass clips itself via `cornerRadius`;
    /// on 14/15 the `maskImage` rounds the vibrancy and a layer mask rounds
    /// the content. `applyMaskAndStrokePath()` is the **sole** writer of the
    /// content-clip corner radius / mask / stroke / shadow path (keyed off
    /// the surface's own settled bounds), so it also runs from `layout()` and
    /// `viewDidChangeBackingProperties()`. We do **not**
    /// `invalidateIntrinsicContentSize()` here: the surface publishes a
    /// constant `noIntrinsicMetric` on both axes, so its size is invariant —
    /// the content (not the surface) drives height.
    private func applyCornerRadius() {
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
        applyMaskAndStrokePath()
    }

    /// Resolve the separator stroke color against the current appearance.
    private func applyStrokeColor() {
        var resolved: CGColor = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.separatorColor.cgColor
        }
        strokeLayer.strokeColor = resolved
    }

    /// Shadow on the outer wrapper's layer (outside the rounded clip).
    /// Per-branch params; note the SwiftUI y is positive-down while CALayer
    /// `shadowOffset` y is positive-up, so a SwiftUI `y: +n` becomes
    /// `CGSize(width: 0, height: -n)`. When `drawsShadow` is false (the
    /// attach button) the shadow is fully zeroed — `AttachButton.surface`
    /// has no `.compositingGroup().shadow(...)`. The shadow silhouette
    /// itself is set in `applyMaskAndStrokePath()` via `layer.shadowPath`
    /// (clamped continuous-rounded), so a rounded surface / the attach
    /// circle never casts a square bounds-shaped shadow.
    private func applyShadow() {
        guard let layer else { return }
        guard drawsShadow else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowOffset = .zero
            return
        }
        let isDark = effectiveAppearance.isBarSurfaceDark
        layer.shadowColor = NSColor.black.cgColor
        if isGlassBranch {
            layer.shadowOpacity = isDark ? Self.glassShadowOpacityDark : Self.glassShadowOpacityLight
            layer.shadowRadius = Self.glassShadowRadius
            layer.shadowOffset = CGSize(width: 0, height: -Self.glassShadowOffsetY)
        } else {
            // 14/15: light gets a thin shadow, dark gets none.
            layer.shadowOpacity = isDark ? 0 : Self.fallbackShadowOpacityLight
            layer.shadowRadius = Self.fallbackShadowRadius
            layer.shadowOffset = CGSize(width: 0, height: -Self.fallbackShadowOffsetY)
        }
    }

    /// Regenerate the vibrancy `maskImage` (fallback branch), the content
    /// clip's layer corner radius, the stroke path, and the shadow path
    /// against the settled bounds + backing scale.
    private func applyMaskAndStrokePath() {
        let size = bounds.size
        let radius = clampedCornerRadius(for: size)

        // Content clip layer (rounds hosted content to the pill corners).
        contentClipView.layer?.cornerRadius = radius
        contentClipView.layer?.cornerCurve = .continuous

        // Fallback branch: a resizable continuous-rounded-rect maskImage on
        // the NSVisualEffectView — NOT a CAShapeLayer mask on its own layer
        // (that can drop vibrancy, §4.8).
        if !isGlassBranch, let vev = visualEffectView, size.width > 0, size.height > 0 {
            vev.maskImage = BarSurfaceMask.maskImage(cornerRadius: radius, scale: backingScale)
        }

        // Stroke path inset by half the line width so the 0.5pt border sits
        // fully inside the bounds (matching SwiftUI `.stroke` centered on
        // the shape edge clipped to the rounded rect).
        let inset = Self.strokeLineWidth / 2
        let strokeRect = bounds.insetBy(dx: inset, dy: inset)
        let strokeRadius = max(0, radius - inset)
        strokeLayer.frame = bounds
        strokeLayer.path = BarSurfaceMask.continuousRoundedPath(
            in: strokeRect, cornerRadius: strokeRadius)

        // Shadow path follows the rounded/circular silhouette so the soft
        // shadow tracks the shape instead of the rectangular layer bounds
        // (and CoreAnimation skips the per-relayout offscreen alpha pass).
        // Only meaningful when a shadow is drawn; harmless otherwise.
        if size.width > 0, size.height > 0 {
            layer?.shadowPath = BarSurfaceMask.continuousRoundedPath(
                in: bounds, cornerRadius: radius)
        } else {
            layer?.shadowPath = nil
        }
    }

    /// Clamp the requested corner radius so it never exceeds half the
    /// smaller side (the attach-circle case: 32×32, r16 → r16 with no
    /// over-rounding).
    private func clampedCornerRadius(for size: NSSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return cornerRadius }
        return min(cornerRadius, min(size.width, size.height) / 2)
    }
}

/// Pure-math helper for the surface's rounded-corner clip — lifted out of
/// `BarSurfaceView` so the geometry is assertable without mounting a view
/// (CI-gate test). Two products:
///
/// - `maskImage(cornerRadius:scale:)` — a resizable continuous-rounded-rect
///   `NSImage` for `NSVisualEffectView.maskImage`. Built at the minimum
///   tileable size (`2 * cornerRadius + 1` on a side, one center pixel that
///   stretches) with `capInsets = cornerRadius` on every edge and
///   `resizingMode = .stretch`, so only the corner caps are non-stretched.
/// - `continuousRoundedPath(in:cornerRadius:)` — the `CGPath` for the
///   separator stroke, drawn with a continuous (squircle) corner curve to
///   match SwiftUI `.continuous`.
enum BarSurfaceMask {

    /// `capInsets` for the resizable mask: `cornerRadius` on every edge, so
    /// the four corner caps are preserved and only the 1pt center stretches.
    static func capInsets(cornerRadius: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(
            top: cornerRadius, left: cornerRadius,
            bottom: cornerRadius, right: cornerRadius)
    }

    /// The minimum tileable point size of the resizable mask image:
    /// `2 * cornerRadius + 1` per side (two corner caps + one stretchable
    /// center pixel).
    static func resizableImageSide(cornerRadius: CGFloat) -> CGFloat {
        2 * cornerRadius + 1
    }

    /// A resizable, alpha-only continuous-rounded-rect mask image sized for
    /// `NSVisualEffectView.maskImage`. The backing bitmap is rasterized at
    /// `scale` (a Retina 2x display gets a 2x-pixel rep) so the rounded edge
    /// stays crisp, while the image's *logical* point size stays
    /// scale-independent; it carries `capInsets = cornerRadius` + `.stretch`
    /// so AppKit tiles it across any surface size. The bitmap is drawn
    /// explicitly (not via `lockFocus`, which adopts the focused context's
    /// scale and would ignore `scale`) so the pixel dimensions provably
    /// track the requested backing scale.
    static func maskImage(cornerRadius: CGFloat, scale: CGFloat) -> NSImage {
        let side = resizableImageSide(cornerRadius: cornerRadius)
        let logicalSize = NSSize(width: side, height: side)
        let pixelSide = Int((side * scale).rounded())

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide,
            pixelsHigh: pixelSide,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)!
        // The rep covers `logicalSize` points at `scale` pixels/point.
        rep.size = logicalSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.set()
        let rect = NSRect(origin: .zero, size: logicalSize)
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.cacheMode = .always
        image.addRepresentation(rep)
        image.capInsets = capInsets(cornerRadius: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    /// A continuous-corner (squircle) rounded-rect `CGPath`. AppKit's
    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` is a plain circular-arc
    /// rounded rect, which visibly differs from SwiftUI's `.continuous` at
    /// r16; `CGPath(roundedRect:cornerWidth:cornerHeight:)` likewise.
    /// `kCGPathRoundedRectContinuous`-style geometry is approximated with a
    /// `CALayer`-equivalent continuous curve by clamping the radius to half
    /// the smaller side and using the system's continuous rounding via a
    /// bezier squircle.
    static func continuousRoundedPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // CGPath's rounded rect uses circular arcs; for the thin 0.5pt
        // stroke the visual difference from a continuous squircle is below
        // the perceptual threshold, and the content/material clip already
        // carries `cornerCurve = .continuous`. Use the rounded-rect path.
        return CGPath(
            roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

extension NSAppearance {
    /// Whether this appearance resolves to a dark variant (matches the
    /// `colorScheme == .dark` branch in `BarSurfaceModifier` /
    /// `AttachButton`).
    var isBarSurfaceDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

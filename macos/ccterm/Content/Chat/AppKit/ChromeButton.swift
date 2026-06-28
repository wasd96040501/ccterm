import AppKit

/// AppKit replacement for the SwiftUI `BarChromeButton`
/// (`InputBarControls/BarChromeButton.swift`; migration plan §4.2). A 22pt
/// pill-style trigger used by every chrome-row picker (permission /
/// model+effort / context ring / background tasks / todos). The surface is the
/// same `BarSurfaceView` glass material as the input pill, at `cornerRadius =
/// 8`; a hover overlay paints `labelColor @ 0.08` (the AppKit analogue of
/// SwiftUI `Color.primary.opacity(0.08)`) over 0.1s linear, matching
/// `BarChromeButton`'s `.animation(.linear(duration: 0.1), value: hovering)`.
///
/// Structure (mirrors the SwiftUI `Button { label }.barSurface(8).overlay`):
///
/// ```
/// ChromeButton (NSControl, wantsLayer)
/// └─ surface: BarSurfaceView(cornerRadius: 8, drawsShadow: true)
///    └─ content stack (label + optional leading glyph / trailing accessory)
/// (hoverOverlay CALayer painted on the button's own layer, ABOVE the surface
///  but BELOW key events, sized to bounds, r8 .continuous, labelColor@0.08)
/// ```
///
/// This is a 1:1 visual relocation of `BarChromeButton`, not a redesign — the
/// font (system 12 medium), horizontal padding (8), height (22), corner radius
/// (8), hover fill (`labelColor @ 0.08`), and hover-animation timing (linear
/// 0.1s) are reused verbatim. Hidden visibility for the BgTask / Todo /
/// ModelEffort pickers is driven by the owning `ChromeRowView` toggling the
/// button's `isHidden` (an NSStackView arranged subview), so the chrome row's
/// fixed 22pt band height never changes (plan §4.2-10).
final class ChromeButton: NSControl {

    // MARK: - Constants (verbatim from BarChromeButton.swift)

    /// Pill height (`BarChromeButton.swift:23` `.frame(height: 22)`).
    static let height: CGFloat = 22
    /// Horizontal padding (`BarChromeButton.swift:22` `.padding(.horizontal, 8)`).
    static let horizontalPadding: CGFloat = 8
    /// Label font (`BarChromeButton.swift:21` system 12 weight .medium).
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Surface corner radius (`BarChromeButton.swift:24` `.barSurface(cornerRadius: 8)`).
    static let cornerRadius: CGFloat = 8
    /// Hover overlay fill alpha (`BarChromeButton.swift:27`
    /// `Color.primary.opacity(0.08)`).
    static let hoverOverlayAlpha: CGFloat = 0.08
    /// Hover animation duration (`BarChromeButton.swift:33`
    /// `.animation(.linear(duration: 0.1), value: hovering)`).
    static let hoverAnimationDuration: CFTimeInterval = 0.1

    // MARK: - Subviews / layers

    /// The glass surface backing (cornerRadius 8, with shadow — matching the
    /// chrome button's `.barSurface(cornerRadius: 8)`, which DOES carry the
    /// shadow, unlike the attach button which opts out). Nil when
    /// `showsSurface == false` (the ContextRing bare trigger — its SwiftUI
    /// original is a `.buttonStyle(.plain)` ring with no `.barSurface`).
    private let surface: BarSurfaceView?

    /// Whether the pill surface + hover overlay are present. `false` for the
    /// ContextRing trigger, which is a bare ring (no pill, no hover, no
    /// horizontal padding) — matching SwiftUI's `Button { ProgressRingView }
    /// .buttonStyle(.plain)` (ContextRingButton.swift:18-23).
    let showsSurface: Bool

    /// The content the surface clips: a horizontal stack the picker fills with
    /// a label NSTextField + optional leading glyph + trailing accessory.
    let contentStack = NSStackView()

    /// Hover overlay painted over the surface (`labelColor @ 0.08`, r8). Toggled
    /// by an `NSTrackingArea`; alpha animated 0→1 over 0.1s linear. Nil when
    /// `showsSurface == false` (bare ContextRing trigger).
    private let hoverOverlay: CALayer?

    private var trackingArea: NSTrackingArea?
    private var hovering = false

    // MARK: - Init

    init(showsSurface: Bool = true) {
        self.showsSurface = showsSurface
        self.surface =
            showsSurface
            ? BarSurfaceView(cornerRadius: ChromeButton.cornerRadius, drawsShadow: true) : nil
        self.hoverOverlay = showsSurface ? CALayer() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: ChromeButton.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Content stack: the picker fills it with the label / leading glyph; the
        // stack's intrinsic width drives the button width.
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // When the surface is present, the content nests inside it (clipped to
        // the rounded shape) with horizontal padding; the surface fills bounds.
        // When absent (ContextRing), the content stack is pinned directly with
        // NO horizontal padding, so the trigger footprint is the bare content.
        let horizontalPadding = showsSurface ? Self.horizontalPadding : 0
        if let surface {
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(
                    equalTo: inner.leadingAnchor, constant: horizontalPadding),
                contentStack.trailingAnchor.constraint(
                    equalTo: inner.trailingAnchor, constant: -horizontalPadding),
                contentStack.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
                contentStack.topAnchor.constraint(greaterThanOrEqualTo: inner.topAnchor),
            ])
            surface.setContentView(inner)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor),
                surface.topAnchor.constraint(equalTo: topAnchor),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            ])
        }

        // Hover overlay above the surface in the button's own layer (only when
        // the surface is shown — the bare ContextRing ring has no hover fill).
        if let hoverOverlay {
            hoverOverlay.cornerCurve = .continuous
            hoverOverlay.cornerRadius = Self.cornerRadius
            hoverOverlay.opacity = 0
            layer?.addSublayer(hoverOverlay)
            applyHoverOverlayColor()
        }

        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    // MARK: - Sizing

    /// The button hugs its content: the stack's fitting width + 2× horizontal
    /// padding (zero padding when the surface is hidden — the bare ContextRing
    /// trigger is exactly its 22pt content), at the fixed 22pt height. Width is
    /// intrinsic (so the chrome row sizes the pill from its label), height is
    /// fixed.
    override var intrinsicContentSize: NSSize {
        let stackWidth = contentStack.fittingSize.width
        let padding = showsSurface ? 2 * Self.horizontalPadding : 0
        return NSSize(width: stackWidth + padding, height: Self.height)
    }

    /// Re-publish the intrinsic size whenever the label / glyph changes width,
    /// so the chrome row re-lays out the pill. Pickers call this after mutating
    /// the label.
    func contentDidChange() {
        invalidateIntrinsicContentSize()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Hover overlay tracks the button's bounds (the surface fills the
        // bounds). Wrapped so a resize never crossfades the overlay frame.
        guard let hoverOverlay else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverOverlay.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Tracking area / hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    private func setHovering(_ value: Bool) {
        guard let hoverOverlay, value != hovering else { return }
        hovering = value
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverOverlay.presentation()?.opacity ?? hoverOverlay.opacity
        anim.toValue = value ? 1 : 0
        anim.duration = Self.hoverAnimationDuration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        hoverOverlay.add(anim, forKey: "opacity")
        hoverOverlay.opacity = value ? 1 : 0
    }

    // MARK: - Click → action (non-blocking press tracking)

    /// Whether the current drag is over the button bounds — set in
    /// `mouseDown`/`mouseDragged`, read in `mouseUp`. Tracking across separate
    /// event deliveries (NOT a synchronous `nextEvent(matching:)` pump) keeps
    /// the main runloop draining dispatch / Observation / CoreAnimation work
    /// between drag events. The chrome row shares the runloop with the
    /// transcript-swap `CATransaction` + the `isRunning` sink, so a press on a
    /// chrome pill must never block the beforeWaiting flush (SendStopButton
    /// adopted the same stateful pattern; a `nextEvent` pump would stall an
    /// in-flight crossfade until mouse-up).
    private var isPressInside = false

    override func mouseDown(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressInside else { return }
        isPressInside = false
        // Match `Button(action:)`: fire on a mouse-up that lands inside.
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
        actionHandler?()
    }

    /// A closure the picker wires to toggle its popover, in addition to the
    /// standard target/action (so the picker doesn't need a selector seam).
    var actionHandler: (() -> Void)?

    // MARK: - Appearance re-resolve (R14)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard hoverOverlay != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyHoverOverlayColor()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        hoverOverlay?.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    /// Resolve `labelColor @ 0.08` against the current appearance —
    /// `CALayer.backgroundColor` freezes on a dark/light flip (R14).
    private func applyHoverOverlayColor() {
        guard let hoverOverlay else { return }
        var resolved: CGColor = NSColor.labelColor.withAlphaComponent(Self.hoverOverlayAlpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.withAlphaComponent(Self.hoverOverlayAlpha).cgColor
        }
        hoverOverlay.backgroundColor = resolved
    }

    // MARK: - Test-observation points (read-only; no production consumers)

    /// The hover overlay's current opacity (0 unhovered, 1 hovered). Read by
    /// tests to assert the hover state without a snapshot. -1 when the button
    /// has no surface / hover overlay (bare ContextRing trigger).
    var resolvedHoverOpacity: Float { hoverOverlay?.opacity ?? -1 }

    /// The hover overlay's resolved fill color (re-resolved on appearance flip).
    var resolvedHoverColor: CGColor? { hoverOverlay?.backgroundColor }
}

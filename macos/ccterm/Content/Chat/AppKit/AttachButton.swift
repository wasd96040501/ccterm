import AppKit

/// AppKit replacement for the (now-deleted) SwiftUI attach button (migration
/// plan §4.1-10,
/// component-mapping table). A standalone 32pt circle backed by the Phase-0
/// `BarSurfaceView(cornerRadius: 16, drawsShadow: false)` (the shadowless
/// glass circle that matched the original's `surface`), with a centered `+`
/// template image.
///
/// The SwiftUI original used a single-item `Menu` ("Attach Image or File")
/// that drove the host's `NSOpenPanel`; per §4.1-10 that collapses to a
/// direct click → `onPick` (the controller opens `NSOpenPanel`). The
/// `.buttonStyle(.plain)` press-dim is reimplemented by lowering the `+`
/// template alpha to ~0.5 on `mouseDown` (the glass circle stays solid).
///
/// The dashed accent drop-target stroke (accent,
/// `lineWidth 1.5, dash [4,3]`) is drawn as a `CAShapeLayer` overlay toggled
/// by `isDropTargeted`; the idle 0.5pt `separatorColor` stroke is the
/// `BarSurfaceView`'s own border, so we only add the *drop* stroke here.
final class AttachButton: NSControl {

    /// 32pt circle (`AttachButton.size = 32`).
    static let size: CGFloat = 32
    /// `+` glyph point size + weight (`AttachButton.swift:41` — 13pt,
    /// `.semibold`).
    private static let iconPointSize: CGFloat = 13

    /// Fired on a plain click. The controller opens `NSOpenPanel`.
    var onPick: (() -> Void)?

    /// Drives the dashed accent drop-target stroke. Toggled by the bar via
    /// `setDropTargeted(_:in:)` inside the SAME `NSAnimationContext` group as
    /// the pill's stroke so they animate in sync (§4.1-9).
    private(set) var isDropTargeted: Bool = false

    private let surface = BarSurfaceView(cornerRadius: AttachButton.size / 2, drawsShadow: false)
    private let iconView = NSImageView()
    private let dropStrokeLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        // Template + `.labelColor` so it tracks light/dark like SwiftUI's
        // `.foregroundStyle(.primary)`.
        iconView.image?.isTemplate = true
        iconView.contentTintColor = .labelColor
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Drop-target stroke on top of the surface, hidden until targeted.
        dropStrokeLayer.fillColor = nil
        dropStrokeLayer.lineWidth = 1.5
        dropStrokeLayer.lineDashPattern = [4, 3]
        dropStrokeLayer.isHidden = true
        dropStrokeLayer.opacity = 0
        layer?.addSublayer(dropStrokeLayer)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Attach image or file"))
        toolTip = String(localized: "Attach Image or File")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    /// Fixed 32×32 — the bar lays it out at the bottom-left.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }

    /// The `+` glyph's current alpha (1.0 idle / ~0.5 while pressed) and the
    /// glass circle's alpha — TEST-OBSERVATION GETTERS (read-only) surfacing
    /// the press-dim invariant (the `+` dims while the circle stays solid,
    /// §4.1-10). No production code reads these; they follow the documented
    /// `BarSurfaceView.glassCornerRadius` test-observation-getter precedent.
    var glyphAlphaForTestObservation: CGFloat { iconView.alphaValue }
    var surfaceAlphaForTestObservation: CGFloat { surface.alphaValue }

    // MARK: - Press feedback + click (non-blocking press tracking)

    /// Whether the current drag is over the button bounds — set in
    /// `mouseDown`/`mouseDragged`, read in `mouseUp`. Tracked across separate
    /// event deliveries (NOT a synchronous `nextEvent(matching:)` pump) so the
    /// main runloop keeps draining dispatch / Observation / CoreAnimation work
    /// between drag events.
    private var isPressInside = false

    override func mouseDown(with event: NSEvent) {
        // Press-dim: lower the `+` template alpha; the glass circle stays
        // solid (matching SwiftUI `.buttonStyle(.plain)`'s icon-only dim).
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
        iconView.alphaValue = isPressInside ? 0.5 : 1.0
    }

    override func mouseDragged(with event: NSEvent) {
        // Track the drag so the dim follows the cursor and we only fire
        // `onPick` when the mouse-up lands inside (standard NSButton semantics).
        isPressInside = bounds.contains(convert(event.locationInWindow, from: nil))
        iconView.alphaValue = isPressInside ? 0.5 : 1.0
    }

    override func mouseUp(with event: NSEvent) {
        iconView.alphaValue = 1.0
        guard isPressInside else { return }
        isPressInside = false
        onPick?()
    }

    // MARK: - Drop stroke

    override func layout() {
        super.layout()
        dropStrokeLayer.frame = bounds
        dropStrokeLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        applyDropStrokeColor()
    }

    /// Toggle the dashed accent ring inside the bar's shared
    /// `NSAnimationContext` group (`ctx`), so the pill stroke + this ring fade
    /// together at `.easeOut(0.12)` (§4.1-9). Opacity-driven so the dashed
    /// stroke never pops.
    func setDropTargeted(_ targeted: Bool, in ctx: NSAnimationContext) {
        guard targeted != isDropTargeted else { return }
        isDropTargeted = targeted
        dropStrokeLayer.isHidden = false
        applyDropStrokeColor()
        // The caller's group already supplies duration/timing; just write the
        // animatable target under `allowsImplicitAnimation`.
        dropStrokeLayer.opacity = targeted ? 1 : 0
    }

    private func applyDropStrokeColor() {
        var resolved: CGColor = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.cgColor
        }
        dropStrokeLayer.strokeColor = resolved
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyDropStrokeColor()
        CATransaction.commit()
    }
}

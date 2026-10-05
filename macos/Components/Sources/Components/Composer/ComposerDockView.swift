import AppKit

/// What lies under a session tab's floating composer (design 08 *The card*,
/// `.lv-dock`): the transcript scrolls under it, fading out over the 24 pt
/// above the card and gone beside and below it, so the card stands on the
/// window's colour. Clicks and scrolling pass through to the transcript.
public final class ComposerDockView: NSView {
    /// How far above the card the transcript starts to fade.
    public static let fade: CGFloat = 24

    private let gradient = CAGradientLayer()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradient)
        // Opaque at the bottom (y up), clear at the top.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let window = NSColor.windowBackgroundColor
            gradient.colors = [window.cgColor, window.cgColor, window.withAlphaComponent(0).cgColor]
        }
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let solid = bounds.height > 0 ? max(0, 1 - Self.fade / bounds.height) : 0
        gradient.locations = [0, NSNumber(value: Double(solid)), 1]
        CATransaction.commit()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

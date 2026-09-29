import AppKit

/// One square of a list's + | − bar, as System Settings draws them: 20 × 20,
/// radius 5, a 10-point glyph, no fill at rest. The pointer over it fills
/// the square (black 5 % / white 8 %), a press deepens the fill (black 12 % /
/// white 18 %). Disabled, the glyph dims and nothing fills.
@MainActor
final class ListBarButton: NSButton {
    static let side: CGFloat = 20

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(symbol: String, label: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        focusRingType = .none
        contentTintColor = .labelColor
        toolTip = label
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovered = false }
            contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: NSColor = dark ? .white : .black
        let alpha: CGFloat
        switch (isEnabled, isHighlighted, isHovered) {
        case (false, _, _): alpha = 0
        case (_, true, _): alpha = dark ? 0.18 : 0.12
        case (_, _, true): alpha = dark ? 0.08 : 0.05
        default: alpha = 0
        }
        layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

/// The 1 × 12 divider between the bar's buttons.
@MainActor
final class ListBarDividerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
}

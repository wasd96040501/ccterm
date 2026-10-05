import AppKit

/// One square of a list's + | − bar: a borderless 20 × 20 button with a
/// 10-point glyph. It draws nothing of its own — a press darkens the glyph as
/// any borderless button's does. Disabled, the glyph dims.
@MainActor
final class ListBarButton: NSButton {
    static let side: CGFloat = 20

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
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor }
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

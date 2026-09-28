import AppKit

/// The rounded fill a transcript card sits on: the code card's fill
/// (`tertiarySystemFill`) and a slightly larger radius, so a card reads as a
/// sibling of the code blocks around it rather than as a panel on top.
@MainActor
class CardSurfaceView: NSView {
    static let cornerRadius: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
    }
}

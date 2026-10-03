import AppKit

/// The 1-point hairline a form draws between rows and above a bar, in
/// `formSeparator`.
@MainActor
public final class FormHairlineView: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.formSeparator.cgColor
    }
}

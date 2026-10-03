import AppKit

/// What a Settings pane's content stands on: the window's background, with the
/// content `inset` in from every edge — the pane itself, at the pane's width,
/// whatever the card under it is drawn with.
final class PaneView: NSView {
    init(_ content: NSView, inset amount: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: amount),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: amount),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -amount),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -amount),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

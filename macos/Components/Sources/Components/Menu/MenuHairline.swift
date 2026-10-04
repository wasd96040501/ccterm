import AppKit

/// A 0.5-pt line in the separator colour of plain Light or Dark (`plain`): the
/// material's vibrant appearance would hand it an opaque grey.
final class MenuHairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var allowsVibrancy: Bool { false }

    // Painted when it joins a window and when the appearance flips, not in
    // `updateLayer`: a line laid out after its first display pass never got one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

import AppKit

/// A row of a card that responds to the pointer the way a source list row
/// does: a soft fill under the pointer, a step deeper while pressed, and a
/// click reported on release inside — with its click count, so a double-click
/// can mean "keep it open".
///
/// The owning card sets ``onClick``; the row never knows what a click means.
@MainActor
class PressableRowView: NSView {
    /// `clickCount` is AppKit's: 2 for the second press of a double-click.
    var onClick: ((_ clickCount: Int) -> Void)?

    /// Off, the row ignores the pointer — a step with nothing to open.
    var isPressable = true {
        didSet {
            guard isPressable != oldValue else { return }
            if !isPressable { isHovered = false }
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    /// Inset of the fill from the row's edges.
    var highlightInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Forgets the pointer: a recycled row starts un-hovered.
    func resetHighlight() {
        isHovered = false
        isPressed = false
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isPressable, isHovered || isPressed else { return }
        let rect = NSRect(
            x: highlightInsets.left, y: highlightInsets.top,
            width: bounds.width - highlightInsets.left - highlightInsets.right,
            height: bounds.height - highlightInsets.top - highlightInsets.bottom)
        NSColor.labelColor.withAlphaComponent(isPressed ? 0.1 : 0.05).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    // MARK: - Pointer

    /// A press anywhere on a pressable row is the row's, labels included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return isPressable ? self : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isPressable
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isPressable else { return super.mouseDown(with: event) }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressable else { return super.mouseDragged(with: event) }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressable else { return super.mouseUp(with: event) }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?(event.clickCount) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetHighlight()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { isPressable ? .button : .staticText }

    override func accessibilityPerformPress() -> Bool {
        guard isPressable else { return false }
        onClick?(1)
        return true
    }
}

import AppKit

/// The + at the trailing end of an editor's tab bar: a 24-point circle in the
/// quietest system fill with a 10-point plus in secondary ink, Ghostty's
/// control at the bar's scale. The pointer over it lifts the fill one step and
/// the plus to label ink; pressed, one step more.
///
/// Draws only; what pressing it does is its target's.
final class NewTabButton: NSButton {

    /// The circle's diameter.
    static let side: CGFloat = 24

    private var isPointerInside = false {
        didSet { refresh() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        bezelStyle = .smallSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = Self.plus
        focusRingType = .none
        let name = String(localized: "New Tab", bundle: .module)
        toolTip = name + " ⌘T"
        setAccessibilityLabel(name)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// The circle is the frame: a bezelled button's own insets would make the
    /// constrained 24 points the circle plus a margin.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// A plus whose symbol alignment rect is its ink, so centring the image
    /// centres the plus. The sheet's plus is 10 pt from tip to tip at a 1.4-pt
    /// stroke; the symbol's ink is about 0.83 of its point size.
    private static let plus: NSImage? = {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        image?.alignmentRect = NSRect(origin: .zero, size: image?.size ?? .zero)
        return image
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    /// Hidden with its bar, it is not under the pointer any more.
    override func viewDidHide() {
        super.viewDidHide()
        isPointerInside = false
    }

    override var isHighlighted: Bool {
        didSet { refresh() }
    }

    /// The pointer over it, or pressed: the ink and the fill one step each.
    var isLifted: Bool { isPointerInside || isHighlighted }

    private func refresh() {
        contentTintColor = isLifted ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isHighlighted ? .pressedFill : isPointerInside ? .hoverFill : .restingFill
        fill.setFill()
        let circle = NSBezierPath(ovalIn: bounds)
        circle.fill()
        // A hairline of separator just inside the circle (the sheet's inset
        // 0.5-pt ring). `withAlphaComponent` would replace the separator's own
        // alpha, not scale it.
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
        super.draw(dirtyRect)
    }
}

extension NSColor {

    /// The + at rest: the quietest of the system's fills.
    fileprivate static var restingFill: NSColor {
        if #available(macOS 14.0, *) { return .quaternarySystemFill }
        return NSColor.labelColor.withAlphaComponent(0.027)
    }

    /// The + under the pointer: one step up.
    fileprivate static var hoverFill: NSColor {
        if #available(macOS 14.0, *) { return .tertiarySystemFill }
        return NSColor.labelColor.withAlphaComponent(0.047)
    }

    /// The + pressed: one more.
    fileprivate static var pressedFill: NSColor {
        if #available(macOS 14.0, *) { return .secondarySystemFill }
        return NSColor.labelColor.withAlphaComponent(0.078)
    }
}

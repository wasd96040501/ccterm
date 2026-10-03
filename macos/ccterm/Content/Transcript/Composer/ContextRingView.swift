import AppKit

/// The context ring (design 08 *Context*): a 14-pt ring filled to the
/// fraction of the context in use, its percentage after it, in the status
/// slot once the context is half full. A click opens `/context` beside.
/// The ring is a measured shape — its arc is the number — so it is drawn.
@MainActor
final class ContextRingView: NSView {
    var onPress: (() -> Void)?

    private let ring = RingShape()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        ring.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        addSubview(label)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 14),
            ring.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `fraction` of the ring and `text` after it. Idempotent.
    func configure(fraction: Double, text: String, toolTip: String?) {
        ring.fraction = fraction
        label.stringValue = text
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip ?? text)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The ring itself: a 2-pt track and an arc from the top, clockwise.
private final class RingShape: NSView {
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let radius: CGFloat = 5.5 * bounds.width / 14
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.composerTile.setStroke()
            track.stroke()
            guard fraction > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(fraction, 1),
                clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.secondaryLabelColor.setStroke()
            arc.stroke()
        }
    }
}

import AppKit

/// The context ring (design 08 *Context*): a 14-pt ring filled to the
/// fraction of the context in use, its percentage after it, in the status
/// slot once the context is half full. AppKit's accessory-bar button — its
/// bezel under the pointer, acting on release — whose press opens `/context`
/// beside. The ring is a measured shape — its arc is the number — so its
/// image is drawn.
@MainActor
final class ContextRingButton: NSButton {
    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .accessoryBar
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageLeading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `fraction` of the ring and `text` after it. Idempotent.
    func configure(fraction: Double, text: String, toolTip: String?) {
        image = Self.ring(fraction)
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip ?? text)
    }

    /// The ring at `fraction`, drawn whenever the button draws, in its
    /// appearance.
    private static func ring(_ fraction: Double) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { bounds in
            RingShape.draw(fraction, in: bounds)
            return true
        }
    }
}

/// The ring itself: a 2-pt track and an arc from the top, clockwise.
private enum RingShape {
    static func draw(_ fraction: Double, in bounds: NSRect) {
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

import AppKit

/// A live session's state, one small mark at the row's trailing edge or in a
/// tab's close-button slot (design 08 `.dotmark`, `.arcmark`): idle a quiet
/// 6-pt dot, needs-input a 7-pt coral dot, failed a 7-pt red one, and
/// responding an 11-pt ring with an arc travelling it — the tile's motion,
/// since a running thing moves and isn't coloured. On a selected, focused row
/// every mark is white, as the icon is. Reduce Motion stills the arc.
final class ActivityMarkView: NSView {
    /// The width and height of the mark's slot.
    static let slot: CGFloat = 14

    private let shape = CAShapeLayer()
    /// Under the arc, the whole ring it travels.
    private let track = CAShapeLayer()

    /// The arc mark is the sheet's 12-unit circle (r 4.6, stroke 1.5) drawn 11 pt big.
    private static let arcRadius: CGFloat = 4.6 * 11 / 12
    private static let arcWidth: CGFloat = 1.5 * 11 / 12
    /// The arc's share of the ring: a dash of 9 on a circumference of 2π · 4.6.
    private static let arcLength: CGFloat = 9 / (2 * .pi * 4.6)

    var activity: SessionState.Activity? {
        didSet {
            guard activity != oldValue else { return }
            setAccessibilityLabel(activity?.accessibilityLabel)
            update()
        }
    }

    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(shape)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.slot, height: Self.slot) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    override func layout() {
        super.layout()
        // The shape is its own centred square, so the arc turns about its middle.
        let side = Self.slot
        for layer in [track, shape] {
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func update() {
        isHidden = activity == nil
        let side = Self.slot
        let diameter: CGFloat =
            switch activity {
            case .responding: Self.arcRadius * 2
            case .idle: 6
            default: 7
            }
        let path = CGPath(
            ellipseIn: CGRect(x: (side - diameter) / 2, y: (side - diameter) / 2, width: diameter, height: diameter),
            transform: nil)
        shape.path = path
        track.path = path
        needsDisplay = true
        animate()
    }

    /// Colours are resolved here, in the view's appearance, so they follow
    /// light and dark.
    private func paint() {
        let colour: NSColor? =
            switch activity {
            // `withAlphaComponent` replaces the colour's alpha; the dot is
            // secondary ink at 55 % of its own.
            case .idle: NSColor.secondaryLabelColor.scalingAlpha(by: 0.55)
            case .responding: .secondaryLabelColor
            case .needsInput: NSColor(resource: .sidebarCoral)
            case .failed: .systemRed
            case nil: nil
            }
        // The white of a selected row, quieter for the quiet dot.
        let ink = isEmphasized ? NSColor.white.withAlphaComponent(activity == .idle ? 0.55 : 1) : colour
        if case .responding = activity {
            shape.fillColor = nil
            shape.strokeColor = ink?.cgColor
            shape.lineWidth = Self.arcWidth
            shape.lineCap = .round
            shape.strokeStart = 0
            shape.strokeEnd = Self.arcLength
            track.isHidden = false
            track.fillColor = nil
            track.lineWidth = Self.arcWidth
            track.strokeColor = (isEmphasized ? NSColor.white.withAlphaComponent(0.3) : .secondarySystemFill).cgColor
        } else {
            shape.fillColor = ink?.cgColor
            shape.strokeColor = nil
            shape.strokeEnd = 1
            track.isHidden = true
        }
    }

    private func animate() {
        shape.removeAllAnimations()
        guard case .responding = activity, window != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        shape.add(turn, forKey: "turn")
    }
}

extension NSColor {
    /// This colour with its alpha scaled, resolved in the current appearance.
    fileprivate func scalingAlpha(by factor: CGFloat) -> NSColor {
        let resolved = usingColorSpace(.sRGB) ?? self
        return resolved.withAlphaComponent(resolved.alphaComponent * factor)
    }
}

extension SessionState.Activity {
    /// What VoiceOver says of a mark.
    var accessibilityLabel: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .responding: String(localized: "Responding")
        case .needsInput: String(localized: "Needs Your Input")
        case .failed: String(localized: "Failed")
        }
    }
}

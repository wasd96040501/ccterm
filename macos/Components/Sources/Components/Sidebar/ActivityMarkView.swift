import AppKit
import DisplayModels

/// A live session's state, one small mark at the row's trailing edge
/// (design/sidebar-icons): idle a quiet dot, needs-input a coral dot, failed
/// a red one, and responding a ring with an arc travelling it — the
/// tile's motion, since a running thing moves and isn't coloured. On a
/// selected, focused row every mark is white, as the icon is. Reduce Motion
/// stills the arc.
public final class ActivityMarkView: NSView {
    /// The width and height of the mark's slot.
    static let slot: CGFloat = 14

    private let shape = CAShapeLayer()

    public var activity: SidebarActivity? {
        didSet {
            guard activity != oldValue else { return }
            setAccessibilityLabel(activity?.accessibilityLabel)
            update()
        }
    }

    public var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        update()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.slot, height: Self.slot) }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    public override func layout() {
        super.layout()
        // The shape is its own centred square, so the arc turns about its middle.
        let side = Self.slot
        shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func update() {
        isHidden = activity == nil
        let side = Self.slot
        let path = CGMutablePath()
        if case .responding = activity {
            path.addEllipse(in: CGRect(x: 2, y: 2, width: side - 4, height: side - 4))
        } else {
            path.addEllipse(in: CGRect(x: (side - 6) / 2, y: (side - 6) / 2, width: 6, height: 6))
        }
        shape.path = path
        needsDisplay = true
        animate()
    }

    /// Colours are resolved here, in the view's appearance, so they follow
    /// light and dark.
    private func paint() {
        let colour: NSColor? =
            switch activity {
            case .idle: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            case .responding: .secondaryLabelColor
            case .needsInput: NSColor.sidebarCoral
            case .failed: .systemRed
            case nil: nil
            }
        // The white of a selected row, quieter for the quiet dot.
        let ink = isEmphasized ? NSColor.white.withAlphaComponent(activity == .idle ? 0.55 : 1) : colour
        if case .responding = activity {
            shape.fillColor = nil
            shape.strokeColor = ink?.cgColor
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.strokeStart = 0
            shape.strokeEnd = 1.0 / 3
        } else {
            shape.fillColor = ink?.cgColor
            shape.strokeColor = nil
            shape.strokeEnd = 1
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

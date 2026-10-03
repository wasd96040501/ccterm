import AppKit
import Components

/// The filter over a menu's list (`.mfilter`): 26 pt tall, the control radius,
/// the hover fill with a hairline inside its edge, a 12-pt magnifier in
/// tertiary 8 pt in, then 13-pt words 6 pt after it. While it has the
/// keyboard, a 1-pt accent ring at 50 % over a 3.5-pt halo at 18 % sit outside
/// its edge in place of the hairline.
final class MenuFilterField: NSView {
    static let height: CGFloat = 26

    let field = NSTextField()
    private let magnifier = NSImageView()
    private let ring = CALayer()
    private let halo = CALayer()

    /// Whether the focus ring shows: the field is being edited.
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        for edge in [halo, ring] {
            edge.cornerCurve = .continuous
            layer?.addSublayer(edge)
        }
        ring.borderWidth = 1
        halo.borderWidth = 3.5

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        magnifier.contentTintColor = .tertiaryLabelColor
        magnifier.imageScaling = .scaleNone

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        for view in [magnifier, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            magnifier.widthAnchor.constraint(equalToConstant: 12),
            magnifier.heightAnchor.constraint(equalToConstant: 12),
            magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The text field's cell keeps 2 pt before its words: 6 after the glyph.
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The tertiary words while it is empty.
    var placeholder: String = "" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer?.borderColor = isFocused ? NSColor.clear.cgColor : NSColor.separatorColor.cgColor
            ring.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            halo.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }
        ring.isHidden = !isFocused
        halo.isHidden = !isFocused
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: -1, dy: -1)
        ring.cornerRadius = CornerRadius.control + 1
        // Both spread from the edge, the ring over the halo's first point.
        halo.frame = bounds.insetBy(dx: -3.5, dy: -3.5)
        halo.cornerRadius = CornerRadius.control + 3.5
        CATransaction.commit()
    }
}

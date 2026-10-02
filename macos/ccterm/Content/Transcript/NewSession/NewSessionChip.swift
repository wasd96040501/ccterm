import AppKit

/// A borderless control of the New view (design 08 *The New view*): a title
/// with an optional glyph and chevron that gets a quiet fill under the pointer —
/// the folder pop-up (22 pt semibold), the branch pop-up and the Worktree
/// toggle (12 pt). `menu`, when set, is popped on press as a pop-up button's
/// is; otherwise a press that ends inside sends `action` (the branch popover,
/// the toggle).
///
/// A dumb view: it shows the title, glyph and state it is given and reports a
/// press.
@MainActor
final class NewSessionChip: NSControl {
    /// A chip's metrics.
    struct Look {
        var font: NSFont
        var insets: NSEdgeInsets
        /// The control's height; `nil` fits the content.
        var height: CGFloat?
        var spacing: CGFloat
        var chevronSize: CGFloat
        var glyphSize: CGFloat

        /// The folder: the page's title.
        static let folder = Look(
            font: .systemFont(ofSize: 22, weight: .semibold),
            insets: NSEdgeInsets(top: 1, left: 10, bottom: 1, right: 8),
            height: nil, spacing: 6, chevronSize: 11, glyphSize: 0)
        /// Branch and Worktree: 24-pt controls.
        static let row = Look(
            font: .systemFont(ofSize: 12),
            insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8),
            height: 24, spacing: 4, chevronSize: 10, glyphSize: 11)
    }

    private static let radius: CGFloat = 7

    var title: String {
        didSet {
            titleField.stringValue = title
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
        }
    }

    var glyph: NSImage? {
        didSet {
            glyphView.image = glyph
            glyphView.isHidden = glyph == nil
        }
    }

    /// Accent-tinted: the Worktree toggle when on.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            refresh()
        }
    }

    /// Held in its pressed look while its menu or popover is open.
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            refresh()
        }
    }

    private let look: Look
    private let showsChevron: Bool
    private var isHovered = false
    private var isPressed = false

    private lazy var titleField: NSTextField = {
        let field = NSTextField(labelWithString: title)
        field.font = look.font
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private lazy var glyphView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: look.glyphSize, weight: .regular)
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var chevronView: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: look.chevronSize, weight: .bold)
        view.contentTintColor = .tertiaryLabelColor
        view.isHidden = !showsChevron
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var content: NSStackView = {
        let stack = NSStackView(views: [glyphView, titleField, chevronView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = look.spacing
        stack.edgeInsets = look.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    init(title: String, look: Look, showsChevron: Bool = true) {
        self.title = title
        self.look = look
        self.showsChevron = showsChevron
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let height = look.height {
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize { content.fittingSize }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Look

    private var isActive: Bool { isHovered || isPressed || isOpen }

    private var fill: NSColor {
        if isOn { return NSColor.controlAccentColor.withAlphaComponent(isActive ? 0.20 : 0.14) }
        return isActive ? .quaternarySystemFill : .clear
    }

    private func refresh() {
        let ink: NSColor = isOn ? .controlAccentColor : (isActive ? .labelColor : .secondaryLabelColor)
        // The folder is the page's title: always label ink.
        titleField.textColor = look.height == nil ? .labelColor : ink
        glyphView.contentTintColor = ink
        needsDisplay = true
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let menu {
            isPressed = true
            isOpen = true
            refresh()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: self)
            isPressed = false
            isOpen = false
            refresh()
            return
        }
        isPressed = true
        refresh()
        // Track like a button: the press counts when it ends inside.
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                refresh()
                if inside { sendAction(action, to: target) }
                return
            }
            if inside != isPressed {
                isPressed = inside
                refresh()
            }
        }
        isPressed = false
        refresh()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        if let menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: self)
        } else {
            sendAction(action, to: target)
        }
        return true
    }
}

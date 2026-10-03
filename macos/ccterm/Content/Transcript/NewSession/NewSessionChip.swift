import AppKit
import Components

/// A borderless control of the New view (design 08 *The New view*): a title
/// with an optional glyph and chevron that gets a quiet fill under the pointer —
/// the folder pop-up (22 pt semibold), the branch pop-up and the Worktree
/// toggle (12 pt). A pop-up sends `action` on press, as the composer's chips
/// do, and its owner opens the menu (`MenuPanel`); the toggle sends it when a
/// press ends inside.
///
/// A dumb view: it shows the title, glyph and state it is given and reports a
/// press.
@MainActor
final class NewSessionChip: NSControl {
    /// A chip's metrics.
    struct Look {
        var font: NSFont
        /// Letter spacing, points.
        var tracking: CGFloat = 0
        var insets: NSEdgeInsets
        /// The control's height; the words are centred in it.
        var height: CGFloat
        var spacing: CGFloat
        /// The chevron's box, points.
        var chevronSize: CGFloat
        /// The page's title: label ink whatever its state.
        var isTitle = false

        /// The folder: the page's title, 22 pt at weight 650 and −0.01 em, in
        /// the design's line (22 × 1.45) plus 1 pt above and below.
        static let folder = Look(
            font: titleFont, tracking: -0.22,
            insets: NSEdgeInsets(top: 1, left: 10, bottom: 1, right: 8),
            height: 34, spacing: 6, chevronSize: 11, isTitle: true)
        /// SF at weight 650, between Semibold and Bold, on the font's weight
        /// axis — `systemFont(ofSize:weight:)` snaps to a named weight.
        private static let titleFont: NSFont = {
            let wght = 0x7767_6874
            let descriptor = NSFont.systemFont(ofSize: 22).fontDescriptor.addingAttributes([
                NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: 650]
            ])
            return NSFont(descriptor: descriptor, size: 22) ?? .systemFont(ofSize: 22, weight: .semibold)
        }()

        /// Branch and Worktree: 24-pt controls.
        static let row = Look(
            font: .systemFont(ofSize: 12),
            insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8),
            height: 24, spacing: 4, chevronSize: 10)
    }

    private static let radius = CornerRadius.control

    private static let truncatingMiddle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    var title: String {
        didSet {
            refresh()
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

    /// A pop-up: the action goes on press, not on release.
    var sendsActionOnPress = false

    /// Held in its pressed look while its menu is open.
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

    /// The glyph at the size its image carries.
    private lazy var glyphView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The design's `chev2`, in its CSS box.
    private lazy var chevronView: NSImageView = {
        let image = NSImage(resource: .newViewChevron).copy() as? NSImage ?? NSImage(resource: .newViewChevron)
        image.size = NSSize(width: look.chevronSize, height: look.chevronSize)
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
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
        heightAnchor.constraint(equalToConstant: look.height).isActive = true
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
        titleField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: look.font, .kern: look.tracking, .foregroundColor: look.isTitle ? .labelColor : ink,
                .paragraphStyle: Self.truncatingMiddle,
            ])
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
        if sendsActionOnPress {
            sendAction(action, to: target)
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
        sendAction(action, to: target)
        return true
    }
}

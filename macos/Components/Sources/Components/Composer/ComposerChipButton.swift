import AppKit
import DisplayModels

/// One of the composer's pull-downs (design 08 *The accessory row*): borderless,
/// 24 pt tall, 12-pt secondary words with their glyphs and a small chevron; a
/// hover fill. Pressing it asks its owner to open the menu or the panel — it
/// shows its menu's state (`isOpen`) so the fill stays while it is up.
///
/// When the composer narrows the owner drops the words the glyph already says
/// (`Tier`): the provider's name first, then Effort's and Mode's names.
@MainActor
final class ComposerChipButton: NSButton {
    /// How much of its words a chip keeps.
    enum Tier: Int, Comparable {
        case full
        /// The provider's name is gone.
        case withoutDetail
        /// Droppable titles are gone too; only glyphs remain.
        case glyphsOnly

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let height: CGFloat = 24

    /// Set while the chip's menu or panel is up.
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            needsDisplay = true
        }
    }

    var tier = Tier.full {
        didSet {
            guard tier != oldValue else { return }
            applyTier()
        }
    }

    private var chip: ComposerPresentation.Chip?
    private var isHovered = false

    private let stack = NSStackView()
    private let leadingGlyphs = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trailingGlyph = NSImageView()
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        sendAction(on: [.leftMouseDown])
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.control
        layer?.cornerCurve = .continuous
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        leadingGlyphs.orientation = .horizontal
        leadingGlyphs.spacing = 4
        leadingGlyphs.alignment = .centerY
        for label in [titleLabel, detailLabel] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byClipping
            // The words keep their width over everything but the window's: the
            // composer drops them by tier when it narrows (`ComposerView.layout`),
            // so they are never cut — and never what widens the window.
            label.setContentCompressionResistancePriority(.dragThatCannotResizeWindow, for: .horizontal)
        }
        trailingGlyph.imageScaling = .scaleNone
        chevron.image = ComposerGlyph.chevron
        chevron.imageScaling = .scaleNone
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        // preview-live.css `.chip`: 8 in from each side, 4 between every item.
        stack.setViews([leadingGlyphs, titleLabel, detailLabel, trailingGlyph, chevron], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    // MARK: - Showing

    /// Shows `chip`. Idempotent.
    func configure(with chip: ComposerPresentation.Chip) {
        self.chip = chip
        isEnabled = chip.isEnabled
        toolTip = chip.toolTip
        titleLabel.stringValue = chip.title
        detailLabel.stringValue = chip.detail.map { "· \($0)" } ?? ""
        leadingGlyphs.setViews(
            chip.leadingGlyphs.map { glyph in
                let view = NSImageView(image: ComposerGlyph.chipImage(glyph) ?? NSImage())
                view.imageScaling = .scaleNone
                return view
            }, in: .leading)
        trailingGlyph.image = chip.trailingGlyph.flatMap { ComposerGlyph.chipImage($0) }
        chevron.isHidden = !chip.isEnabled
        setAccessibilityLabel(chip.toolTip ?? chip.title)
        setAccessibilityValue(chip.title)
        applyTier()
        updateColors()
    }

    private func applyTier() {
        guard let chip else { return }
        detailLabel.isHidden = chip.detail == nil || tier >= .withoutDetail
        titleLabel.isHidden = chip.titleIsDroppable && tier >= .glyphsOnly
        leadingGlyphs.isHidden = chip.leadingGlyphs.isEmpty
        trailingGlyph.isHidden = chip.trailingGlyph == nil
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let chip else { return }
            let ink: NSColor
            if !chip.isEnabled {
                ink = .tertiaryLabelColor
            } else if chip.isDanger {
                ink = .failureText
            } else {
                ink = isHovered || isOpen ? .labelColor : .secondaryLabelColor
            }
            titleLabel.textColor = ink
            detailLabel.textColor = .tertiaryLabelColor
            for case let view as NSImageView in leadingGlyphs.arrangedSubviews { view.contentTintColor = ink }
            trailingGlyph.contentTintColor = .tertiaryLabelColor
            // `.cv { opacity: .7 }` of the chip's ink — its alpha times 0.7,
            // not 0.7 in place of it.
            let resolved = ink.usingColorSpace(.sRGB) ?? ink
            chevron.contentTintColor = resolved.withAlphaComponent(resolved.alphaComponent * 0.7)
        }
    }

    // MARK: - Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let filled = chip?.isEnabled == true && (isHovered || isOpen)
            layer?.backgroundColor = (filled ? NSColor.composerHover : .clear).cgColor
        }
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The labels and glyphs inside are not targets of their own.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}

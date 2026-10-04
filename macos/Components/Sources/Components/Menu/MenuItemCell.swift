import AppKit

/// An item (`.mi`): the check, the glyph, the title with its subtitle under,
/// and the trailing key, glyph or switch. White on the accent while selected,
/// its quieter parts at 85 %; all tertiary while disabled.
final class MenuItemCell: NSTableCellView {
    var onToggle: ((Bool) -> Void)?

    private let check = NSImageView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let trailingGlyph = NSImageView()
    private let toggle = NSSwitch()

    private var item: MenuContent.Item?
    private var glyphColumn = true
    private lazy var titleLeading = titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: MenuMetrics.wordsX)
    private lazy var subtitleWidth = subtitleLabel.widthAnchor.constraint(equalToConstant: 0)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        check.imageScaling = .scaleNone
        glyph.imageScaling = .scaleProportionallyDown
        trailingGlyph.imageScaling = .scaleProportionallyDown
        titleLabel.font = MenuMetrics.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isSelectable = false
        subtitleLabel.maximumNumberOfLines = 0
        key.font = MenuMetrics.keyFont
        key.lineBreakMode = .byTruncatingHead
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)
        for view in [check, glyph, titleLabel, subtitleLabel, key, trailingGlyph, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let titleLineMiddle = MenuMetrics.rowPadding + MenuMetrics.titleLine / 2
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: MenuMetrics.checkX + MenuMetrics.checkSize / 2),
            check.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.glyphX),
            glyph.widthAnchor.constraint(equalToConstant: MenuMetrics.glyphSize),
            glyph.heightAnchor.constraint(equalToConstant: MenuMetrics.glyphSize),
            glyph.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            titleLeading,
            titleLabel.firstBaselineAnchor.constraint(
                equalTo: topAnchor,
                constant: MenuMetrics.rowPadding
                    + MenuMetrics.baseline(of: MenuMetrics.titleFont, onLine: MenuMetrics.titleLine)),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(
                equalTo: topAnchor, constant: MenuMetrics.rowPadding + MenuMetrics.titleLine),
            subtitleWidth,
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            key.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            key.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: MenuMetrics.keyGap),
            trailingGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            trailingGlyph.widthAnchor.constraint(equalToConstant: 14),
            trailingGlyph.heightAnchor.constraint(equalToConstant: 14),
            trailingGlyph.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            // A switch spans the title and the subtitle (`.mi.tg .k`).
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ item: MenuContent.Item, glyphColumn: Bool) {
        self.item = item
        self.glyphColumn = glyphColumn
        titleLabel.stringValue = item.title
        titleLeading.constant = MenuMetrics.wordsX(glyphColumn: glyphColumn)
        check.isHidden = !item.isChecked
        glyph.image = item.glyph
        glyph.isHidden = item.glyph == nil
        subtitleLabel.isHidden = item.subtitle == nil
        key.isHidden = true
        trailingGlyph.isHidden = true
        toggle.isHidden = true
        switch item.trailing {
        case .none: break
        case .key(let words):
            key.stringValue = words
            key.isHidden = false
        case .glyph(let image):
            trailingGlyph.image = image
            trailingGlyph.isHidden = false
        case .toggle(let isOn):
            toggle.state = isOn ? .on : .off
            toggle.isEnabled = item.isEnabled
            toggle.isHidden = false
        }
        toolTip = item.toolTip
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(item.isChecked ? 1 : 0)
        needsLayout = true
        updateColors()
    }

    override func layout() {
        if let item {
            subtitleWidth.constant = max(
                0, MenuMetrics.subtitleWidth(of: item, menuWidth: bounds.width, glyphColumn: glyphColumn))
            subtitleLabel.preferredMaxLayoutWidth = subtitleWidth.constant
        }
        super.layout()
    }

    private func updateColors() {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized
        let quiet = NSColor.white.withAlphaComponent(0.85)
        let title: NSColor
        let secondary: NSColor
        if !item.isEnabled {
            title = .tertiaryLabelColor
            secondary = .tertiaryLabelColor
        } else if selected {
            title = .white
            secondary = quiet
        } else {
            title = item.isDanger ? .failureText : item.isMore ? .controlAccentColor : .labelColor
            secondary = .secondaryLabelColor
        }
        titleLabel.textColor = title
        check.contentTintColor = title
        glyph.contentTintColor = item.isEnabled && item.isDanger && !selected ? .failureText : secondary
        subtitleLabel.attributedStringValue = MenuMetrics.subtitle(item.subtitle ?? "", color: secondary)
        key.textColor = selected && item.isEnabled ? quiet : .tertiaryLabelColor
        trailingGlyph.contentTintColor = selected && item.isEnabled ? quiet : .tertiaryLabelColor
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }
}

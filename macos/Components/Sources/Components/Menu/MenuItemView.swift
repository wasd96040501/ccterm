import AppKit

/// An item of a menu: a check, a glyph, the title with its subtitle under it,
/// and a key, glyph or switch at the trailing edge. On the selection its words
/// turn white; a disabled item is tertiary throughout.
///
/// The table's inset style puts it 16 pt in from the popover's edges.
final class MenuItemView: NSTableCellView {
    /// The switch was flipped.
    var onToggle: (() -> Void)?

    /// The check's column, then the glyph's, then the words.
    private static let glyphX: CGFloat = 18
    private static let wordsX: CGFloat = 42
    private static let wordsXWithoutGlyphs: CGFloat = 18
    private static let trailingGap: CGFloat = 12
    private static let trailingInset: CGFloat = 4

    private let check = NSImageView()
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let trailingGlyph = NSImageView()
    private let toggle = NSSwitch()
    private lazy var words = NSStackView(views: [title, subtitle])
    private lazy var wordsLeading = words.leadingAnchor.constraint(equalTo: leadingAnchor)
    /// The words end before a switch or a glyph at the trailing edge, which
    /// stand beside both lines; a key stands beside the title alone.
    private lazy var wordsBeforeToggle = words.trailingAnchor.constraint(
        lessThanOrEqualTo: toggle.leadingAnchor, constant: -Self.trailingGap)
    private lazy var wordsBeforeGlyph = words.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingGlyph.leadingAnchor, constant: -Self.trailingGap)

    private var item: MenuContent.Item?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Selected", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.isSelectable = false
        key.font = .systemFont(ofSize: 12)
        // A path gives way in its middle, as the Finder's do.
        key.lineBreakMode = .byTruncatingMiddle
        key.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        for view in [check, glyph, words, key, trailingGlyph, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor),
            check.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.glyphX),
            glyph.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
            wordsLeading,
            words.topAnchor.constraint(equalTo: topAnchor),
            words.bottomAnchor.constraint(equalTo: bottomAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: Self.trailingGap),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            key.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            trailingGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            trailingGlyph.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `item` in a row `width` wide (its table column's, or the
    /// footer's) whose menu keeps the glyph column (`glyphColumn`).
    func configure(_ item: MenuContent.Item, glyphColumn: Bool, width: CGFloat) {
        self.item = item
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        check.isHidden = !item.isChecked
        glyph.image = item.glyph
        glyph.isHidden = item.glyph == nil
        key.isHidden = true
        trailingGlyph.isHidden = true
        toggle.isHidden = true
        var trailingWidth: CGFloat = 0
        switch item.trailing {
        case .none:
            break
        case .key(let words):
            key.stringValue = words
            key.isHidden = false
            trailingWidth = key.intrinsicContentSize.width
        case .glyph(let image):
            trailingGlyph.image = image
            trailingGlyph.isHidden = false
            trailingWidth = image.size.width
        case .toggle(let isOn):
            toggle.state = isOn ? .on : .off
            toggle.isEnabled = item.isEnabled
            toggle.isHidden = false
            trailingWidth = toggle.intrinsicContentSize.width
        }
        wordsBeforeToggle.isActive = !toggle.isHidden
        wordsBeforeGlyph.isActive = !trailingGlyph.isHidden
        let wordsX = glyphColumn ? Self.wordsX : Self.wordsXWithoutGlyphs
        wordsLeading.constant = wordsX
        // The subtitle wraps in what the row leaves it: the row's width less
        // the words' column and the trailing column.
        subtitle.preferredMaxLayoutWidth =
            width - wordsX - Self.trailingInset - (trailingWidth > 0 ? trailingWidth + Self.trailingGap : 0)
        toolTip = item.toolTip
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        updateColors()
    }

    private func updateColors() {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized && item.isEnabled && !item.isToggle
        let ink: NSColor
        let quiet: NSColor
        if !item.isEnabled {
            ink = .tertiaryLabelColor
            quiet = .tertiaryLabelColor
        } else if selected {
            ink = .alternateSelectedControlTextColor
            quiet = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
        } else {
            ink = item.isDanger ? .failureText : .labelColor
            quiet = .secondaryLabelColor
        }
        title.textColor = ink
        check.contentTintColor = ink
        glyph.contentTintColor = item.isDanger && item.isEnabled && !selected ? .failureText : quiet
        subtitle.textColor = quiet
        key.textColor = selected ? quiet : .tertiaryLabelColor
        trailingGlyph.contentTintColor = selected ? quiet : .tertiaryLabelColor
    }

    @objc private func toggled() {
        onToggle?()
    }
}

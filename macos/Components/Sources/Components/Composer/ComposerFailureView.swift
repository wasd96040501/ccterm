import AppKit
import DisplayModels

/// The card's top section when the session's CLI quit (design 08 *Failed*,
/// preview-live.css `.lv-banner`): a 6 % red wash with a hairline under it, a
/// red octagon, the title over the detail — the reason, then stderr's last
/// line in the monospaced face — and the buttons **Show Log**, **Restart**
/// trailing; when the words would get narrower than 220 pt the buttons take a
/// row of their own, still trailing. It reads as a notification does, and is
/// part of the card, not a strip above it: the card clips its corners.
@MainActor
final class ComposerFailureView: NSView {
    var onShowLog: (() -> Void)?
    var onRestart: (() -> Void)?

    /// `.lv-banner .tx { flex: 1 1 220px }`: the words' narrowest before the
    /// buttons wrap.
    private static let narrowestWords: CGFloat = 220
    private static let insets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 12)
    /// `gap: 8px 12px`.
    private static let columnGap: CGFloat = 12
    private static let rowGap: CGFloat = 8

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let textStack = NSStackView()
    private let logButton = BannerButton(title: String(localized: "Show Log", bundle: .module), isDefault: false)
    private let restartButton = BannerButton(title: String(localized: "Restart", bundle: .module), isDefault: true)
    private let buttons = NSStackView()
    private let hairline = NSView()

    private lazy var wideConstraints: [NSLayoutConstraint] = [
        textStack.trailingAnchor.constraint(
            lessThanOrEqualTo: buttons.leadingAnchor, constant: -Self.columnGap),
        buttons.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
        textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom - 1.5),
    ]
    private lazy var narrowConstraints: [NSLayoutConstraint] = [
        textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
        buttons.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: Self.rowGap),
        buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom),
    ]

    /// Whether the buttons have a row of their own.
    private var isNarrow = false {
        didSet {
            guard isNarrow != oldValue else { return }
            NSLayoutConstraint.deactivate(isNarrow ? wideConstraints : narrowConstraints)
            NSLayoutConstraint.activate(isNarrow ? narrowConstraints : wideConstraints)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        icon.image = ComposerGlyph.failure
        icon.imageScaling = .scaleNone
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.isSelectable = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.orientation = .vertical
        // The words take the section's width when the buttons wrap below.
        textStack.setHuggingPriority(.stretches, for: .horizontal)
        textStack.alignment = .leading
        // The sheet's line boxes: the title's is 13 × 1.45 = 18.85 pt, about
        // 3 more than a label's, split above and below its words (the stack
        // starts 1.5 lower and ends 1.5 higher than the banner's padding); the
        // detail's 2-pt gap follows, less the extra line height TextKit puts
        // above a line where CSS splits it.
        textStack.spacing = 2.5
        textStack.setViews([titleLabel, detailLabel], in: .leading)
        logButton.target = self
        logButton.action = #selector(showLog)
        restartButton.target = self
        restartButton.action = #selector(restart)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setViews([logButton, restartButton], in: .leading)
        hairline.wantsLayer = true
        for view in [icon, textStack, buttons, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Claude quit unexpectedly", bundle: .module))
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            // `.oct { align-self: flex-start; margin-top: 1px }`.
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top + 1),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.columnGap),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top + 1.5),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        NSLayoutConstraint.activate(wideConstraints)
    }

    /// Shows `failure`. Idempotent.
    func configure(with failure: ComposerPresentation.Failure) {
        titleLabel.stringValue = failure.title
        detailLabel.attributedStringValue = Self.detail(failure)
        setAccessibilityLabel(failure.title)
        setAccessibilityValue(failure.output.map { "\(failure.detail) · \($0)" } ?? failure.detail)
    }

    /// `.why`: 11 pt secondary, the output in the monospaced face. Its lines
    /// are 15 pt, which the monospaced run's own box grows to 15.5 as the
    /// sheet draws them.
    private static func detail(_ failure: ComposerPresentation.Failure) -> NSAttributedString {
        let line = NSMutableParagraphStyle()
        line.minimumLineHeight = 15.5
        line.maximumLineHeight = 15.5
        let words: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: line,
        ]
        let text = NSMutableAttributedString(string: failure.detail, attributes: words)
        if let output = failure.output {
            text.append(NSAttributedString(string: " · ", attributes: words))
            var code = words
            code[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            text.append(NSAttributedString(string: output, attributes: code))
        }
        return text
    }

    override func layout() {
        // The buttons wrap when the words would get narrower than 220 pt.
        let room =
            bounds.width - Self.insets.left - 16 - Self.columnGap - Self.columnGap - buttons.fittingSize.width
            - Self.insets.right
        let nextNarrow = bounds.width > 0 && room < Self.narrowestWords
        if nextNarrow != isNarrow { isNarrow = nextNarrow }
        // The detail wraps at the words' own width, so its height is its lines'.
        let words = nextNarrow ? room + buttons.fittingSize.width + Self.columnGap : room
        if bounds.width > 0, abs(detailLabel.preferredMaxLayoutWidth - words) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = words
        }
        super.layout()
    }

    @objc private func showLog() { onShowLog?() }
    @objc private func restart() { onRestart?() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.06).cgColor
            hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The banner's buttons, the design's `.abtn` at the banner's size
/// (`.lv-banner .abtn`): a 24-pt capsule, a 12-pt title 12 in from each side;
/// Show Log on the hover fill with a hairline ring outside it, Restart the
/// accent under white.
private final class BannerButton: NSButton {
    private static let height: CGFloat = 24
    private static let padding: CGFloat = 12

    private let isDefault: Bool
    private let ring = CALayer()

    init(title: String, isDefault: Bool) {
        self.isDefault = isDefault
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        clipsToBounds = false
        layer?.cornerRadius = Self.height / 2
        ring.borderWidth = 0.5
        ring.isHidden = isDefault
        layer?.addSublayer(ring)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: isDefault ? .white : NSColor.labelColor,
            ])
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 2 * Self.padding, height: Self.height)
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isDefault ? .controlAccentColor : .composerHover
            let shade: NSColor = isDefault ? .black : .labelColor
            layer?.backgroundColor =
                (isHighlighted ? fill.blended(withFraction: 0.15, of: shade) ?? fill : fill).cgColor
            ring.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.masksToBounds = false
    }

    override func layout() {
        super.layout()
        // `box-shadow: 0 0 0 0.5px`: the ring is outside the capsule.
        ring.frame = bounds.insetBy(dx: -0.5, dy: -0.5)
        ring.cornerRadius = bounds.height / 2 + 0.5
    }
}

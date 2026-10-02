import AppKit

/// The card's top section when the session's CLI quit (design 08 *Failed*): a
/// 6 % red wash with a hairline under it, a red octagon, the title over the
/// detail, and the buttons — **Show Log**, **Restart** — trailing, or under
/// the words when the card is narrow. It reads as a notification does, and is
/// part of the card, not a strip above it: the card clips its corners.
@MainActor
final class ComposerFailureView: NSView {
    var onShowLog: (() -> Void)?
    var onRestart: (() -> Void)?

    /// Below this card width the buttons move under the words.
    static let narrowWidth: CGFloat = 480

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let textStack = NSStackView()
    private let logButton = PillButton(title: String(localized: "Show Log"))
    private let restartButton = PillButton(title: String(localized: "Restart"), isPrimary: true)
    private let buttons = NSStackView()
    private let hairline = NSView()

    private lazy var wideConstraints: [NSLayoutConstraint] = [
        buttons.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12),
        buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        textStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ]
    private lazy var narrowConstraints: [NSLayoutConstraint] = [
        textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        textStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        buttons.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        buttons.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 8),
        buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ]

    var isNarrow = false {
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
        icon.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])))
        icon.imageScaling = .scaleNone
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
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
        setAccessibilityLabel(String(localized: "Claude quit unexpectedly"))
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        NSLayoutConstraint.activate(wideConstraints)
    }

    /// Shows `failure`. Idempotent.
    func configure(with failure: ComposerModel.Failure) {
        titleLabel.stringValue = failure.title
        detailLabel.stringValue = failure.detail
        setAccessibilityLabel(failure.title)
        setAccessibilityValue(failure.detail)
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

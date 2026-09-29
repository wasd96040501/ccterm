import AppKit

/// An account in the Accounts list, 52 tall like a titled row with a
/// description: a 28-point mark (Claude's, or server.rack for a provider), the title over a
/// secondary line, and ⓘ — or a button, or a spinner — at the trailing
/// edge. Not selectable, as System Settings' rows aren't; ⓘ or a double
/// click reports `onOpen`, the button `onAction`. Its context menu is
/// whatever its controller sets as `menu`; the row shows pressed while the
/// menu is open.
@MainActor
final class AccountRowView: NSView {
    /// ⓘ was clicked or the row double-clicked.
    var onOpen: (() -> Void)?
    /// The trailing push button was clicked.
    var onAction: (() -> Void)?

    private var content: AccountRowContent?
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    private let mark = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailing = NSStackView()
    private var markConstraints: [NSLayoutConstraint] = []
    private var noMarkConstraints: [NSLayoutConstraint] = []

    private lazy var infoButton: NSButton = {
        let image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: String(localized: "Details"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(info(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }()

    private lazy var actionButton = NSButton(title: "", target: self, action: #selector(action(_:)))

    private lazy var spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        return spinner
    }()

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with content: AccountRowContent) {
        guard content != self.content else { return }
        self.content = content
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle
        mark.isHidden = content.mark == .none
        if content.mark == .provider {
            mark.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            mark.contentTintColor = .secondaryLabelColor
        } else {
            mark.image = NSImage(named: "ClaudeMark")
            mark.contentTintColor = nil
        }
        mark.alphaValue = content.mark == .claudeDimmed ? 0.45 : 1
        mark.contentFilters = content.mark == .claudeDimmed ? [Self.grayscale] : []
        NSLayoutConstraint.deactivate(content.mark == .none ? markConstraints : noMarkConstraints)
        NSLayoutConstraint.activate(content.mark == .none ? noMarkConstraints : markConstraints)

        for view in trailing.arrangedSubviews {
            trailing.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch content.accessory {
        case .info:
            trailing.addArrangedSubview(infoButton)
        case .button(let title):
            actionButton.title = title
            trailing.addArrangedSubview(actionButton)
        case .progress:
            trailing.addArrangedSubview(spinner)
            spinner.startAnimation(nil)
        }
    }

    private func configureHierarchy() {
        wantsLayer = true
        mark.image = NSImage(named: "ClaudeMark")
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.wantsLayer = true
        mark.layerUsesCoreImageFilters = true
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [mark, titleLabel, subtitleLabel, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 28),
            mark.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10.5),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.heightAnchor.constraint(equalToConstant: 14),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
        ])
        markConstraints = [titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10)]
        noMarkConstraints = [titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)]
        NSLayoutConstraint.activate(noMarkConstraints)
    }

    private static let grayscale: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(0, forKey: kCIInputSaturationKey)
        return filter
    }()

    // MARK: - Events

    @objc private func info(_ sender: Any?) {
        onOpen?()
    }

    @objc private func action(_ sender: Any?) {
        onAction?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, content?.accessory == .info { onOpen?() } else { super.mouseDown(with: event) }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        isPressed = true
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        isPressed = false
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isPressed ? NSColor.labelColor.withAlphaComponent(0.05).cgColor : nil
    }
}

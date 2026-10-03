import AppKit
import DisplayModels

/// An account in the Accounts list, 52 tall like a titled row with a
/// description: a 28-point mark (Claude's, or server.rack for a provider), the title over a
/// secondary line, and ⓘ — or a button, or a spinner — at the trailing
/// edge. Not selectable, as System Settings' rows aren't; ⓘ or a double
/// click reports `onOpen`, the button `onAction`. Its context menu is
/// whatever its controller sets as `menu`; the row shows pressed while the
/// menu is open.
@MainActor
public final class AccountRowView: NSView {
    /// ⓘ was clicked or the row double-clicked.
    public var onOpen: (() -> Void)?
    /// The trailing push button was clicked.
    public var onAction: (() -> Void)?

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
        let button = NSButton(image: .settingsInfo, target: self, action: #selector(info(_:)))
        button.setAccessibilityLabel(String(localized: "Details", bundle: .module))
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

    public init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public func configure(with content: AccountRowContent) {
        guard content != self.content else { return }
        self.content = content
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle
        mark.isHidden = content.mark == .none
        if content.mark == .provider {
            mark.image = .settingsProviderMark
            mark.contentTintColor = .secondaryLabelColor
        } else {
            mark.image = NSImage.claudeMark
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
        mark.image = NSImage.claudeMark
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

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, content?.accessory == .info { onOpen?() } else { super.mouseDown(with: event) }
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        isPressed = true
    }

    public override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        isPressed = false
    }

    // MARK: - Just imported

    /// The accent at 14 %, under the row's content.
    private lazy var tintView = TintView()

    /// Tints the row as one just imported: held for 0.72 s, then fading to the
    /// group's fill over 1.68 s.
    public func flash() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if tintView.superview == nil {
            tintView.frame = bounds
            tintView.autoresizingMask = [.width, .height]
            addSubview(tintView, positioned: .below, relativeTo: nil)
        }
        tintView.alphaValue = 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.72))
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.68
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.tintView.animator().alphaValue = 0
            }
        }
    }

    private final class TintView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = isPressed ? NSColor.labelColor.withAlphaComponent(0.05).cgColor : nil
    }
}

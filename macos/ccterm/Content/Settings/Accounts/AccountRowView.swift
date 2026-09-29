import AppKit

/// An account in the Accounts list: Claude's mark for the subscription, the
/// title over a secondary line, and an ⓘ button. Not selectable, as System
/// Settings' rows aren't; ⓘ or a double click reports `onOpen`. Its context
/// menu is whatever its controller sets as `menu`.
@MainActor
final class AccountRowView: NSView {
    /// ⓘ was clicked or the row double-clicked.
    var onOpen: (() -> Void)?

    private let mark = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private lazy var infoButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: String(localized: "Details"))!,
            target: self, action: #selector(info(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        return button
    }()

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with content: AccountRowContent) {
        titleLabel.stringValue = content.title
        subtitleLabel.stringValue = content.subtitle
        mark.isHidden = !content.showsMark
    }

    private func configureHierarchy() {
        mark.image = NSImage(named: "ClaudeMark")
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for view in [mark, titleLabel, subtitleLabel, infoButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        // Skeleton geometry; the measured layout lands with the pane.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 51),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 28),
            mark.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10.5),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10.5),
            infoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -10),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -10),
        ])
    }

    @objc private func info(_ sender: Any?) {
        onOpen?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpen?() } else { super.mouseDown(with: event) }
    }
}

import AppKit

/// The API Providers group with nothing in it, as `ContentUnavailableView`
/// draws one: a quiet `server.rack`, “No API Providers”, one line of what a
/// provider is for, Add Provider…, and a hint that a pasted alias works too.
/// Its owner wires the button.
@MainActor
public final class ProvidersEmptyView: NSView {
    public let addButton = AddProviderButton()

    private lazy var symbol: NSImageView = {
        let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .tertiaryLabelColor
        return view
    }()

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "No API Providers", bundle: .module))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }()

    private lazy var descriptionLabel: NSTextField = {
        let label = NSTextField(
            wrappingLabelWithString: String(
                localized: "Run Claude Code through the Anthropic API, a gateway or a local proxy.", bundle: .module))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 380
        return label
    }()

    private lazy var hintLabel: NSTextField = {
        let label = NSTextField(
            labelWithString: String(localized: "Or press ⌘V to paste shell aliases or commands.", bundle: .module))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }()

    public init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        for view in [symbol, titleLabel, descriptionLabel, addButton, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        var constraints = [
            symbol.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            symbol.widthAnchor.constraint(equalToConstant: 34),
            symbol.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.topAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 10),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            descriptionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            addButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 14),
            hintLabel.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 10),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ]
        for view in [symbol, titleLabel, descriptionLabel, addButton, hintLabel] {
            constraints.append(view.centerXAnchor.constraint(equalTo: centerXAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}

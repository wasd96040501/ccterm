import AppKit

/// The sheet shown while the person signs in through the browser, 380 wide:
/// Claude's mark, what to do, a spinner, then Open Browser Again (a link)
/// and Cancel. The presenter dismisses it when the sign-in ends.
@MainActor
public final class SignInViewController: NSViewController {
    /// Cancel, Escape or ⌘.
    public var onCancel: (() -> Void)?

    /// The page to open again; `nil` until the CLI has printed it.
    private var browserURL: URL?

    static let width: CGFloat = 380

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public func configure(browserURL: URL?) {
        self.browserURL = browserURL
        openAgainButton.isEnabled = browserURL != nil
    }

    private lazy var mark: NSImageView = {
        let view = NSImageView(image: NSImage.claudeMark)
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }()

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "Sign in to Claude", bundle: .module))
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }()

    private lazy var messageLabel: NSTextField = {
        let label = NSTextField(
            wrappingLabelWithString: String(
                localized: "Continue in your browser. CCTerm finishes signing in when you approve access.",
                bundle: .module))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = SignInViewController.width - 48
        return label
    }()

    private lazy var spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        return spinner
    }()

    private lazy var waitLabel: NSTextField = {
        let label = NSTextField(labelWithString: String(localized: "Waiting for your browser…", bundle: .module))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private lazy var waitRow: NSStackView = {
        let stack = NSStackView(views: [spinner, waitLabel])
        stack.spacing = 8
        return stack
    }()

    private lazy var openAgainButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(openAgain(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Open Browser Again", bundle: .module),
            attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 13)])
        button.isEnabled = false
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = NSButton(
            title: String(localized: "Cancel", bundle: .module), target: self, action: #selector(cancel(_:)))
        button.keyEquivalent = "\u{1b}"
        return button
    }()

    public override func loadView() {
        view = NSView()
        configureHierarchy()
        configureConstraints()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        spinner.startAnimation(nil)
        preferredContentSize = view.fittingSize
    }

    private func configureHierarchy() {
        for subview in [mark, titleLabel, messageLabel, waitRow, openAgainButton, cancelButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            mark.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            mark.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mark.widthAnchor.constraint(equalToConstant: 48),
            mark.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            waitRow.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            waitRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.topAnchor.constraint(equalTo: waitRow.bottomAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            openAgainButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            openAgainButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
        ])
    }

    @objc private func openAgain(_ sender: Any?) {
        guard let browserURL else { return }
        NSWorkspace.shared.open(browserURL)
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
    }

    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

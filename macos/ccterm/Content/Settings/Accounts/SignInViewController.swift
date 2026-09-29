import AppKit

/// The sheet shown while the person signs in through the browser: Claude's
/// mark, what to do, a spinner, Open Browser Again and Cancel. The presenter
/// dismisses it when the sign-in ends.
@MainActor
final class SignInViewController: NSViewController {
    /// Cancel, Escape or ⌘.
    var onCancel: (() -> Void)?

    /// The page to open again; `nil` until the CLI has printed it.
    private var browserURL: URL?

    func configure(browserURL: URL?) {
        self.browserURL = browserURL
        openAgainButton.isEnabled = browserURL != nil
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: 230)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var openAgainButton: NSButton = {
        let button = NSButton(
            title: String(localized: "Open Browser Again"), target: self, action: #selector(openAgain(_:)))
        button.isEnabled = false
        return button
    }()

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Skeleton: the measured layout lands with the sheet.
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [
            NSImageView(image: NSImage(named: "ClaudeMark") ?? NSImage()),
            NSTextField(labelWithString: String(localized: "Sign in to Claude")),
            openAgainButton, cancel,
        ])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func openAgain(_ sender: Any?) {
        guard let browserURL else { return }
        NSWorkspace.shared.open(browserURL)
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

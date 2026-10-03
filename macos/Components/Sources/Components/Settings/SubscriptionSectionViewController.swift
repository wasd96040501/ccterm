import AppKit

/// Accounts' Subscription section: the signed-in account's row, or a row to
/// sign in with, and the sheet that waits on the browser while signing in.
/// Shows the state it is handed and reports what the person asks for.
@MainActor
public final class SubscriptionSectionViewController: NSViewController {
    /// The login, as the section shows it.
    public enum State: Equatable {
        /// Not read yet.
        case checking
        case signedOut
        /// Waiting for the person to approve in the browser; the page, once
        /// it is known.
        case signingIn(browserURL: URL?)
        /// The signed-in account's row.
        case signedIn(AccountRowContent)
    }

    public weak var delegate: SubscriptionSectionViewControllerDelegate?

    private var shownState: State?
    /// The sign-in sheet while the browser flow runs.
    private var signIn: SignInViewController?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let group = FormGroupView()
    private let row = AccountRowView()

    public override func loadView() {
        view = FormSectionView(title: String(localized: "Subscription", bundle: .module), content: group)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        group.setRows([row])
    }

    /// Shows `state`; the same state again changes nothing.
    public func show(_ state: State) {
        loadViewIfNeeded()
        guard state != shownState else { return }
        // The login is read at launch, so this is rare: the row settles from
        // “Checking…” with a short fade rather than a jump.
        if shownState == .checking, state != .checking { fadeIn(row) }
        shownState = state
        switch state {
        case .signedIn(let content):
            row.configure(with: content)
            row.onOpen = { [weak self] in self.map { $0.delegate?.subscriptionSectionDidRequestOpen($0) } }
            row.menu = menu()
        case .checking:
            row.configure(with: .checking)
            row.onOpen = nil
            row.menu = nil
        case .signedOut, .signingIn:
            row.configure(with: .signedOut)
            row.onOpen = nil
            row.onAction = { [weak self] in self.map { $0.delegate?.subscriptionSectionDidRequestSignIn($0) } }
            row.menu = nil
        }
        showSignIn(state)
    }

    private func fadeIn(_ view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = 1
        }
    }

    /// The sign-in sheet is up exactly while signing in.
    private func showSignIn(_ state: State) {
        if case .signingIn(let url) = state {
            let sheet = signIn ?? SignInViewController()
            sheet.configure(browserURL: url)
            guard signIn == nil else { return }
            sheet.onCancel = { [weak self] in self.map { $0.delegate?.subscriptionSectionDidCancelSignIn($0) } }
            signIn = sheet
            presentAsSheet(sheet)
        } else if let signIn {
            dismiss(signIn)
            self.signIn = nil
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Details…", bundle: .module), action: #selector(openDetails(_:)),
                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Sign Out…", bundle: .module), action: #selector(requestSignOut(_:)),
                keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func openDetails(_ sender: NSMenuItem) {
        delegate?.subscriptionSectionDidRequestOpen(self)
    }

    @objc private func requestSignOut(_ sender: NSMenuItem) {
        delegate?.subscriptionSectionDidRequestSignOut(self)
    }
}

extension AccountRowContent {
    /// No one is signed in to a subscription.
    static let signedOut = AccountRowContent(
        title: String(localized: "Not signed in", bundle: .module),
        subtitle: String(localized: "Use your Claude Pro or Max plan.", bundle: .module), mark: .claudeDimmed,
        accessory: .button(String(localized: "Sign In…", bundle: .module)))

    /// The login hasn't been read yet.
    static let checking = AccountRowContent(
        title: String(localized: "Subscription", bundle: .module),
        subtitle: String(localized: "Checking…", bundle: .module), mark: .claudeDimmed, accessory: .progress)
}

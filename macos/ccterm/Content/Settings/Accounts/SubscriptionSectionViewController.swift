import AppKit
import Combine
import Components

/// Accounts' Subscription section: the signed-in account's row, or a row to
/// sign in with, and the sheet that waits on the browser while signing in.
/// Shows the login's state and reports what the person asks for.
@MainActor
final class SubscriptionSectionViewController: NSViewController {
    weak var delegate: SubscriptionSectionViewControllerDelegate?

    private let states: AnyPublisher<SubscriptionService.State, Never>
    private var shownState: SubscriptionService.State?
    private var cancellables = Set<AnyCancellable>()
    /// The sign-in sheet while the browser flow runs.
    private var signIn: SignInViewController?

    /// `states`: the login, now and each time it changes; must deliver on the
    /// main actor, and its current value on subscribing, so the first frame is
    /// already right.
    init(states: AnyPublisher<SubscriptionService.State, Never>) {
        self.states = states
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let group = FormGroupView()
    private let row = AccountRowView()

    override func loadView() {
        view = FormSectionView(title: String(localized: "Subscription"), content: group)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        group.setRows([row])
        states
            .sink { [weak self] state in self?.show(state) }
            .store(in: &cancellables)
    }

    private func show(_ state: SubscriptionService.State) {
        // The login is read at launch, so this is rare: the row settles from
        // “Checking…” with a short fade rather than a jump.
        if shownState == .unknown, state != .unknown { fadeIn(row) }
        shownState = state
        switch state {
        case .signedIn(let subscription):
            row.configure(with: AccountRowContent(subscription: subscription))
            row.onOpen = { [weak self] in self.map { $0.delegate?.subscriptionSection($0, didOpen: subscription) } }
            row.menu = menu(for: subscription)
        case .unknown:
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

    /// The sign-in sheet is up exactly while signing in.
    private func fadeIn(_ view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = 1
        }
    }

    private func showSignIn(_ state: SubscriptionService.State) {
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

    private func menu(for subscription: Subscription) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: String(localized: "Details…"), action: #selector(openDetails(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: String(localized: "Sign Out…"), action: #selector(requestSignOut(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
            item.representedObject = subscription
        }
        return menu
    }

    @objc private func openDetails(_ sender: NSMenuItem) {
        guard let subscription = sender.representedObject as? Subscription else { return }
        delegate?.subscriptionSection(self, didOpen: subscription)
    }

    @objc private func requestSignOut(_ sender: NSMenuItem) {
        guard let subscription = sender.representedObject as? Subscription else { return }
        delegate?.subscriptionSection(self, didRequestSignOut: subscription)
    }
}

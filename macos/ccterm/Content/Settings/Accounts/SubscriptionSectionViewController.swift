import AppKit
import Combine

/// Accounts' Subscription section: the signed-in account's row, or a row to
/// sign in with, and the sheet that waits on the browser while signing in.
/// Shows the login's state and reports what the person asks for.
@MainActor
final class SubscriptionSectionViewController: NSViewController {
    weak var delegate: SubscriptionSectionViewControllerDelegate?

    private let state: AnyPublisher<SubscriptionService.State, Never>
    private var cancellables = Set<AnyCancellable>()
    /// The sign-in sheet while the browser flow runs.
    private var signIn: SignInViewController?

    /// `state`: the login, current value first — `SubscriptionService.$state`.
    init(state: AnyPublisher<SubscriptionService.State, Never>) {
        self.state = state
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
        state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.show(state) }
            .store(in: &cancellables)
    }

    private func show(_ state: SubscriptionService.State) {
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

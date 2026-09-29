import AppKit
import Combine

/// Accounts: the Subscription section above the API Providers section. The
/// sections show their own data and report what the person asks for; this
/// container presents the account sheet and the alerts that confirm a
/// removal, and turns their outcome into store and service calls.
@MainActor
final class AccountsSettingsViewController: NSViewController {
    private let accounts: AccountStore
    private let subscription: SubscriptionService
    private let subscriptionSection: SubscriptionSectionViewController
    private let providersSection: ProvidersSectionViewController

    /// The open account sheet, if any.
    private var editor: AccountEditorViewController?
    /// The account the open sheet edits.
    private var editing: Account?

    init(accounts: AccountStore, subscription: SubscriptionService) {
        self.accounts = accounts
        self.subscription = subscription
        subscriptionSection = SubscriptionSectionViewController(state: subscription.$state.eraseToAnyPublisher())
        providersSection = ProvidersSectionViewController(
            providers: accounts.$accounts.map { $0.filter { $0.provider != nil } }.eraseToAnyPublisher())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = FormView(sections: [subscriptionSection.view, providersSection.view])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(subscriptionSection)
        addChild(providersSection)
        subscriptionSection.delegate = self
        providersSection.delegate = self
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await subscription.refresh() }
    }

    // MARK: - The account sheet

    private func open(_ account: Account, mode: AccountEditorMode) {
        guard editor == nil else { return }
        Task {
            do {
                let secrets = try await accounts.secrets(for: account.id)
                present(account, secrets: secrets, mode: mode)
            } catch {
                appLog(.error, "AccountsSettingsViewController", "reading secrets failed — \(error)")
            }
        }
    }

    private func present(_ account: Account, secrets: AccountSecrets, mode: AccountEditorMode) {
        guard editor == nil else { return }
        let editor = AccountEditorViewController(mode: mode, account: account, secrets: secrets)
        editor.delegate = self
        self.editor = editor
        editing = account
        presentAsSheet(editor)
    }

    private func dismissEditor() {
        guard let editor else { return }
        dismiss(editor)
        self.editor = nil
        editing = nil
    }

    /// ⌘V on the pane: a new provider, filled from what was copied — an
    /// alias out of `~/.zshrc` becomes a provider in one step.
    @objc func paste(_ sender: Any?) {
        guard editor == nil, let text = NSPasteboard.general.string(forType: .string), AccountPaste(text) != nil
        else { return }
        present(.newProvider(), secrets: AccountSecrets(), mode: .newProvider)
        editor?.fill(from: text)
    }

    // MARK: - Confirmations

    /// Asks before deleting `account`, on `window` (the sheet's, or the
    /// Settings window's); deletes it on confirmation.
    private func confirmDelete(_ account: Account, on window: NSWindow?) {
        // Skeleton: the alert lands with the pane.
    }

    /// Asks before signing out; signs out on confirmation.
    private func confirmSignOut(_ subscription: Subscription, on window: NSWindow?) {
        // Skeleton: the alert lands with the pane.
    }
}

extension AccountsSettingsViewController: SubscriptionSectionViewControllerDelegate {
    func subscriptionSection(_ section: SubscriptionSectionViewController, didOpen subscription: Subscription) {
        open(accounts.subscriptionSettings, mode: .subscription(subscription))
    }

    func subscriptionSectionDidRequestSignIn(_ section: SubscriptionSectionViewController) {
        subscription.signIn()
    }

    func subscriptionSectionDidCancelSignIn(_ section: SubscriptionSectionViewController) {
        subscription.cancelSignIn()
    }

    func subscriptionSection(
        _ section: SubscriptionSectionViewController, didRequestSignOut subscription: Subscription
    ) {
        confirmSignOut(subscription, on: view.window)
    }
}

extension AccountsSettingsViewController: ProvidersSectionViewControllerDelegate {
    func providersSectionDidRequestAdd(_ section: ProvidersSectionViewController) {
        present(.newProvider(), secrets: AccountSecrets(), mode: .newProvider)
    }

    func providersSection(_ section: ProvidersSectionViewController, didOpen account: Account) {
        open(account, mode: .provider)
    }

    func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate account: Account) {
        Task {
            do {
                try await accounts.duplicate(account.id)
            } catch {
                appLog(.error, "AccountsSettingsViewController", "duplicating an account failed — \(error)")
            }
        }
    }

    func providersSection(_ section: ProvidersSectionViewController, didRequestDelete account: Account) {
        confirmDelete(account, on: view.window)
    }
}

extension AccountsSettingsViewController: AccountEditorViewControllerDelegate {
    func accountEditor(_ editor: AccountEditorViewController, didSave account: Account, secrets: AccountSecrets) {
        Task {
            do {
                try await accounts.save(account, secrets: secrets)
                dismissEditor()
            } catch {
                appLog(.error, "AccountsSettingsViewController", "saving an account failed — \(error)")
            }
        }
    }

    func accountEditorDidCancel(_ editor: AccountEditorViewController) {
        dismissEditor()
    }

    func accountEditorDidRequestRemoval(_ editor: AccountEditorViewController) {
        switch editor.mode {
        case .subscription(let subscription): confirmSignOut(subscription, on: editor.view.window)
        case .provider: editing.map { confirmDelete($0, on: editor.view.window) }
        case .newProvider: break
        }
    }
}

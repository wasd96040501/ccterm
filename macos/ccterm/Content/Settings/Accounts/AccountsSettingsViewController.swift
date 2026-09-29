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
        // Each section starts from the state as it is now, so the pane's
        // first frame is already right; changes follow.
        subscriptionSection = SubscriptionSectionViewController(
            state: subscription.state, updates: subscription.$state.dropFirst().eraseToAnyPublisher())
        providersSection = ProvidersSectionViewController(
            providers: accounts.providers,
            updates: accounts.$accounts.dropFirst().map { $0.filter { $0.provider != nil } }.eraseToAnyPublisher())
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
                view.window.map { report(error, on: $0, while: "reading an account's secrets") }
            }
        }
    }

    /// `paste`: text to fill the draft from before the sheet appears.
    private func present(_ account: Account, secrets: AccountSecrets, mode: AccountEditorMode, paste: String? = nil) {
        guard editor == nil else { return }
        let editor = AccountEditorViewController(mode: mode, account: account, secrets: secrets)
        editor.delegate = self
        if let paste { editor.fill(from: paste) }
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
        present(.newProvider(), secrets: AccountSecrets(), mode: .newProvider, paste: text)
    }

    // MARK: - Confirmations

    /// Asks before deleting `account`, on `window` (the sheet's, or the
    /// Settings window's); deletes it on confirmation.
    private func confirmDelete(_ account: Account, on window: NSWindow?) {
        guard let window, let provider = account.provider else { return }
        let alert = Self.confirmation(
            title: String(localized: "Delete “\(provider.name)”?"),
            message: String(
                localized:
                    "Its token is removed from your keychain. Sessions already running keep going until they end."),
            confirm: String(localized: "Delete"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do {
                    try await self.accounts.remove(account.id)
                    if self.editing?.id == account.id { self.dismissEditor() }
                } catch {
                    self.report(error, on: window, while: "deleting an account")
                }
            }
        }
    }

    /// Asks before signing out; signs out on confirmation.
    private func confirmSignOut(_ subscription: Subscription, on window: NSWindow?) {
        guard let window else { return }
        let alert = Self.confirmation(
            title: String(localized: "Sign out of \(subscription.email)?"),
            message: String(
                localized:
                    "New sessions can’t use your subscription until you sign in again. Your API providers aren’t affected."
            ),
            confirm: String(localized: "Sign Out"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do {
                    try await self.subscription.signOut()
                    if case .subscription = self.editor?.mode { self.dismissEditor() }
                } catch {
                    self.report(error, on: window, while: "signing out")
                }
            }
        }
    }

    /// An alert that confirms a destructive action: the action on the
    /// right, marked destructive; Cancel beside it, the default — Return
    /// and Escape both cancel.
    private static func confirmation(title: String, message: String, confirm: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirm)
        confirmButton.hasDestructiveAction = true
        confirmButton.keyEquivalent = ""
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\r"
        return alert
    }

    /// Tells the person an action failed, on the window they acted in.
    private func report(_ error: Error, on window: NSWindow, while action: String) {
        appLog(.error, "AccountsSettingsViewController", "\(action) failed — \(error.localizedDescription)")
        NSAlert(error: error).beginSheetModal(for: window)
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

    func providersSectionDidRequestImport(_ section: ProvidersSectionViewController) {
        paste(nil)
    }

    func providersSection(_ section: ProvidersSectionViewController, didOpen account: Account) {
        open(account, mode: .provider)
    }

    func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate account: Account) {
        Task {
            do {
                try await accounts.duplicate(account.id)
            } catch {
                view.window.map { report(error, on: $0, while: "duplicating an account") }
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
                (editor.view.window ?? view.window).map { report(error, on: $0, while: "saving an account") }
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

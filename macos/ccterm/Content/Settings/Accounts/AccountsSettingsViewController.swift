import AppKit
import Combine
import Components

/// Accounts: the Subscription section above the API Providers section. The
/// sections show their own data and report what the person asks for; this
/// container presents the account sheet and the alerts that confirm a
/// removal, and turns their outcome into store and service calls.
@MainActor
final class AccountsSettingsViewController: NSViewController {
    private let accounts: AccountStore
    private let launch: LaunchStore
    private let launchCheck: LaunchCheckService
    private let subscription: SubscriptionService
    private let subscriptionSection: SubscriptionSectionViewController
    private let providersSection: ProvidersSectionViewController

    /// The open account sheet, if any.
    private var editor: AccountEditorViewController?
    private var editorModel: AccountEditorViewModel?
    /// The account the open sheet edits.
    private var editing: Account?

    init(
        accounts: AccountStore, launch: LaunchStore, launchCheck: LaunchCheckService,
        subscription: SubscriptionService
    ) {
        self.accounts = accounts
        self.launch = launch
        self.launchCheck = launchCheck
        self.subscription = subscription
        subscriptionSection = SubscriptionSectionViewController(states: subscription.$state.eraseToAnyPublisher())
        providersSection = ProvidersSectionViewController(
            providers: accounts.$accounts.map { $0.filter { $0.provider != nil } }.eraseToAnyPublisher())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The pane's note about an import: at the bottom, centred, 24 above it.
    private let toast = ToastView()

    override func loadView() {
        let form = FormView(sections: [subscriptionSection.view, providersSection.view])
        let container = NSView()
        for subview in [form, toast] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: container.topAnchor),
            form.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            toast.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
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

    /// `entry`: what to fill the draft from before the sheet appears.
    private func present(
        _ account: Account, secrets: AccountSecrets, mode: AccountEditorMode, entry: AccountPaste.Entry? = nil
    ) {
        guard editor == nil else { return }
        let model = AccountEditorViewModel(
            mode: mode, account: account, secrets: secrets, entry: entry,
            takenNames: providerNames(excluding: account.id), commandValidation: commandValidation(for: account))
        let editor = AccountEditorViewController(viewModel: model)
        editor.delegate = self
        self.editor = editor
        editorModel = model
        editing = account
        presentAsSheet(editor)
    }

    private func dismissEditor() {
        guard let editor else { return }
        dismiss(editor)
        self.editor = nil
        editorModel = nil
        editing = nil
    }

    /// Checks `account`'s launch command as it is typed: what it launches, under
    /// General's settings.
    private func commandValidation(for account: Account) -> LaunchCommandValidation {
        LaunchCommandValidation(
            check: launchCheck,
            configuration: { [launch] in launch.configuration(accountCommand: $0) },
            text: account.command)
    }

    private func providerNames(excluding id: UUID) -> [String] {
        accounts.providers.filter { $0.id != id }.compactMap { $0.provider?.name }
    }

    // MARK: - Import

    /// Whether the clipboard holds something to import.
    private var canImport: Bool {
        NSPasteboard.general.string(forType: .string).map { !AccountPaste.entries($0).isEmpty } ?? false
    }

    /// ⌘V on the pane: providers out of what was copied — an alias in
    /// `~/.zshrc` becomes a provider in one step. One provider opens in the
    /// sheet to be looked over; several are added to the list.
    @objc func paste(_ sender: Any?) {
        guard editor == nil, let text = NSPasteboard.general.string(forType: .string) else { return }
        let entries = AccountPaste.entries(text)
        switch entries.count {
        case 0:
            return
        case 1:
            present(.newProvider(), secrets: AccountSecrets(), mode: .newProvider, entry: entries[0])
        default:
            importProviders(entries)
        }
    }

    private func importProviders(_ entries: [AccountPaste.Entry]) {
        let (providers, skipped) = AccountPaste.importable(
            entries, existingNames: accounts.providers.compactMap { $0.provider?.name })
        appLog(
            .info, "AccountsSettingsViewController",
            "import — \(entries.count) entries, \(providers.count) importable, \(skipped) skipped")
        guard !providers.isEmpty else {
            showImportResult(added: 0, skipped: skipped)
            return
        }
        Task {
            do {
                try await accounts.add(providers)
                providersSection.flash(providers.map(\.0.id))
                showImportResult(added: providers.count, skipped: skipped)
            } catch {
                view.window.map { report(error, on: $0, while: "importing providers") }
            }
        }
    }

    /// Says on the pane how many providers an import added and how many entries
    /// it left out: “Imported 3 providers”, “Imported 2 providers · 1 skipped”,
    /// “No providers imported · 3 skipped”.
    func showImportResult(added: Int, skipped: Int) {
        appLog(.info, "AccountsSettingsViewController", "import done — \(added) added, \(skipped) skipped")
        var text =
            added > 0 ? String(localized: "Imported \(added) providers") : String(localized: "No providers imported")
        if skipped > 0 { text += " · " + String(localized: "\(skipped) skipped") }
        toast.show(text)
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
                    if case .subscription = self.editorModel?.mode { self.dismissEditor() }
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

    func providersSectionCanImport(_ section: ProvidersSectionViewController) -> Bool {
        canImport
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
        guard let mode = editorModel?.mode else { return }
        switch mode {
        case .subscription(let subscription): confirmSignOut(subscription, on: editor.view.window)
        case .provider: editing.map { confirmDelete($0, on: editor.view.window) }
        case .newProvider: break
        }
    }
}

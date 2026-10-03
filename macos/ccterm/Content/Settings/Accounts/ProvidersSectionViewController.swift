import AppKit
import Combine
import Components

/// Accounts' API Providers section: a row per provider — or an empty state —
/// and Add Provider… (with Import from Clipboard in its menu) under the group. Shows the list and reports what the
/// person asks for.
@MainActor
final class ProvidersSectionViewController: NSViewController {
    weak var delegate: ProvidersSectionViewControllerDelegate?

    private let providers: AnyPublisher<[Account], Never>
    private var cancellables = Set<AnyCancellable>()
    /// The rows on show, by account.
    private var rows: [UUID: AccountRowView] = [:]

    /// `providers`: the provider accounts, now and each time the list changes;
    /// must deliver on the main actor, and its current value on subscribing, so
    /// the first frame is already right.
    init(providers: AnyPublisher<[Account], Never>) {
        self.providers = providers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let group = FormGroupView()
    private let emptyView = ProvidersEmptyView()
    private lazy var section = FormSectionView(
        title: String(localized: "API Providers"), content: group, trailingButtons: [addButton])
    private let addButton = AddProviderButton()

    override func loadView() {
        view = section
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for button in [addButton, emptyView.addButton] {
            button.onAdd = { [weak self] in self.map { $0.delegate?.providersSectionDidRequestAdd($0) } }
            button.onImport = { [weak self] in self.map { $0.delegate?.providersSectionDidRequestImport($0) } }
            button.isImportEnabled = { [weak self] in
                self.flatMap { $0.delegate?.providersSectionCanImport($0) } ?? false
            }
        }
        providers
            .sink { [weak self] providers in self?.show(providers) }
            .store(in: &cancellables)
    }

    /// A row per provider; with none, the empty state, which carries Add
    /// Provider… in place of the button under the group.
    private func show(_ providers: [Account]) {
        section.areTrailingButtonsHidden = providers.isEmpty
        guard !providers.isEmpty else {
            group.setRows([emptyView])
            return
        }
        rows = [:]
        group.setRows(
            providers.compactMap { account in
                guard let provider = account.provider else { return nil }
                let row = AccountRowView()
                rows[account.id] = row
                row.configure(with: AccountRowContent(provider: provider))
                row.onOpen = { [weak self] in self.map { $0.delegate?.providersSection($0, didOpen: account) } }
                row.menu = menu(for: account)
                return row
            })
    }

    /// Tints the rows of the providers with these ids, as just imported.
    func flash(_ ids: [UUID]) {
        for id in ids { rows[id]?.flash() }
    }

    private func menu(for account: Account) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: String(localized: "Details…"), action: #selector(open(_:)), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(title: String(localized: "Duplicate"), action: #selector(duplicate(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Delete…"), action: #selector(delete(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
            item.representedObject = account
        }
        return menu
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        delegate?.providersSection(self, didOpen: account)
    }

    @objc private func duplicate(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        delegate?.providersSection(self, didRequestDuplicate: account)
    }

    @objc private func delete(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? Account else { return }
        delegate?.providersSection(self, didRequestDelete: account)
    }
}

import AppKit
import Combine

/// Accounts' API Providers section: a row per provider — or an empty state —
/// and Add Provider… under the group. Shows the list and reports what the
/// person asks for.
@MainActor
final class ProvidersSectionViewController: NSViewController {
    weak var delegate: ProvidersSectionViewControllerDelegate?

    private let providers: AnyPublisher<[Account], Never>
    private var cancellables = Set<AnyCancellable>()

    /// `providers`: the provider accounts, current value first.
    init(providers: AnyPublisher<[Account], Never>) {
        self.providers = providers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let group = FormGroupView()
    private lazy var addButton = NSButton(
        title: String(localized: "Add Provider…"), target: self, action: #selector(add(_:)))

    override func loadView() {
        view = FormSectionView(title: String(localized: "API Providers"), content: group, trailingButtons: [addButton])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        providers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in self?.show(providers) }
            .store(in: &cancellables)
    }

    private func show(_ providers: [Account]) {
        // Skeleton: the empty state lands with the pane.
        group.setRows(
            providers.compactMap { account in
                guard let provider = account.provider else { return nil }
                let row = AccountRowView()
                row.configure(with: AccountRowContent(provider: provider))
                row.onOpen = { [weak self] in self.map { $0.delegate?.providersSection($0, didOpen: account) } }
                row.menu = menu(for: account)
                return row
            })
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

    @objc private func add(_ sender: Any?) {
        delegate?.providersSectionDidRequestAdd(self)
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

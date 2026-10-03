import AppKit
import DisplayModels

/// Accounts' API Providers section: a row per provider — or an empty state —
/// and Add Provider… (with Import from Clipboard in its menu) under the group.
/// Shows the rows it is handed and reports what the person asks for, by
/// provider id.
@MainActor
public final class ProvidersSectionViewController: NSViewController {
    /// A provider's row: its id, reported back, and what it shows.
    public struct Row: Equatable {
        public var id: UUID
        public var content: AccountRowContent

        public init(id: UUID, content: AccountRowContent) {
            self.id = id
            self.content = content
        }
    }

    public weak var delegate: ProvidersSectionViewControllerDelegate?

    private var shownRows: [Row]?
    /// The rows on show, by provider.
    private var rows: [UUID: AccountRowView] = [:]

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private let group = FormGroupView()
    private let emptyView = ProvidersEmptyView()
    private lazy var section = FormSectionView(
        title: String(localized: "API Providers", bundle: .module), content: group, trailingButtons: [addButton])
    private let addButton = AddProviderButton()

    public override func loadView() {
        view = section
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        for button in [addButton, emptyView.addButton] {
            button.onAdd = { [weak self] in self.map { $0.delegate?.providersSectionDidRequestAdd($0) } }
            button.onImport = { [weak self] in self.map { $0.delegate?.providersSectionDidRequestImport($0) } }
            button.isImportEnabled = { [weak self] in
                self.flatMap { $0.delegate?.providersSectionCanImport($0) } ?? false
            }
        }
    }

    /// A row per provider; with none, the empty state, which carries Add
    /// Provider… in place of the button under the group. The same rows again
    /// change nothing.
    public func show(_ providers: [Row]) {
        loadViewIfNeeded()
        guard providers != shownRows else { return }
        shownRows = providers
        section.areTrailingButtonsHidden = providers.isEmpty
        guard !providers.isEmpty else {
            group.setRows([emptyView])
            return
        }
        rows = [:]
        group.setRows(
            providers.map { provider in
                let row = AccountRowView()
                rows[provider.id] = row
                row.configure(with: provider.content)
                row.onOpen = { [weak self] in self.map { $0.delegate?.providersSection($0, didOpen: provider.id) } }
                row.menu = menu(for: provider.id)
                return row
            })
    }

    /// Tints the rows of the providers with these ids, as just imported.
    public func flash(_ ids: [UUID]) {
        for id in ids { rows[id]?.flash() }
    }

    private func menu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Details…", bundle: .module), action: #selector(open(_:)), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Duplicate", bundle: .module), action: #selector(duplicate(_:)),
                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Delete…", bundle: .module), action: #selector(delete(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
            item.representedObject = id
        }
        return menu
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delegate?.providersSection(self, didOpen: id)
    }

    @objc private func duplicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delegate?.providersSection(self, didRequestDuplicate: id)
    }

    @objc private func delete(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delegate?.providersSection(self, didRequestDelete: id)
    }
}

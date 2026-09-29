import AppKit
import Combine

/// An account's sheet, 540 × 600 for either kind: a header, a scrolling form
/// — the subscription's details or the provider's connection, the
/// environment variables, the provider's models, how the CLI is launched —
/// and a button bar. Return saves, Escape and ⌘. cancel. Reports to its
/// delegate; the presenter dismisses it.
///
/// The form's sections are built once, from the mode; the view model's
/// presentation then updates them in place.
@MainActor
final class AccountEditorViewController: NSViewController {
    weak var delegate: AccountEditorViewControllerDelegate?

    let mode: AccountEditorMode
    private let viewModel: AccountEditorViewModel
    private let environment = EnvironmentVariablesViewController()
    private var cancellables = Set<AnyCancellable>()
    /// The fields' revision last written into the controls.
    private var shownFieldsRevision = -1

    /// The sheet's size, fixed so the window never resizes under it.
    static let size = NSSize(width: 540, height: 600)

    init(mode: AccountEditorMode, account: Account, secrets: AccountSecrets) {
        self.mode = mode
        viewModel = AccountEditorViewModel(mode: mode, account: account, secrets: secrets)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var headerTitle = NSTextField(labelWithString: "")
    private lazy var headerSubtitle = NSTextField(labelWithString: "")
    private lazy var header: NSStackView = {
        let stack = NSStackView(views: [headerTitle, headerSubtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }()
    private lazy var form = FormView(topInset: 16, sectionSpacing: 22)
    private lazy var buttonBar: NSStackView = {
        let stack = NSStackView(views: [removeButton, NSView(), cancelButton, saveButton])
        stack.spacing = 12
        return stack
    }()

    private lazy var nameField = Self.field(placeholder: String(localized: "Required"))
    private lazy var baseURLField = Self.field(placeholder: "https://api.anthropic.com")
    private lazy var baseURLRow = FormRowView(title: String(localized: "Base URL"), accessory: baseURLField)
    private lazy var commandField = Self.field(placeholder: "claude", monospaced: true)
    private lazy var argumentsField = Self.field(placeholder: String(localized: "None"), monospaced: true)

    private lazy var removeButton: NSButton = {
        let title =
            if case .subscription = mode { String(localized: "Sign Out…") } else { String(localized: "Delete…") }
        let button = NSButton(title: title, target: self, action: #selector(requestRemoval(_:)))
        button.hasDestructiveAction = true
        button.isHidden = mode == .newProvider
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        button.keyEquivalent = "\u{1b}"
        return button
    }()

    private lazy var saveButton: NSButton = {
        let title = mode == .newProvider ? String(localized: "Add") : String(localized: "Save")
        let button = NSButton(title: title, target: self, action: #selector(save(_:)))
        button.keyEquivalent = "\r"
        return button
    }()

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(environment)
        configureHierarchy()
        configureConstraints()
        environment.delegate = self
        for field in [nameField, baseURLField, commandField, argumentsField] {
            field.delegate = self
        }
        viewModel.$presentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in self?.show(presentation) }
            .store(in: &cancellables)
    }

    private func configureHierarchy() {
        form.setSections(sections())
        for subview in [header, form, buttonBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            form.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonBar.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 14),
            buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    /// The form's sections for this kind of account.
    private func sections() -> [NSView] {
        var sections: [NSView] = []
        if case .subscription = mode {
            // Skeleton: Email, Organization, Plan, Signed in with.
        } else {
            sections.append(
                FormSectionView(
                    title: String(localized: "Connection"),
                    content: FormGroupView(rows: [
                        FormRowView(title: String(localized: "Name"), accessory: nameField), baseURLRow,
                    ])))
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Environment Variables"), content: FormGroupView(rows: [environment.view])))
        sections.append(
            FormSectionView(
                title: String(localized: "Launch"),
                content: FormGroupView(rows: [
                    FormRowView(title: String(localized: "Command"), accessory: commandField),
                    FormRowView(title: String(localized: "Arguments"), accessory: argumentsField),
                ])))
        return sections
    }

    /// Data down: derived state every time; field values only after a
    /// change that didn't come from typing in them.
    private func show(_ presentation: AccountEditorPresentation) {
        headerTitle.stringValue = presentation.title
        headerSubtitle.stringValue = presentation.subtitle
        saveButton.isEnabled = presentation.canSave
        baseURLRow.detail = presentation.baseURLError
        baseURLRow.isDetailError = true
        environment.configure(with: presentation.environmentRows)
        guard presentation.fieldsRevision != shownFieldsRevision else { return }
        shownFieldsRevision = presentation.fieldsRevision
        let fields = presentation.fields
        nameField.stringValue = fields.name
        baseURLField.stringValue = fields.baseURL
        commandField.stringValue = fields.command
        argumentsField.stringValue = fields.arguments
    }

    private static func field(placeholder: String, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.placeholderString = placeholder
        if monospaced { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        return field
    }

    // MARK: - Actions

    @objc private func save(_ sender: Any?) {
        let result = viewModel.result
        delegate?.accountEditor(self, didSave: result.account, secrets: result.secrets)
    }

    @objc private func cancel(_ sender: Any?) {
        delegate?.accountEditorDidCancel(self)
    }

    /// ⌘. and Escape outside a field.
    override func cancelOperation(_ sender: Any?) {
        cancel(sender)
    }

    @objc private func requestRemoval(_ sender: Any?) {
        delegate?.accountEditorDidRequestRemoval(self)
    }

    /// Reads `text` — `KEY=value` lines, `export` lines or a whole alias —
    /// into the draft, and says what it filled.
    func fill(from text: String) {
        let summary = viewModel.paste(text)
        // Skeleton: the toast lands with the sheet.
        _ = summary
    }

    /// ⌘V anywhere in the sheet but a text field.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        fill(from: text)
    }
}

extension AccountEditorViewController: NSTextFieldDelegate {
    /// Events up: each keystroke into the draft.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field {
        case nameField: viewModel.setName(field.stringValue)
        case baseURLField: viewModel.setBaseURL(field.stringValue)
        case commandField: viewModel.setCommand(field.stringValue)
        case argumentsField: viewModel.setArguments(field.stringValue)
        default: break
        }
    }
}

extension AccountEditorViewController: EnvironmentVariablesViewControllerDelegate {
    func environmentVariables(_ list: EnvironmentVariablesViewController, didToggleAt index: Int) {
        viewModel.toggleVariable(at: index)
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetName name: String, at index: Int) {
        viewModel.setVariableName(name, at: index)
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetValue value: String, at index: Int) {
        viewModel.setVariableValue(value, at: index)
    }

    func environmentVariablesDidAdd(_ list: EnvironmentVariablesViewController) -> Int {
        viewModel.addVariable()
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, didRemoveAt index: Int) {
        viewModel.removeVariable(at: index)
    }

    func environmentVariables(_ list: EnvironmentVariablesViewController, valueAt index: Int) -> String {
        viewModel.variableValue(at: index)
    }
}

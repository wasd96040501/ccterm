import AppKit
import Combine

/// An account's sheet, 540 × 600 for either kind: a header, a scrolling form
/// — the subscription's account or the provider's connection, the
/// environment variables, the provider's models, how the CLI is launched —
/// and a button bar that gains a hairline while the form runs under it.
/// Return saves, Escape and ⌘. cancel. Reports to its delegate; the
/// presenter dismisses it.
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
    /// Filled from a paste before it appeared: leave the focus alone.
    private var wasFilled = false

    /// The sheet's size, fixed so the window never resizes under it.
    static let size = NSSize(width: 540, height: 600)
    /// The page Manage opens: the plan's billing on claude.ai.
    static let manageURL = URL(string: "https://claude.ai/settings/billing")!

    init(mode: AccountEditorMode, account: Account, secrets: AccountSecrets) {
        self.mode = mode
        viewModel = AccountEditorViewModel(mode: mode, account: account, secrets: secrets)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var isSubscription: Bool {
        if case .subscription = mode { return true }
        return false
    }

    // MARK: - Header

    private lazy var headerMark: NSImageView = {
        let view = NSImageView(image: NSImage(named: "ClaudeMark") ?? NSImage())
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isHidden = !isSubscription
        return view
    }()

    private lazy var headerTitle: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var headerSubtitle: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var header: NSStackView = {
        let text = NSStackView(views: [headerTitle, headerSubtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [headerMark, text])
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }()

    // MARK: - Form

    private lazy var form = FormView(topInset: 16, sectionSpacing: 22)

    private lazy var nameField = FormTextField(placeholder: String(localized: "Required"))
    private lazy var baseURLField = FormTextField(placeholder: "https://api.anthropic.com")
    private lazy var baseURLRow = FormRowView(title: String(localized: "Base URL"), accessory: baseURLField)

    private lazy var authenticationPopUp: FormPopUpButton = {
        let popUp = FormPopUpButton()
        for option in AccountEditorViewModel.authenticationOptions {
            popUp.addItem(
                title: option.title, detail: option.detail, representedObject: option.authentication.rawValue)
        }
        popUp.target = self
        popUp.action = #selector(chooseAuthentication(_:))
        return popUp
    }()

    private lazy var credentialField = FormSecretField(placeholder: String(localized: "Required"))
    private lazy var credentialRow = FormRowView(title: "", accessory: credentialField)

    private lazy var modelFields: [(field: FormTextField, keyPath: WritableKeyPath<Account.Models, String>)] = [
        (FormTextField(placeholder: String(localized: "Default"), monospaced: true), \.main),
        (FormTextField(placeholder: String(localized: "Default"), monospaced: true), \.opus),
        (FormTextField(placeholder: String(localized: "Default"), monospaced: true), \.sonnet),
        (FormTextField(placeholder: String(localized: "Default"), monospaced: true), \.haiku),
    ]

    private lazy var commandField = FormTextField(placeholder: "claude", width: 300, monospaced: true)
    private lazy var argumentsField = FormTextField(
        placeholder: String(localized: "None"), width: 300, monospaced: true)

    private lazy var emailLabel = Self.valueLabel()
    private lazy var organizationLabel = Self.valueLabel()
    private lazy var planLabel = Self.valueLabel()
    private lazy var methodLabel = Self.valueLabel()

    private lazy var manageButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(manage(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Manage"),
            attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 13)])
        button.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        button.imagePosition = .imageTrailing
        button.contentTintColor = .linkColor
        return button
    }()

    // MARK: - Button bar

    private lazy var barHairline: FormHairlineView = {
        let hairline = FormHairlineView()
        hairline.isHidden = true
        return hairline
    }()

    private lazy var buttonBar: NSStackView = {
        let stack = NSStackView(views: [removeButton, NSView(), cancelButton, saveButton])
        stack.spacing = 12
        return stack
    }()

    private lazy var removeButton: NSButton = {
        let title = isSubscription ? String(localized: "Sign Out…") : String(localized: "Delete…")
        let button = Self.barButton(title: title, target: self, action: #selector(requestRemoval(_:)))
        button.hasDestructiveAction = true
        button.isHidden = mode == .newProvider
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = Self.barButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        button.keyEquivalent = "\u{1b}"
        return button
    }()

    private lazy var saveButton: NSButton = {
        let title = mode == .newProvider ? String(localized: "Add") : String(localized: "Save")
        let button = Self.barButton(title: title, target: self, action: #selector(save(_:)))
        button.keyEquivalent = "\r"
        return button
    }()

    private lazy var toast = ToastView()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(environment)
        configureHierarchy()
        configureConstraints()
        environment.delegate = self
        for field in [nameField, baseURLField, commandField, argumentsField] + modelFields.map(\.field) {
            field.delegate = self
        }
        credentialField.onChange = { [weak self] credential in self?.viewModel.setCredential(credential) }
        form.onContentBelowChange = { [weak self] below in self?.barHairline.isHidden = !below }
        viewModel.$presentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in self?.show(presentation) }
            .store(in: &cancellables)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.autorecalculatesKeyViewLoop = true
        // A new provider starts in Name; an existing account opens with
        // nothing focused, to read before editing.
        view.window?.makeFirstResponder(mode == .newProvider && !wasFilled ? nameField : nil)
    }

    private func configureHierarchy() {
        form.setSections(sections())
        for subview in [header, form, barHairline, buttonBar, toast] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            headerMark.widthAnchor.constraint(equalToConstant: 36),
            headerMark.heightAnchor.constraint(equalToConstant: 36),
            headerTitle.heightAnchor.constraint(equalToConstant: 16),
            headerSubtitle.heightAnchor.constraint(equalToConstant: 14),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            form.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barHairline.topAnchor.constraint(equalTo: form.bottomAnchor),
            barHairline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barHairline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonBar.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 14),
            buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -66),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
    }

    /// The form's sections for this kind of account.
    private func sections() -> [NSView] {
        var sections: [NSView] = []
        if isSubscription {
            let plan = NSStackView(views: [planLabel, manageButton])
            plan.spacing = 8
            sections.append(
                FormSectionView(
                    title: String(localized: "Account"),
                    content: FormGroupView(rows: [
                        FormRowView(title: String(localized: "Email"), accessory: emailLabel),
                        FormRowView(title: String(localized: "Organization"), accessory: organizationLabel),
                        FormRowView(title: String(localized: "Plan"), accessory: plan),
                        FormRowView(title: String(localized: "Signed in with"), accessory: methodLabel),
                    ])))
        } else {
            sections.append(
                FormSectionView(
                    title: String(localized: "Connection"),
                    content: FormGroupView(rows: [
                        FormRowView(title: String(localized: "Name"), accessory: nameField),
                        baseURLRow,
                        FormRowView(title: String(localized: "Authentication"), accessory: authenticationPopUp),
                        credentialRow,
                    ])))
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Environment Variables"), content: FormGroupView(rows: [environment.view])))
        if !isSubscription {
            let titles = [
                String(localized: "Model"), String(localized: "Opus"), String(localized: "Sonnet"),
                String(localized: "Haiku"),
            ]
            sections.append(
                FormSectionView(
                    title: String(localized: "Models"),
                    content: FormGroupView(
                        rows: zip(titles, modelFields).map { FormRowView(title: $0, accessory: $1.field) })))
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Launch"),
                content: FormGroupView(rows: [
                    FormRowView(title: String(localized: "Command"), accessory: commandField),
                    FormRowView(title: String(localized: "Arguments"), accessory: argumentsField),
                ])))
        return sections
    }

    // MARK: - Data down

    /// Derived state every time; field values only after a change that
    /// didn't come from typing in them.
    private func show(_ presentation: AccountEditorPresentation) {
        headerTitle.stringValue = presentation.title
        headerSubtitle.stringValue = presentation.subtitle
        saveButton.isEnabled = presentation.canSave
        baseURLRow.detail = presentation.baseURLError
        baseURLRow.isDetailError = true
        credentialRow.title = presentation.credentialTitle
        credentialRow.attributedDetail = Self.credentialDetail(variable: presentation.credentialVariable)
        credentialField.configure(value: presentation.fields.credential, masked: presentation.maskedCredential)
        let authentication = authenticationPopUp.indexOfItem(
            withRepresentedObject: presentation.fields.authentication.rawValue)
        if authentication >= 0 { authenticationPopUp.selectItem(at: authentication) }
        if let details = presentation.subscription {
            emailLabel.stringValue = details.email
            organizationLabel.stringValue = details.organization
            planLabel.stringValue = details.plan
            methodLabel.stringValue = details.signInMethod
        }
        environment.configure(with: presentation.environmentRows)

        guard presentation.fieldsRevision != shownFieldsRevision else { return }
        shownFieldsRevision = presentation.fieldsRevision
        let fields = presentation.fields
        nameField.stringValue = fields.name
        baseURLField.stringValue = fields.baseURL
        for (field, value) in zip(modelFields.map(\.field), [fields.model, fields.opus, fields.sonnet, fields.haiku]) {
            field.stringValue = value
        }
        commandField.stringValue = fields.command
        argumentsField.stringValue = fields.arguments
    }

    /// “Sent as `ANTHROPIC_AUTH_TOKEN`. Stored in your keychain.”
    private static func credentialDetail(variable: String) -> NSAttributedString {
        let template = String(localized: "Sent as %@. Stored in your keychain.")
        let parts = template.components(separatedBy: "%@")
        let text = NSMutableAttributedString(string: parts.first ?? "")
        text.append(
            NSAttributedString(
                string: variable, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]))
        text.append(NSAttributedString(string: parts.dropFirst().joined()))
        return text
    }

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private static func barButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        return button
    }

    // MARK: - Events up

    /// Reads `text` — `KEY=value` lines, `export` lines or a whole alias —
    /// into the draft, and says what it filled.
    func fill(from text: String) {
        wasFilled = true
        toast.show(viewModel.paste(text))
    }

    /// ⌘V anywhere in the sheet but a text field.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        fill(from: text)
    }

    @objc private func chooseAuthentication(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
            let authentication = Account.Authentication(rawValue: raw)
        else { return }
        viewModel.setAuthentication(authentication)
    }

    @objc private func manage(_ sender: Any?) {
        NSWorkspace.shared.open(Self.manageURL)
    }

    @objc private func save(_ sender: Any?) {
        // An edit in progress is part of what is saved.
        view.window?.makeFirstResponder(nil)
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
        default:
            guard let model = modelFields.first(where: { $0.field === field }) else { return }
            viewModel.setModel(model.keyPath, to: field.stringValue)
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

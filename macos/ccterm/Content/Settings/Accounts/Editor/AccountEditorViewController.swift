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

    var mode: AccountEditorMode { viewModel.mode }
    private let viewModel: AccountEditorViewModel
    private let environment = EnvironmentVariablesViewController()
    private var cancellables = Set<AnyCancellable>()
    /// The fields' revision last written into the controls.
    private var shownFieldsRevision = -1
    /// Filled from a paste before it appeared: leave the focus alone.
    private var wasFilled = false
    /// What a paste made before the sheet appeared filled, to say once it has.
    private var pendingToast: String?

    /// The sheet's size, fixed so the window never resizes under it.
    static let size = NSSize(width: 540, height: 600)
    /// The page Manage opens: the plan's billing on claude.ai.
    static let manageURL = URL(string: "https://claude.ai/settings/billing")!

    init(viewModel: AccountEditorViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var isSubscription: Bool {
        if case .subscription = mode { return true }
        return false
    }

    // MARK: - Form

    private lazy var form = FormView(topInset: 20, sectionSpacing: 22)

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

    /// The model a session starts with, then what each family's alias
    /// resolves to; empty leaves the CLI's own choice.
    private lazy var modelFields:
        [(title: String, field: FormTextField, keyPath: WritableKeyPath<Account.Models, String>)] = [
            (String(localized: "Default Model"), Self.modelField(), \.main),
            ("Opus", Self.modelField(), \.opus),
            ("Sonnet", Self.modelField(), \.sonnet),
            ("Haiku", Self.modelField(), \.haiku),
            ("Fable", Self.modelField(), \.fable),
        ]

    private lazy var commandField = FormTextField(placeholder: "claude", width: 300, monospaced: true)
    private lazy var commandRow = FormRowView(title: String(localized: "Command"), accessory: commandField)
    private lazy var argumentsField = FormTextField(
        placeholder: String(localized: "None"), width: 300, monospaced: true)

    private lazy var emailLabel = Self.valueLabel()
    private lazy var organizationLabel = Self.valueLabel()
    private lazy var planLabel = Self.valueLabel()

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
        // The view model delivers on the main actor and its current value on
        // subscribing, so the first frame shows the draft as it is.
        viewModel.$presentation
            .sink { [weak self] presentation in self?.show(presentation) }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // A new provider starts in Name. An existing account, or one filled
        // from a paste, opens to read before editing: focus goes to the
        // variable list, which shows none while nothing is selected. Set
        // before the sheet turns key, which would otherwise pick a field.
        view.window?.autorecalculatesKeyViewLoop = true
        view.window?.initialFirstResponder =
            mode == .newProvider && !wasFilled ? nameField : environment.initialFirstResponder
    }

    private func configureHierarchy() {
        form.setSections(sections())
        for subview in [form, barHairline, buttonBar, toast] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.topAnchor),
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
            sections.append(
                FormSectionView(
                    title: String(localized: "Models"),
                    content: FormGroupView(rows: modelFields.map { FormRowView(title: $0.title, accessory: $0.field) }))
            )
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Launch"),
                content: FormGroupView(rows: [
                    commandRow,
                    FormRowView(title: String(localized: "Arguments"), accessory: argumentsField),
                ])))
        return sections
    }

    // MARK: - Data down

    /// Derived state every time; field values only after a change that
    /// didn't come from typing in them.
    private func show(_ presentation: AccountEditorPresentation) {
        saveButton.isEnabled = presentation.canSave
        baseURLRow.detail = presentation.baseURLError
        baseURLRow.isDetailError = true
        commandRow.detail = presentation.commandError
        commandRow.isDetailError = true
        credentialRow.title = presentation.credentialTitle
        credentialField.configure(value: presentation.fields.credential, masked: presentation.maskedCredential)
        let authentication = authenticationPopUp.indexOfItem(
            withRepresentedObject: presentation.fields.authentication.rawValue)
        if authentication >= 0 { authenticationPopUp.selectItem(at: authentication) }
        if let details = presentation.subscription {
            emailLabel.stringValue = details.email
            organizationLabel.stringValue = details.organization
            planLabel.stringValue = details.plan
        }
        environment.configure(with: presentation.environmentRows)

        guard presentation.fieldsRevision != shownFieldsRevision else { return }
        shownFieldsRevision = presentation.fieldsRevision
        let fields = presentation.fields
        nameField.stringValue = fields.name
        baseURLField.stringValue = fields.baseURL
        let models = [fields.model, fields.opus, fields.sonnet, fields.haiku, fields.fable]
        for (field, value) in zip(modelFields.map(\.field), models) {
            field.stringValue = value
        }
        commandField.stringValue = fields.command
        argumentsField.stringValue = fields.arguments
    }

    private static func modelField() -> FormTextField {
        FormTextField(placeholder: String(localized: "Automatic"), monospaced: true)
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

    /// Fills the draft from `entry` and says what it filled.
    func fill(_ entry: AccountPaste.Entry) {
        say(viewModel.apply(entry))
    }

    /// Reads `text` — `KEY=value` lines, `export` lines or a whole alias —
    /// into the draft, and says what it filled.
    private func fill(from text: String) {
        say(viewModel.paste(text))
    }

    /// Shows a note about what a paste did. Before the sheet is up, it waits
    /// for it to appear.
    private func say(_ summary: String) {
        wasFilled = true
        if isViewLoaded, view.window != nil { toast.show(summary) } else { pendingToast = summary }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let pendingToast { toast.show(pendingToast) }
        pendingToast = nil
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
    /// Escape in a field cancels the sheet; a field editor binds it to
    /// `complete:`, which would otherwise offer completions.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.complete(_:)) else { return false }
        cancel(control)
        return true
    }

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

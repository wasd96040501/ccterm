import AppKit
import DisplayModels

/// An account's sheet, 540 × 600 for either kind: a header, a scrolling form
/// — the subscription's account or the provider's connection, the
/// environment variables, the provider's models, how the CLI is launched —
/// and a button bar that gains a hairline while the form runs under it.
/// Return saves, Escape and ⌘. cancel. Shows what it is given
/// (``show(_:)``) and reports each edit to its delegate; the presenter
/// dismisses it.
///
/// The form's sections are built once, from the kind; each presentation
/// then updates them in place.
public final class AccountEditorViewController: NSViewController {
    /// Which account the sheet edits, which decides its sections and buttons.
    public enum Kind: Equatable {
        /// The subscription's settings: its details, variables and launch;
        /// Sign Out….
        case subscription
        /// A provider being added: connection, variables, models, launch; Add.
        case newProvider
        /// A provider already in the list: the same, with Delete… and Save.
        case provider
    }

    /// A text the sheet edits, as its delegate is told of it.
    public enum Field: Equatable {
        case name, baseURL, credential
        case model(Model)
        case command, arguments
    }

    /// The model a session starts with, then each family's alias.
    public enum Model: CaseIterable {
        case main, opus, sonnet, haiku, fable
    }

    public weak var delegate: AccountEditorViewControllerDelegate?

    private let kind: Kind
    private let environment = EnvironmentVariablesViewController()
    /// What it shows; applied once the view has loaded.
    private var presentation: AccountEditorPresentation?
    /// The fields' revision last written into the controls.
    private var shownFieldsRevision = -1
    /// Filled from a paste before it appeared: leave the focus alone.
    private var wasFilled = false
    /// What a paste made before the sheet appeared filled, to say once it has.
    private var pendingToast: String?

    /// The sheet's size, fixed so the window never resizes under it.
    public static let size = NSSize(width: 540, height: 600)

    public init(kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.size
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var isSubscription: Bool { kind == .subscription }

    // MARK: - Form

    private lazy var form = FormView(topInset: 20, sectionSpacing: 22)

    private lazy var nameField = FormTextField(placeholder: String(localized: "Required", bundle: .module))
    private lazy var baseURLField = FormTextField(placeholder: "https://api.anthropic.com")
    private lazy var baseURLRow = FormRowView(
        title: String(localized: "Base URL", bundle: .module), accessory: baseURLField)

    /// Each way a credential is sent, in `Authentication.allCases`' order.
    private lazy var authenticationPopUp: FormPopUpButton = {
        let popUp = FormPopUpButton()
        for authentication in AccountEditorPresentation.Authentication.allCases {
            popUp.addItem(title: authentication.title, detail: authentication.header, representedObject: nil)
        }
        popUp.target = self
        popUp.action = #selector(chooseAuthentication(_:))
        return popUp
    }()

    private lazy var credentialField = FormSecretField(placeholder: String(localized: "Required", bundle: .module))
    private lazy var credentialRow = FormRowView(title: "", accessory: credentialField)

    /// The model a session starts with, then what each family's alias
    /// resolves to; empty leaves the CLI's own choice.
    private lazy var modelFields: [(model: Model, title: String, field: FormTextField)] = [
        (.main, String(localized: "Default Model", bundle: .module), Self.modelField()),
        (.opus, "Opus", Self.modelField()),
        (.sonnet, "Sonnet", Self.modelField()),
        (.haiku, "Haiku", Self.modelField()),
        (.fable, "Fable", Self.modelField()),
    ]

    private lazy var commandField = FormTextField(placeholder: "claude", width: 300, monospaced: true)
    private lazy var commandRow = FormRowView(
        title: String(localized: "Command", bundle: .module), accessory: commandField)
    private lazy var argumentsField = FormTextField(
        placeholder: String(localized: "None", bundle: .module), width: 300, monospaced: true)

    private lazy var emailLabel = Self.valueLabel()
    private lazy var organizationLabel = Self.valueLabel()
    private lazy var planLabel = Self.valueLabel()

    private lazy var manageButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(manage(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: String(localized: "Manage", bundle: .module),
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
        let title =
            isSubscription
            ? String(localized: "Sign Out…", bundle: .module) : String(localized: "Delete…", bundle: .module)
        let button = Self.barButton(title: title, target: self, action: #selector(requestRemoval(_:)))
        button.hasDestructiveAction = true
        button.isHidden = kind == .newProvider
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = Self.barButton(
            title: String(localized: "Cancel", bundle: .module), target: self, action: #selector(cancel(_:)))
        button.keyEquivalent = "\u{1b}"
        return button
    }()

    private lazy var saveButton: NSButton = {
        let title =
            kind == .newProvider
            ? String(localized: "Add", bundle: .module) : String(localized: "Save", bundle: .module)
        let button = Self.barButton(title: title, target: self, action: #selector(save(_:)))
        button.keyEquivalent = "\r"
        return button
    }()

    private lazy var toast = ToastView()

    // MARK: - Lifecycle

    public override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(environment)
        configureHierarchy()
        configureConstraints()
        environment.delegate = self
        for field in [nameField, baseURLField, commandField, argumentsField] + modelFields.map(\.field) {
            field.delegate = self
        }
        credentialField.onChange = { [weak self] credential in
            guard let self else { return }
            delegate?.accountEditor(self, didEdit: .credential, to: credential)
        }
        form.onContentBelowChange = { [weak self] below in self?.barHairline.isHidden = !below }
        // What it was given before it loaded, so the first frame shows it.
        if let presentation { apply(presentation) }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        // A new provider starts in Name. An existing account, or one filled
        // from a paste, opens to read before editing: focus goes to the
        // variable list, which shows none while nothing is selected. Set
        // before the sheet turns key, which would otherwise pick a field.
        view.window?.autorecalculatesKeyViewLoop = true
        view.window?.initialFirstResponder =
            kind == .newProvider && !wasFilled ? nameField : environment.initialFirstResponder
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
                    title: String(localized: "Account", bundle: .module),
                    content: FormGroupView(rows: [
                        FormRowView(title: String(localized: "Email", bundle: .module), accessory: emailLabel),
                        FormRowView(
                            title: String(localized: "Organization", bundle: .module), accessory: organizationLabel),
                        FormRowView(title: String(localized: "Plan", bundle: .module), accessory: plan),
                    ])))
        } else {
            sections.append(
                FormSectionView(
                    title: String(localized: "Connection", bundle: .module),
                    content: FormGroupView(rows: [
                        FormRowView(title: String(localized: "Name", bundle: .module), accessory: nameField),
                        baseURLRow,
                        FormRowView(
                            title: String(localized: "Authentication", bundle: .module), accessory: authenticationPopUp),
                        credentialRow,
                    ])))
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Environment Variables", bundle: .module),
                content: FormGroupView(rows: [environment.view])))
        if !isSubscription {
            sections.append(
                FormSectionView(
                    title: String(localized: "Models", bundle: .module),
                    content: FormGroupView(rows: modelFields.map { FormRowView(title: $0.title, accessory: $0.field) }))
            )
        }
        sections.append(
            FormSectionView(
                title: String(localized: "Launch", bundle: .module),
                content: FormGroupView(rows: [
                    commandRow,
                    FormRowView(title: String(localized: "Arguments", bundle: .module), accessory: argumentsField),
                ])))
        return sections
    }

    // MARK: - Data down

    /// Shows `presentation`: derived state every time; field values only
    /// after a change that didn't come from typing in them.
    public func show(_ presentation: AccountEditorPresentation) {
        self.presentation = presentation
        if isViewLoaded { apply(presentation) }
    }

    private func apply(_ presentation: AccountEditorPresentation) {
        saveButton.isEnabled = presentation.canSave
        baseURLRow.detail = presentation.baseURLError
        baseURLRow.isDetailError = true
        commandRow.detail = presentation.commandDetail.text
        commandRow.isDetailError = presentation.commandDetail.isError
        credentialRow.title = presentation.fields.authentication.credentialTitle
        credentialField.configure(value: presentation.fields.credential, masked: presentation.maskedCredential)
        if let authentication = AccountEditorPresentation.Authentication.allCases.firstIndex(
            of: presentation.fields.authentication)
        {
            authenticationPopUp.selectItem(at: authentication)
        }
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
        for model in modelFields {
            model.field.stringValue = fields.value(of: model.model)
        }
        commandField.stringValue = fields.command
        argumentsField.stringValue = fields.arguments
    }

    private static func modelField() -> FormTextField {
        FormTextField(placeholder: String(localized: "Automatic", bundle: .module), monospaced: true)
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

    /// Shows a note about what a paste did. Before the sheet is up, it waits
    /// for it to appear — and the sheet, filled, opens to read rather than in
    /// Name.
    public func say(_ summary: String) {
        wasFilled = true
        if isViewLoaded, view.window != nil { toast.show(summary) } else { pendingToast = summary }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if let pendingToast { toast.show(pendingToast) }
        pendingToast = nil
    }

    /// ⌘V anywhere in the sheet but a text field: the text — `KEY=value`
    /// lines, `export` lines or a whole alias — to fill the draft from.
    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        delegate?.accountEditor(self, didPaste: text)
    }

    @objc private func chooseAuthentication(_ sender: NSPopUpButton) {
        let all = AccountEditorPresentation.Authentication.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        delegate?.accountEditor(self, didChoose: all[sender.indexOfSelectedItem])
    }

    @objc private func manage(_ sender: Any?) {
        delegate?.accountEditorDidRequestManage(self)
    }

    @objc private func save(_ sender: Any?) {
        // An edit in progress is part of what is saved.
        view.window?.makeFirstResponder(nil)
        delegate?.accountEditorDidRequestSave(self)
    }

    @objc private func cancel(_ sender: Any?) {
        delegate?.accountEditorDidCancel(self)
    }

    /// ⌘. and Escape outside a field.
    public override func cancelOperation(_ sender: Any?) {
        cancel(sender)
    }

    @objc private func requestRemoval(_ sender: Any?) {
        delegate?.accountEditorDidRequestRemoval(self)
    }
}

extension AccountEditorViewController: NSTextFieldDelegate {
    /// Escape in a field cancels the sheet; a field editor binds it to
    /// `complete:`, which would otherwise offer completions.
    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.complete(_:)) else { return false }
        cancel(control)
        return true
    }

    /// Events up: each keystroke into the draft.
    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let edited: Field
        switch field {
        case nameField: edited = .name
        case baseURLField: edited = .baseURL
        case commandField: edited = .command
        case argumentsField: edited = .arguments
        default:
            guard let model = modelFields.first(where: { $0.field === field }) else { return }
            edited = .model(model.model)
        }
        delegate?.accountEditor(self, didEdit: edited, to: field.stringValue)
    }
}

/// The variable list's events, passed on as the sheet's.
extension AccountEditorViewController: EnvironmentVariablesViewControllerDelegate {
    public func environmentVariables(_ list: EnvironmentVariablesViewController, didToggleAt index: Int) {
        delegate?.accountEditor(self, didToggleVariableAt: index)
    }

    public func environmentVariables(
        _ list: EnvironmentVariablesViewController, didSetName name: String, at index: Int
    ) {
        delegate?.accountEditor(self, didSetVariableName: name, at: index)
    }

    public func environmentVariables(
        _ list: EnvironmentVariablesViewController, didSetValue value: String, at index: Int
    ) {
        delegate?.accountEditor(self, didSetVariableValue: value, at: index)
    }

    public func environmentVariablesDidAdd(_ list: EnvironmentVariablesViewController) -> Int {
        delegate?.accountEditorDidAddVariable(self) ?? 0
    }

    public func environmentVariables(_ list: EnvironmentVariablesViewController, didRemoveAt index: Int) {
        delegate?.accountEditor(self, didRemoveVariableAt: index)
    }

    public func environmentVariables(_ list: EnvironmentVariablesViewController, valueAt index: Int) -> String {
        delegate?.accountEditor(self, valueOfVariableAt: index) ?? ""
    }
}

extension AccountEditorPresentation.Authentication {
    /// Its item in the Authentication menu.
    fileprivate var title: String {
        switch self {
        case .authToken: String(localized: "Auth Token", bundle: .module)
        case .apiKey: String(localized: "API Key", bundle: .module)
        }
    }

    /// What it sends, beside its title in the menu.
    fileprivate var header: String {
        switch self {
        case .authToken: "Authorization: Bearer"
        case .apiKey: "x-api-key"
        }
    }

    /// The credential row's title.
    fileprivate var credentialTitle: String {
        switch self {
        case .authToken: String(localized: "Token", bundle: .module)
        case .apiKey: String(localized: "API key", bundle: .module)
        }
    }
}

extension AccountEditorPresentation.Fields {
    /// The text of `model`'s field.
    fileprivate func value(of model: AccountEditorViewController.Model) -> String {
        switch model {
        case .main: self.model
        case .opus: opus
        case .sonnet: sonnet
        case .haiku: haiku
        case .fable: fable
        }
    }
}

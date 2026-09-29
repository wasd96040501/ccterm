import AppKit

/// A form row's field for a secret. At rest it shows the secret masked —
/// its first three and last four characters, `sk-••••••••7c1e`; focused it
/// is a plain secure field; the eye beside it reveals the secret.
///
/// The secure field is always there, for clicks and Tab to land in; at
/// rest its bullets are drawn clear and the mask is shown over it.
@MainActor
final class FormSecretField: NSView {
    /// Each edit, with the whole secret.
    var onChange: ((String) -> Void)?

    private var value = ""
    private var isRevealed = false
    private var isEditing = false

    private let secureField = SecureField()
    private let plainField = FormTextField(placeholder: "", width: 230, monospaced: true)
    private let maskLabel = MaskLabel(labelWithString: "")
    private lazy var eyeButton: NSButton = {
        let button = NSButton(image: NSImage(), target: self, action: #selector(toggleReveal(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageOnly
        return button
    }()

    init(placeholder: String) {
        super.init(frame: .zero)
        for field in [secureField, plainField] {
            field.placeholderString = placeholder
            field.delegate = self
        }
        configureHierarchy()
        configureConstraints()
        secureField.onFocus = { [weak self] in self?.setEditing(true) }
        secureField.onEndEditing = { [weak self] in self?.setEditing(false) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `value`, masked as `masked` at rest. Leaves a field being typed
    /// in alone.
    func configure(value: String, masked: String) {
        self.value = value
        maskLabel.stringValue = masked
        if !isEditing, secureField.stringValue != value { secureField.stringValue = value }
        if plainField.currentEditor() == nil, plainField.stringValue != value { plainField.stringValue = value }
    }

    private func configureHierarchy() {
        secureField.isBordered = false
        secureField.drawsBackground = false
        secureField.focusRingType = .none
        secureField.alignment = .right
        secureField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        maskLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        maskLabel.alignment = .right
        maskLabel.lineBreakMode = .byTruncatingHead
        for view in [secureField, plainField, maskLabel, eyeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        var constraints = [
            eyeButton.widthAnchor.constraint(equalToConstant: 20),
            eyeButton.heightAnchor.constraint(equalToConstant: 20),
            eyeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plainField.trailingAnchor.constraint(equalTo: eyeButton.leadingAnchor, constant: -6),
            plainField.leadingAnchor.constraint(equalTo: leadingAnchor),
            plainField.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ]
        for view in [secureField, maskLabel] as [NSView] {
            constraints += [
                view.leadingAnchor.constraint(equalTo: plainField.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: plainField.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: plainField.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func setEditing(_ editing: Bool) {
        isEditing = editing
        update()
    }

    private func update() {
        plainField.isHidden = !isRevealed
        secureField.isHidden = isRevealed
        maskLabel.isHidden = isRevealed || isEditing
        secureField.textColor = isEditing ? .labelColor : .clear
        let symbol = isRevealed ? "eye.slash" : "eye"
        eyeButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isRevealed ? String(localized: "Hide") : String(localized: "Show"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    @objc private func toggleReveal(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        isRevealed.toggle()
        secureField.stringValue = value
        plainField.stringValue = value
        update()
    }

    /// The secure field, reporting when it takes and gives up focus.
    private final class SecureField: NSSecureTextField {
        var onFocus: (() -> Void)?
        var onEndEditing: (() -> Void)?

        /// Before the field editor copies the text colour.
        override func becomeFirstResponder() -> Bool {
            onFocus?()
            return super.becomeFirstResponder()
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onEndEditing?()
        }
    }

    /// The mask, drawn over the secure field; clicks go through to it.
    private final class MaskLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension FormSecretField: NSTextFieldDelegate {
    /// Escape goes to whatever encloses the field — a sheet cancels; a
    /// field editor binds it to `complete:`.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.complete(_:)) else { return false }
        return nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: control) ?? false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        value = field.stringValue
        onChange?(value)
    }
}

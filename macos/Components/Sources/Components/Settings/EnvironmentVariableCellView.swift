import AppKit
import DisplayModels

/// One row of the variable list: a checkbox, the name and the value in the
/// monospaced face, and a warning glyph when the row may not do what it
/// looks like. Columns: 30 for the checkbox, the name and the value sharing
/// the rest 1.6 : 1, 22 for the glyph, 5 to spare. The fields edit in
/// place; the value field swaps its masked display for `editingValue` while
/// it is edited. Tab moves from the name to the value; Escape puts the field
/// back as it was.
@MainActor
final class EnvironmentVariableCellView: NSTableCellView, NSTextFieldDelegate {
    /// The two fields of a row.
    enum Part {
        case name, value
    }

    /// The checkbox was clicked.
    var onToggle: (() -> Void)?
    /// `part`'s edit ended with `text`.
    var onCommit: ((_ part: Part, _ text: String) -> Void)?
    /// Return or Escape ended the edit, and focus goes back to the list;
    /// `cancelled` for Escape, which has already put the field back.
    var onEndEditing: ((_ cancelled: Bool) -> Void)?
    /// The value to edit, when it isn't what's shown — unmasked.
    var editingValue: (() -> String?)? {
        get { valueField.editingValue }
        set { valueField.editingValue = newValue }
    }

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let nameField = Field()
    let valueField = Field()
    private let warning = NSImageView()
    private var row: EnvironmentRow?

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `row`; a field being edited keeps its text.
    func configure(with row: EnvironmentRow) {
        self.row = row
        checkbox.state = row.isEnabled ? .on : .off
        if nameField.currentEditor() == nil { nameField.stringValue = row.name }
        if valueField.currentEditor() == nil { valueField.stringValue = row.displayValue }
        warning.isHidden = row.warning == nil
        warning.toolTip = row.warning
        updateColors()
    }

    /// Whether either field is being edited.
    var isEditing: Bool {
        nameField.currentEditor() != nil || valueField.currentEditor() != nil
    }

    /// The name as its field holds it.
    var name: String { nameField.stringValue }

    /// Puts `part`'s field into editing.
    func edit(_ part: Part) {
        window?.makeFirstResponder(part == .name ? nameField : valueField)
    }

    /// The field at `point`, in the cell's coordinates; `nil` over the
    /// checkbox.
    func part(at point: NSPoint) -> Part? {
        guard point.x > 30 else { return nil }
        return point.x >= valueField.frame.minX - 2 ? .value : .name
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// Label ink; tertiary for a row that's off; white on the selection.
    func updateColors() {
        // A row being edited draws no selection, so its ink goes back to label.
        let onSelection = backgroundStyle == .emphasized && !isEditing
        for field in [nameField, valueField] {
            // The row hands its style to every control cell, which would draw
            // label ink white while the selection is hidden for editing.
            field.cell?.backgroundStyle = onSelection ? .emphasized : .normal
            field.textColor =
                field.currentEditor() != nil
                ? .labelColor
                : onSelection
                    ? .alternateSelectedControlTextColor : row?.isEnabled == false ? .tertiaryLabelColor : .labelColor
        }
        warning.contentTintColor = onSelection ? .alternateSelectedControlTextColor : .formWarning
    }

    private func configureHierarchy() {
        nameField.setPlaceholder(String(localized: "Name", bundle: .module))
        valueField.setPlaceholder(String(localized: "Value", bundle: .module))
        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: String(localized: "Warning", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        for field in [nameField, valueField] {
            field.delegate = self
            field.onEditingChange = { [weak self] in self?.editingDidChange() }
        }
        for view in [checkbox, nameField, valueField, warning] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A field spans its column less 2 each side; its text sits 4
            // further in, 6 from the column's edge.
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30 + 2),
            nameField.trailingAnchor.constraint(equalTo: valueField.leadingAnchor, constant: -4),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(22 + 5 + 2)),
            // (name + 4) = 1.6 × (value + 4)
            nameField.widthAnchor.constraint(equalTo: valueField.widthAnchor, multiplier: 1.6, constant: 2.4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 20),
            valueField.heightAnchor.constraint(equalToConstant: 20),
            warning.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -(5 + 11)),
            warning.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func toggled(_ sender: NSButton) {
        onToggle?()
    }

    // MARK: - NSTextFieldDelegate

    /// Return commits; Tab from the name moves on to the value; Escape puts
    /// the field back as it was.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        // A field editor binds Escape to `complete:`.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            _ = (control as? NSTextField)?.abortEditing()
            if let row { configure(with: row) }
            onEndEditing?(true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onEndEditing?(false)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard control === nameField else { return false }
            window?.makeFirstResponder(valueField)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? Field else { return }
        onCommit?(field === nameField ? .name : .value, field.stringValue)
    }

    /// Editing draws the field as a text box over the selection, which the
    /// row view leaves out.
    private func editingDidChange() {
        updateColors()
        superview?.needsDisplay = true
    }

    /// A cell's text field: borderless at rest, a white box with the focus
    /// ring while edited; the text centred on the row and inset 4.
    final class Field: NSTextField {
        /// The text to edit, when it isn't what's shown — the value unmasked.
        var editingValue: (() -> String?)?
        var onEditingChange: (() -> Void)?

        init() {
            super.init(frame: .zero)
            cell = Cell(textCell: "")
            isEditable = true
            isSelectable = true
            isBordered = false
            drawsBackground = false
            backgroundColor = .textBackgroundColor
            usesSingleLineMode = true
            // At rest a long name ends in an ellipsis; while edited it scrolls.
            lineBreakMode = .byTruncatingTail
            font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            wantsLayer = true
            layer?.cornerRadius = 4
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func setPlaceholder(_ placeholder: String) {
            placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        }

        override func becomeFirstResponder() -> Bool {
            if let value = editingValue?() { stringValue = value }
            drawsBackground = true
            cell?.isScrollable = true
            let became = super.becomeFirstResponder()
            onEditingChange?()
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            endEditingDisplay()
        }

        override func abortEditing() -> Bool {
            let aborted = super.abortEditing()
            endEditingDisplay()
            return aborted
        }

        private func endEditingDisplay() {
            drawsBackground = false
            cell?.isScrollable = false
            cell?.lineBreakMode = .byTruncatingTail
            onEditingChange?()
        }

        /// Centres the line in the field and insets it 4 from the sides,
        /// for drawing and editing alike.
        private final class Cell: NSTextFieldCell {
            override func drawingRect(forBounds rect: NSRect) -> NSRect {
                let base = super.drawingRect(forBounds: rect.insetBy(dx: 2, dy: 0))
                let height = cellSize(forBounds: rect).height
                return NSRect(
                    x: base.minX, y: rect.minY + max(0, (rect.height - height) / 2), width: base.width,
                    height: min(height, rect.height))
            }
        }
    }
}
